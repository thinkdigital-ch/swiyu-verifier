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
proxy_java_opts=()
if [ -n "${HTTP_PROXY}" ]; then
    [[ "${HTTP_PROXY}" =~ ^(https?://)?(.+):([0-9]+)$ ]] && { HTTP_PROXY_HOST=${BASH_REMATCH[2]}; HTTP_PROXY_PORT=${BASH_REMATCH[3]}; }
    proxy_java_opts+=("-Dhttp.proxyHost=${HTTP_PROXY_HOST}" "-Dhttp.proxyPort=${HTTP_PROXY_PORT}")
fi
if [ -n "${HTTPS_PROXY}" ]; then
    [[ "${HTTPS_PROXY}" =~ ^(https?://)?(.+):([0-9]+)$ ]] && { HTTPS_PROXY_HOST=${BASH_REMATCH[2]}; HTTPS_PROXY_PORT=${BASH_REMATCH[3]}; }
    proxy_java_opts+=("-Dhttps.proxyHost=${HTTPS_PROXY_HOST}" "-Dhttps.proxyPort=${HTTPS_PROXY_PORT}")
fi
if [ -n "${NO_PROXY}" ]; then
    proxy_java_opts+=("-Dhttp.nonProxyHosts=${NO_PROXY}")
fi

java -Duser.timezone=Europe/Zurich \
-Dspring.config.location=classpath:bootstrap.yml,classpath:application.yml,optional:file:/vault/secrets/database-credentials.yml \
-Dfile.encoding=UTF-8 \
-Dspring.profiles.active=${MY_SPRING_PROFILES} \
"${proxy_java_opts[@]}" \
${bootclasspath_java_opt} \
-jar $1