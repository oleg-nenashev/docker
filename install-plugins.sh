#!/bin/bash -eu

# Resolve dependencies and download plugins given on the command line
#
# FROM jenkins
# RUN install-plugins.sh docker-slaves github-branch-source
set -o pipefail

REF_DIR=${REF:-/usr/share/jenkins/ref/plugins}
FAILED="$REF_DIR/failed-plugins.txt"

. /usr/local/bin/jenkins-support

getLockFile() {
    printf '%s' "$REF_DIR/${1}.lock"
}

getArchiveFilename() {
    printf '%s' "$REF_DIR/${1}.jpi"
}

download() {
    local plugin originalPlugin version lock ignoreLockFile
    plugin="$1"
    version="${2:-latest}"
    ignoreLockFile="${3:-}"
    lock="$(getLockFile "$plugin")"

    if [[ $ignoreLockFile ]] || mkdir "$lock" &>/dev/null; then
        if ! doDownload "$plugin" "$version"; then
            # some plugin don't follow the rules about artifact ID
            # typically: docker-plugin
            originalPlugin="$plugin"
            plugin="${plugin}-plugin"
            if ! doDownload "$plugin" "$version"; then
                echo "Failed to download plugin: $originalPlugin or $plugin" >&2
                echo "Not downloaded: ${originalPlugin}" >> "$FAILED"
                return 1
            fi
        fi

        if ! checkIntegrity "$plugin"; then
            echo "Downloaded file is not a valid ZIP: $(getArchiveFilename "$plugin")" >&2
            echo "Download integrity: ${plugin}" >> "$FAILED"
            return 1
        fi

        resolveDependencies "$plugin"
    fi
}

