#!/bin/bash

# If the directory provided through environment variable $JAVA_BOOTCLASSPATH exists, we gather up all .jar files in it and append them to the classpath.
# This is done by concatenating all filenames with a colon
# Resulting line looks something like
# -Xbootclasspath/a:my-jce-provider1.jar:my-classpath-lib.jar
# On java bootclasspath:
# https://docs.oracle.com/en/java/javase/24/docs/specs/man/java.html#extra-options-for-java:
#
# -Xbootclasspath/a:directories|zip|JAR-files
#    Specifies a list of directories, JAR files, and ZIP archives to append to the end of the default bootstrap class path.
#
#    On Windows, semicolons (;) separate entities in this list; on other platforms it is a colon (:).
#
test -d "${JAVA_BOOTCLASSPATH}" && bootclasspath_java_opt=-Xbootclasspath/a:$(ls $JAVA_BOOTCLASSPATH/*.jar | tr '\n' ':')

# Print truststore presence for baked-in certs so it is visible in container startup logs.
if ls /certs-app/*.crt >/dev/null 2>&1; then
    echo "Checking certificates in Java truststore:"
    for cert in /certs-app/*.crt; do
        alias="$(basename "$cert" .crt)"
        if keytool -list -keystore "$JAVA_HOME/lib/security/cacerts" -storepass changeit -alias "$alias" >/dev/null 2>&1; then
            echo " => truststore contains alias: $alias"
        else
            echo " => truststore missing alias: $alias"
        fi
    done
fi

# Only set the JVM proxy system properties when the corresponding env vars are
# actually provided. Passing an *empty* -Dhttp.proxyHost=/-Dhttps.proxyHost= is
# NOT equivalent to omitting the property: some HTTP clients (e.g. Reactor Netty,
# used by Spring WebClient) interpret an empty proxyHost as "localhost" and will
# then try to route every outbound request through a non-existent local proxy on
# the hardcoded port 8080, breaking any environment (e.g. tests using mockserver)
# where no proxy is actually configured.

# In addition: when deploying this image to Kubernetes, the spring kubernetes addon
# automatically kicks in and parses the environment variables HTTP[S]_PROXY. It expects
# the normal format http[s]://<server>:<port> which is incompatible with Java which only
# expects the host/IP and the port in the corresponding variables.
# Hence we parse the environment variables and extract the needed information for Java.
# Supported formats (port defaults to 8080):
#   [http[s]://][user[:pass]@]<host>|<IPv4>|[<IPv6>][:<port>][/<path>]
proxy_java_opts=()
add_proxy_opts() {
    local proto="$1" value="$2"
    # groups: 1=scheme 2=userinfo@ 3=host-part 4=IPv6 (without brackets) 5=host/IPv4 6=:port 7=port 8=path
    local re='^(https?://)?([^@/]*@)?(\[([0-9a-fA-F:.]+)\]|([^]:/@[]+))(:([0-9]+))?(/.*)?$'
    if [[ ! "${value}" =~ ${re} ]]; then
        echo "WARNING: ignoring unparsable ${proto^^}_PROXY value '${value}'" >&2
        return
    fi
    local host="${BASH_REMATCH[4]:-${BASH_REMATCH[5]}}"
    local port="${BASH_REMATCH[7]:-8080}"
    if (( 10#${port} < 1 || 10#${port} > 65535 )); then
        echo "WARNING: ignoring ${proto^^}_PROXY value '${value}': invalid port ${port}" >&2
        return
    fi
    [ -n "${BASH_REMATCH[2]}" ] && echo "WARNING: credentials in ${proto^^}_PROXY are ignored by Java's proxy properties" >&2
    proxy_java_opts+=("-D${proto}.proxyHost=${host}" "-D${proto}.proxyPort=$((10#${port}))")
}
[ -n "${HTTP_PROXY}" ]  && add_proxy_opts http  "${HTTP_PROXY}"
[ -n "${HTTPS_PROXY}" ] && add_proxy_opts https "${HTTPS_PROXY}"
# NO_PROXY: accepts curl, Go and Java syntax and converts it to Java's http.nonProxyHosts
# (Java also uses this property for HTTPS, there is no https.nonProxyHosts).
#   curl/Go: comma-separated; foo and .foo -> foo|*.foo (union of curl and Go semantics),
#            *.foo kept; host:port and [IPv6]:port -> port stripped (Java can't match ports)
#   Java:    '|'-separated; plain names are exact matches, *foo / foo* wildcards kept
# Entries can be mixed; CIDR ranges are not supported and are skipped with a warning.
parse_no_proxy() {
    local value="$1" java_syntax=false entry
    [[ "${value}" == *"|"* ]] && java_syntax=true
    local -a entries hosts=()
    local -A seen=()
    IFS=',|' read -ra entries <<< "${value}"
    for entry in "${entries[@]}"; do
        entry="${entry//[[:space:]]/}"
        entry="${entry%.}"                                                      # trailing dot (FQDN)
        [ -z "${entry}" ] && continue
        if [[ "${entry}" == */* ]]; then
            echo "WARNING: CIDR '${entry}' in NO_PROXY is not supported, ignored" >&2
            continue
        fi
        [[ "${entry}" =~ ^\[(.*)\](:[0-9]+)?$ ]] && entry="${BASH_REMATCH[1]}"  # [IPv6][:port]
        [[ "${entry}" =~ ^([^:]+):[0-9]+$ ]] && entry="${BASH_REMATCH[1]}"       # host:port
        local -a patterns=("${entry}")
        if [[ "${entry}" == *"*"* || "${entry}" == *:* || "${entry}" =~ ^[0-9.]+$ ]]; then
            :                                                                   # wildcards, IPv6, IPv4: as is
        elif [[ "${entry}" == .* ]] || ! ${java_syntax}; then
            entry="${entry#.}"
            patterns=("${entry}" "*.${entry}")                                  # curl/Go domain
        fi
        for entry in "${patterns[@]}"; do
            [ -n "${seen[${entry}]:-}" ] || { seen[${entry}]=1; hosts+=("${entry}"); }
        done
    done
    local IFS='|'
    [ ${#hosts[@]} -gt 0 ] && proxy_java_opts+=("-Dhttp.nonProxyHosts=${hosts[*]}")
}
[ -n "${NO_PROXY}" ] && parse_no_proxy "${NO_PROXY}"

java -Duser.timezone=Europe/Zurich \
-Dspring.config.location=classpath:bootstrap.yml,classpath:application.yml,optional:file:/vault/secrets/database-credentials.yml \
-Dfile.encoding=UTF-8 \
-Dspring.profiles.active=${MY_SPRING_PROFILES} \
"${proxy_java_opts[@]}" \
${bootclasspath_java_opt} \
-jar $1