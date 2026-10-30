#!/bin/bash
# Stage 2: runtime config externalization.
# Converts env vars to JVM system properties so ONE WAR runs against any JDBC target.
# Spring Framework 5.x's PropertySourcesPlaceholderConfigurer (registered via
# <context:property-placeholder>) uses StandardEnvironment, which includes
# systemProperties BEFORE localProperties when localOverride=false (the default).
# So -Djdbc.url overrides whatever is in datasource-mysql.properties.
set -euo pipefail

JAVA_OPTS="${JAVA_OPTS:-}"

# Core datasource override: Spring reads ${jdbc.url}, ${jdbc.username}, ${jdbc.password}
# driverClassName, db.script and jpa.database can also be set via env vars so the
# SAME IMAGE DIGEST serves H2 (testing) and MySQL 8.4 (production) without a rebuild.
JAVA_OPTS="${JAVA_OPTS} -Djdbc.url=${JDBC_URL:-jdbc:mysql://localhost:3306/petclinic}"
JAVA_OPTS="${JAVA_OPTS} -Djdbc.username=${JDBC_USER:-petclinic}"
JAVA_OPTS="${JAVA_OPTS} -Djdbc.password=${JDBC_PASSWORD:-petclinic}"
JAVA_OPTS="${JAVA_OPTS} -Djdbc.driverClassName=${JDBC_DRIVER_CLASS:-com.mysql.cj.jdbc.Driver}"
JAVA_OPTS="${JAVA_OPTS} -Djdbc.initLocation=classpath:db/${DB_SCRIPT:-mysql}/schema.sql"
JAVA_OPTS="${JAVA_OPTS} -Djdbc.dataLocation=classpath:db/${DB_SCRIPT:-mysql}/data.sql"
JAVA_OPTS="${JAVA_OPTS} -Djpa.database=${JPA_DATABASE:-MYSQL}"

# JVM container awareness: heap at 75% of cgroup limit, explicit GC thread cap.
# Without these, G1 sees all host CPUs and JVM OOM-kills the container (exit 137).
JAVA_OPTS="${JAVA_OPTS} -XX:MaxRAMPercentage=75.0"
JAVA_OPTS="${JAVA_OPTS} -XX:+ExitOnOutOfMemoryError"
JAVA_OPTS="${JAVA_OPTS} -XX:ActiveProcessorCount=2"

# Charset and timezone: pin explicitly so migrating between hosts doesn't
# silently shift date formatting or settlement file byte encoding.
JAVA_OPTS="${JAVA_OPTS} -Dfile.encoding=UTF-8"
JAVA_OPTS="${JAVA_OPTS} -Duser.timezone=${TZ:-UTC}"

echo "[entrypoint] JDBC_URL=${JDBC_URL:-jdbc:mysql://localhost:3306/petclinic}"
echo "[entrypoint] JETTY_HOME=${JETTY_HOME}"
echo "[entrypoint] JETTY_BASE=${JETTY_BASE}"
echo "[entrypoint] PORT=${PORT:-8080}"

exec java \
  ${JAVA_OPTS} \
  -jar "${JETTY_HOME}/start.jar" \
  "jetty.base=${JETTY_BASE}" \
  "jetty.http.port=${PORT:-8080}"