doDownload() {
    local plugin version url jpi
    plugin="$1"
    version="$2"
    jpi="$(getArchiveFilename "$plugin")"

    # If plugin already exists and is the same version do not download
    if test -f "$jpi" && unzip -p "$jpi" META-INF/MANIFEST.MF | tr -d '\r' | grep "^Plugin-Version: ${version}$" > /dev/null; then
        echo "Using provided plugin: $plugin"
        return 0
    fi

    if [[ "$version" == "latest" && -n "$JENKINS_UC_LATEST" ]]; then
        # If version-specific Update Center is available, which is the case for LTS versions,
        # use it to resolve latest versions.
        url="$JENKINS_UC_LATEST/latest/${plugin}.hpi"
    elif [[ "$version" == "experimental" && -n "$JENKINS_UC_EXPERIMENTAL" ]]; then
        # Download from the experimental update center
        url="$JENKINS_UC_EXPERIMENTAL/latest/${plugin}.hpi"
    elif [[ "$version" == incrementals* ]] ; then
        # Download from Incrementals repo: https://jenkins.io/blog/2018/05/15/incremental-deployment/
        # Example URL: https://repo.jenkins-ci.org/incrementals/org/jenkins-ci/plugins/workflow/workflow-support/2.19-rc289.d09828a05a74/workflow-support-2.19-rc289.d09828a05a74.hpi
        local groupId incrementalsVersion
        arrIN=(${version//;/ })
        groupId=${arrIN[1]}
        incrementalsVersion=${arrIN[2]}
        url="${JENKINS_INCREMENTALS_REPO_MIRROR}/$(echo "${groupId}" | tr '.' '/')/${plugin}/${incrementalsVersion}/${plugin}-${incrementalsVersion}.hpi"
    else
        JENKINS_UC_DOWNLOAD=${JENKINS_UC_DOWNLOAD:-"$JENKINS_UC/download"}
        url="$JENKINS_UC_DOWNLOAD/plugins/$plugin/$version/${plugin}.hpi"
    fi

    echo "Downloading plugin: $plugin from $url"
    retry_command curl "${CURL_OPTIONS:--sSfL}" --connect-timeout "${CURL_CONNECTION_TIMEOUT:-20}" --retry "${CURL_RETRY:-5}" --retry-delay "${CURL_RETRY_DELAY:-0}" --retry-max-time "${CURL_RETRY_MAX_TIME:-60}" "$url" -o "$jpi"
    return $?
}

checkIntegrity() {
    local plugin jpi
    plugin="$1"
    jpi="$(getArchiveFilename "$plugin")"

    unzip -t -qq "$jpi" >/dev/null
    return $?
}

resolveDependencies() {
    local plugin jpi dependencies
    plugin="$1"
    jpi="$(getArchiveFilename "$plugin")"

    dependencies="$(unzip -p "$jpi" META-INF/MANIFEST.MF | tr -d '\r' | tr '\n' '|' | sed -e 's#| ##g' | tr '|' '\n' | grep "^Plugin-Dependencies: " | sed -e 's#^Plugin-Dependencies: ##')"

    if [[ ! $dependencies ]]; then
        echo " > $plugin has no dependencies"
        return
    fi

    echo " > $plugin depends on $dependencies"

    IFS=',' read -r -a array <<< "$dependencies"

    for d in "${array[@]}"
    do
        plugin="$(cut -d':' -f1 - <<< "$d")"
        if [[ $d == *"resolution:=optional"* ]]; then
            echo "Skipping optional dependency $plugin"
        else
            local pluginInstalled
            if pluginInstalled="$(echo -e "${bundledPlugins}\n${installedPlugins}" | grep "^${plugin}:")"; then
                pluginInstalled="${pluginInstalled//[$'\r']}"
                local versionInstalled; versionInstalled=$(versionFromPlugin "${pluginInstalled}")
                local minVersion; minVersion=$(versionFromPlugin "${d}")
                if versionLT "${versionInstalled}" "${minVersion}"; then
                    echo "Upgrading bundled dependency $d ($minVersion > $versionInstalled)"
                    download "$plugin" &
                else
                    echo "Skipping already installed dependency $d ($minVersion <= $versionInstalled)"
                fi
            else
                download "$plugin" &
            fi
        fi
    done
    wait
}

bundledPlugins() {
    local JENKINS_WAR=/usr/share/jenkins/jenkins.war
    if [ -f $JENKINS_WAR ]
    then
        TEMP_PLUGIN_DIR=/tmp/plugintemp.$$
        for i in $(jar tf $JENKINS_WAR | grep -E '[^detached-]plugins.*\..pi' | sort)
        do
            rm -fr $TEMP_PLUGIN_DIR
            mkdir -p $TEMP_PLUGIN_DIR
            PLUGIN=$(basename "$i"|cut -f1 -d'.')
            (cd $TEMP_PLUGIN_DIR;jar xf "$JENKINS_WAR" "$i";jar xvf "$TEMP_PLUGIN_DIR/$i" META-INF/MANIFEST.MF >/dev/null 2>&1)
            VER=$(grep -E -i Plugin-Version "$TEMP_PLUGIN_DIR/META-INF/MANIFEST.MF"|cut -d: -f2|sed 's/ //')
            echo "$PLUGIN:$VER"
        done
        rm -fr $TEMP_PLUGIN_DIR
    else
        rm -f "$TEMP_ALREADY_INSTALLED"
        echo "ERROR file not found: $JENKINS_WAR"
        exit 1
    fi
}

versionFromPlugin() {
    local plugin=$1
    if [[ $plugin =~ .*:.* ]]; then
        echo "${plugin##*:}"
    else
        echo "latest"
    fi

}

installedPlugins() {
    for f in "$REF_DIR"/*.jpi; do
        echo "$(basename "$f" | sed -e 's/\.jpi//'):$(get_plugin_version "$f")"
    done
}

availableUpdates() {
    local url
    if [[ -n "$JENKINS_UC_LATEST" ]]; then
        # If version-specific Update Center is available, which is the case for LTS versions,
        # use it to resolve latest versions.
        url="$JENKINS_UC_LATEST/update-center.actual.json"
    else
        JENKINS_UC_DOWNLOAD=${JENKINS_UC_DOWNLOAD:-"$JENKINS_UC/download"}
        url="$JENKINS_UC_DOWNLOAD/update-center.actual.json"
    fi
    local jqExecutable="/usr/local/bin/jq"
    local ucMetadataFile="$REF_DIR/uc.json"

    local updatesFile="$REF_DIR/availableUpdates.txt"
    local securityWarningsFile="$REF_DIR/securityWarnings.txt"

    # TODO: do jq installation in Dockerfile so that it comes from cache when plugin list is refreshed
    local failureReason=""
    # Download UC metadata file if it is missing
    if [ ! -f "$ucMetadataFile" ]; then
        curl --connect-timeout "${CURL_CONNECTION_TIMEOUT:-20}" \
             --retry "${CURL_RETRY:-5}" --retry-delay "${CURL_RETRY_DELAY:-0}" --retry-max-time "${CURL_RETRY_MAX_TIME:-60}" \
             -s -f -L "$url" -o "$ucMetadataFile" \
                || failureReason="Cannot retrieve the UC metadata from ${url}, error code: $?"
    fi

    if [[ -n "$failureReason" ]] ; then
        >&2 echo "WARNING: Cannot check for updates: $failureReason"
        if [[ "${IGNORE_SECURITY_WARNINGS}" = true ]] ; then
            >&2 echo "WARNING: Security warnings are ignored, will continue build"
        else
            # If security warnings are critical, we cannot continue here
            exit -1
        fi
    else
        local securityFailed=""
        for f in "$REF_DIR"/*.jpi; do
            local pluginName versionInstalled latestVersion securityWarnings
            pluginName=$(basename "$f" | sed -e 's/\.jpi//')
            versionInstalled=$(get_plugin_version "$f")
            latestVersion=$("${jqExecutable}" -r ".plugins[\"${pluginName}\"].version" "$ucMetadataFile")
            if versionLT "${versionInstalled}" "${latestVersion}"; then
                echo "$pluginName:$versionInstalled:$latestVersion" >> "$updatesFile"
                # Also report it in the build log
                echo "$pluginName:$versionInstalled => $latestVersion"
            fi

            # Example: query all security warning for the plugin's version
            # ./jq -r '.warnings[] | select(.name == "git") | select(.id | contains("SECURITY")) | select(.versions[].lastVersion | . >= "3.0.0" and (contains("beta") | not) and (contains("alpha") | not)) | "\(.id): \(.message) (\(.url))"'
            # TODO: This logic won't work properly for experimental releases which may have also fixes delivered in a separate baseline (e.g. Git)
            local experimentalFilter="select(.versions[].lastVersion | (contains(\"beta\") | not) and (contains(\"alpha\") | not))"
            local outputFormat="\"\\(.versions[0].lastVersion) - \\(.id): \\(.message) (\\(.url))\""
            securityWarnings=$("${jqExecutable}" -r ".warnings[] | select(.name == \"${pluginName}\") | select(.id | contains(\"SECURITY\")) | ${experimentalFilter} | ${outputFormat}" "$ucMetadataFile")
            if [[ -n "$securityWarnings" ]] ; then
                local firstHit=true
                while read -r line ; do
                    local lastAffectedVersion
                    lastAffectedVersion=$(echo $line | awk '{print $1;}')
                    if versionLT "${lastAffectedVersion}" "${versionInstalled}" ; then
                        lastAffectedVersion="${lastAffectedVersion}"
                    else
                        if [[ $firstHit = true ]] ; then
                           >&2 echo "Security warnings for plugin $pluginName:"
                           echo "${pluginName}" >> "${securityWarningsFile}"
                           firstHit=false
                        fi
                        >&2 echo "up to ${line}"
                        echo "up to ${line}" >> "${securityWarningsFile}"
                        securityFailed="${pluginName}"
                    fi
                done <<< $(echo "${securityWarnings}")
            fi
        done

        if [[ -n "$securityFailed" ]] ; then
            >&2 echo "WARNING: Some installed plugins have security warnings, see above"
            if [[ "${IGNORE_SECURITY_WARNINGS}" = true ]] ; then
                >&2 echo "WARNING: Ignoring the security warnings"
            else
                exit -1
            fi
        fi
    fi
}

jenkinsMajorMinorVersion() {
    local JENKINS_WAR
    JENKINS_WAR=/usr/share/jenkins/jenkins.war
    if [[ -f "$JENKINS_WAR" ]]; then
        local version major minor
        version="$(java -jar /usr/share/jenkins/jenkins.war --version)"
        major="$(echo "$version" | cut -d '.' -f 1)"
        minor="$(echo "$version" | cut -d '.' -f 2)"
        echo "$major.$minor"
    else
        echo "ERROR file not found: $JENKINS_WAR"
        return 1
    fi
}

main() {
    local plugin pluginVersion jenkinsVersion
    local plugins=()

    mkdir -p "$REF_DIR" || exit 1

    # Read plugins from stdin or from the command line arguments
    if [[ ($# -eq 0) ]]; then
        while read -r line || [ "$line" != "" ]; do
            # Remove leading/trailing spaces, comments, and empty lines
            plugin=$(echo "${line}" | tr -d '\r' | sed -e 's/^[ \t]*//g' -e 's/[ \t]*$//g' -e 's/[ \t]*#.*$//g' -e '/^[ \t]*$/d')

            # Avoid adding empty plugin into array
            if [ ${#plugin} -ne 0 ]; then
                plugins+=("${plugin}")
            fi
        done
    else
        plugins=("$@")
    fi

    # Create lockfile manually before first run to make sure any explicit version set is used.
    echo "Creating initial locks..."
    for plugin in "${plugins[@]}"; do
        mkdir "$(getLockFile "${plugin%%:*}")"
    done

    echo "Analyzing war..."
    bundledPlugins="$(bundledPlugins)"

    echo "Registering preinstalled plugins..."
    installedPlugins="$(installedPlugins)"

    # Check if there's a version-specific update center, which is the case for LTS versions
    jenkinsVersion="$(jenkinsMajorMinorVersion)"
    if curl -fsL -o /dev/null "$JENKINS_UC/$jenkinsVersion"; then
        JENKINS_UC_LATEST="$JENKINS_UC/$jenkinsVersion"
        echo "Using version-specific update center: $JENKINS_UC_LATEST..."
    else
        JENKINS_UC_LATEST=
    fi

    echo "Downloading plugins..."
    for plugin in "${plugins[@]}"; do
        pluginVersion=""

        if [[ $plugin =~ .*:.* ]]; then
            pluginVersion=$(versionFromPlugin "${plugin}")
            plugin="${plugin%%:*}"
        fi

        download "$plugin" "$pluginVersion" "true" &
    done
    wait

    echo
    echo "WAR bundled plugins:"
    echo "${bundledPlugins}"
    echo
    echo "Installed plugins:"
    installedPlugins
    echo
    if [[ "$CHECK_UPDATES" = true ]] ; then
        echo "Available updates:"
        availableUpdates
        echo
    fi

    if [[ -f $FAILED ]]; then
        echo "Some plugins failed to download!" "$(<"$FAILED")" >&2
        exit 1
    fi

    echo "Cleaning up locks"
    rm -r "$REF_DIR"/*.lock
}

main "$@"