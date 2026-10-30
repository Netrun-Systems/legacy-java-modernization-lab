# syntax=docker/dockerfile:1.7
#
# Multi-target Dockerfile for PetClinic lab.
# Build targets:
#   jetty12   - container-app host (Jetty 12.1.14 ee8, JDK 21)    [default]
#   jetty94   - legacy-app host  (Jetty 9.4.58, JDK 21)
#
# Usage:
#   docker build --target jetty12 -t lab/petclinic:jetty12 .
#   docker build --target jetty94 -t lab/petclinic:jetty94 .
#
# Stage 2 externalization: JDBC_URL / JDBC_USER / JDBC_PASSWORD env vars
# are converted to JVM system properties by entrypoint.sh.
# Spring's PropertySourcesPlaceholderConfigurer reads them before the
# classpath datasource-mysql.properties file (localOverride=false default).

ARG MAVEN_VERSION=3.9.11
ARG JETTY12_VERSION=12.1.14
ARG JETTY94_VERSION=9.4.58.v20250814
ARG MAVEN_CENTRAL=https://repo.maven.apache.org/maven2
ARG PETCLINIC_TAG=v5.3.22

# ---------------------------------------------------------------------------
# Stage 1: Build the WAR (MySQL profile so mysql-connector-j is included).
# BuildKit cache mount keeps ~/.m2 across builds; ~3 min first run, ~30 s after.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk-noble AS builder
ARG MAVEN_VERSION
ARG MAVEN_CENTRAL
ARG PETCLINIC_TAG

RUN apt-get update -qq && apt-get install -y -qq git curl python3 2>/dev/null

WORKDIR /build

# Download Maven
RUN curl -fsSL -o maven.tgz \
    "${MAVEN_CENTRAL}/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" && \
    tar xzf maven.tgz && rm maven.tgz

# Clone source at exact tag
RUN git clone -q --depth 1 --branch "${PETCLINIC_TAG}" \
    https://github.com/spring-petclinic/spring-framework-petclinic.git

# Build WAR with MySQL profile (includes mysql-connector-j in WEB-INF/lib).
# BuildKit cache preserves ~/.m2 between Docker builds.
RUN --mount=type=cache,target=/root/.m2 \
    cd spring-framework-petclinic && \
    /build/apache-maven-${MAVEN_VERSION}/bin/mvn \
      -q -B -DskipTests -Djacoco.skip=true -P MySQL \
      package

# Add jetty-ee8-web.xml so ONE WAR works on both Jetty 9.4 and 12.1.
# Jetty 9.4 ignores jetty-ee8-web.xml; Jetty 12 reads it first.
# The file fixes the ClassNotFoundException on Jetty 12 caused by
# org.eclipse.jetty.webapp.WebAppContext moving to the ee8 namespace.
RUN mkdir -p /tmp/patch/WEB-INF && \
    cat > /tmp/patch/WEB-INF/jetty-ee8-web.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE Configure PUBLIC "-//Jetty//Configure//EN" "https://jetty.org/configure_10_0.dtd">
<Configure class="org.eclipse.jetty.ee8.webapp.WebAppContext">
    <Set name="parentLoaderPriority">true</Set>
</Configure>
EOF
    cd /tmp/patch && jar uf /build/spring-framework-petclinic/target/petclinic.war WEB-INF/jetty-ee8-web.xml && \
    cp /build/spring-framework-petclinic/target/petclinic.war /petclinic.war

# Patch WAR so driverClassName and init scripts are runtime-configurable.
# This lets the same image digest target H2 (dev) and MySQL 8.4 (prod) via env vars.
# Download H2 JAR for injection into WAR (MySQL-profile build omits it).
# patch_war.py injects it into WEB-INF/lib so H2 mode works at class-load.
RUN curl -fsSL -o /tmp/h2.jar \
    "${MAVEN_CENTRAL}/com/h2database/h2/2.1.214/h2-2.1.214.jar"

COPY stage2/patch_war.py /tmp/patch_war.py
RUN python3 /tmp/patch_war.py && rm /tmp/patch_war.py /tmp/h2.jar

# ---------------------------------------------------------------------------
# Stage 2a: Jetty 12.1.14 ee8 runtime (container-app / "after" host)
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jre-noble AS jetty12
ARG JETTY12_VERSION
ARG MAVEN_CENTRAL

ENV JETTY_VERSION=${JETTY12_VERSION} \
    JETTY_HOME=/opt/jetty-home \
    JETTY_BASE=/var/lib/jetty

RUN apt-get update -qq && apt-get install -y -qq curl 2>/dev/null && \
    curl -fsSL -o /tmp/jetty.tgz \
      "${MAVEN_CENTRAL}/org/eclipse/jetty/jetty-home/${JETTY_VERSION}/jetty-home-${JETTY_VERSION}.tar.gz" && \
    tar xzf /tmp/jetty.tgz -C /opt && \
    ln -s /opt/jetty-home-${JETTY_VERSION} /opt/jetty-home && \
    rm /tmp/jetty.tgz && \
    apt-get remove -y curl && apt-get autoremove -y

# Initialise Jetty base with ee8-deploy and JSTL/JSP modules by writing
# start.d/*.ini files directly. --add-modules with --jetty.base= is silently
# ignored in Jetty 12 (the flag is not a recognised start.jar argument; Jetty
# reports "Unknown Arguments detected" and falls back to CWD as the base,
# leaving start.d empty). Writing the ini files directly is the reliable path.
RUN mkdir -p "${JETTY_BASE}/start.d" && \
    echo "--module=server"           > "${JETTY_BASE}/start.d/server.ini" && \
    echo "--module=http"             > "${JETTY_BASE}/start.d/http.ini" && \
    echo "--module=ee8-deploy"       > "${JETTY_BASE}/start.d/ee8-deploy.ini" && \
    echo "--module=ee8-apache-jsp"   > "${JETTY_BASE}/start.d/ee8-apache-jsp.ini" && \
    echo "--module=ee8-glassfish-jstl" > "${JETTY_BASE}/start.d/ee8-glassfish-jstl.ini"

COPY --from=builder /petclinic.war "${JETTY_BASE}/webapps/"
# Pin the WAR to ee8 environment; without this an unpinned WAR goes to the
# newest enabled EE environment, which would fail if a jakarta env were also enabled.
RUN printf 'environment=ee8\n' > "${JETTY_BASE}/webapps/petclinic.properties"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
LABEL org.opencontainers.image.title="petclinic-jetty12" \
      org.opencontainers.image.version="${JETTY12_VERSION}" \
      org.opencontainers.image.description="PetClinic v5.3.22 on Jetty 12.1 ee8 (javax unchanged)"

ENTRYPOINT ["/entrypoint.sh"]

# ---------------------------------------------------------------------------
# Stage 2b: Jetty 9.4.58 runtime (legacy-app / "before" host)
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jre-noble AS jetty94
ARG JETTY94_VERSION
ARG MAVEN_CENTRAL

ENV JETTY_VERSION=${JETTY94_VERSION} \
    JETTY_HOME=/opt/jetty-home \
    JETTY_BASE=/var/lib/jetty

RUN apt-get update -qq && apt-get install -y -qq curl 2>/dev/null && \
    curl -fsSL -o /tmp/jetty.tgz \
      "${MAVEN_CENTRAL}/org/eclipse/jetty/jetty-home/${JETTY_VERSION}/jetty-home-${JETTY_VERSION}.tar.gz" && \
    tar xzf /tmp/jetty.tgz -C /opt && \
    ln -s "/opt/jetty-home-${JETTY_VERSION}" /opt/jetty-home && \
    rm /tmp/jetty.tgz && \
    apt-get remove -y curl && apt-get autoremove -y

RUN mkdir -p "${JETTY_BASE}" && \
    java -jar "${JETTY_HOME}/start.jar" \
      --jetty.base="${JETTY_BASE}" \
      --add-to-start=http,deploy,jsp,jstl,annotations 2>&1 | \
      grep -v "^$" || true

COPY --from=builder /petclinic.war "${JETTY_BASE}/webapps/"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
LABEL org.opencontainers.image.title="petclinic-jetty94" \
      org.opencontainers.image.version="${JETTY94_VERSION}" \
      org.opencontainers.image.description="PetClinic v5.3.22 on Jetty 9.4 (legacy, EoL Jan 2026)"

ENTRYPOINT ["/entrypoint.sh"]
