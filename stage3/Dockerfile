#
# Stage 3 production Dockerfile - used by Jenkins pipeline.
# Identical logic to stage2/Dockerfile but with full OCI labels for
# commit→digest traceability (PCI 6.5.1.b) and explicit ARGs for pinning.
#
# Jenkins passes:
#   --build-arg GIT_COMMIT=<sha>
#   --build-arg BUILD_NUMBER=<n>
#   --target jetty12 (or jetty94 for legacy rebuild)

ARG MAVEN_VERSION=3.9.11
ARG JETTY12_VERSION=12.1.14
ARG JETTY94_VERSION=9.4.58.v20250814
ARG MAVEN_CENTRAL=https://repo.maven.apache.org/maven2
ARG PETCLINIC_TAG=v5.3.22
ARG GIT_COMMIT=unknown
ARG BUILD_NUMBER=0

# ---------------------------------------------------------------------------
# Builder - same as stage2
# ---------------------------------------------------------------------------
# eclipse-temurin:21-jdk-noble pinned by digest 2026-10-29
FROM eclipse-temurin@sha256:bd6ac06e2a2df928af21c75c4a8a0f2829a93377a65761d6a577bb32281e2ac3 AS builder
ARG MAVEN_VERSION MAVEN_CENTRAL PETCLINIC_TAG

RUN apt-get update -qq && apt-get install -y -qq git curl python3 2>/dev/null

WORKDIR /build
RUN curl -fsSL -o maven.tgz \
    "${MAVEN_CENTRAL}/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" && \
    tar xzf maven.tgz && rm maven.tgz

RUN git clone -q --depth 1 --branch "${PETCLINIC_TAG}" \
    https://github.com/spring-petclinic/spring-framework-petclinic.git

RUN --mount=type=cache,target=/root/.m2 \
    cd spring-framework-petclinic && \
    /build/apache-maven-${MAVEN_VERSION}/bin/mvn \
      -q -B -DskipTests -Djacoco.skip=true -P MySQL \
      package

RUN mkdir -p /tmp/patch/WEB-INF && \
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE Configure PUBLIC "-//Jetty//Configure//EN" "https://jetty.org/configure_10_0.dtd">' \
      '<Configure class="org.eclipse.jetty.ee8.webapp.WebAppContext">' \
      '    <Set name="parentLoaderPriority">true</Set>' \
      '</Configure>' \
      > /tmp/patch/WEB-INF/jetty-ee8-web.xml && \
    cd /tmp/patch && \
    jar uf /build/spring-framework-petclinic/target/petclinic.war WEB-INF/jetty-ee8-web.xml && \
    cp /build/spring-framework-petclinic/target/petclinic.war /petclinic.war

# Patch WAR so datasource driverClassName and init scripts are runtime-configurable.
# Without this, driverClassName is hardcoded to MySQL in the XML and H2 mode fails.
# With this patch the same image digest serves H2 (dev/test) and MySQL 8.4 (prod).
# Download H2 JAR for injection into WAR (MySQL-profile build omits it).
# patch_war.py injects it into WEB-INF/lib so H2 mode works at class-load.
RUN curl -fsSL -o /tmp/h2.jar \
    "${MAVEN_CENTRAL}/com/h2database/h2/2.1.214/h2-2.1.214.jar"

COPY stage3/patch_war.py /tmp/patch_war.py
RUN python3 /tmp/patch_war.py && rm /tmp/patch_war.py /tmp/h2.jar

# ---------------------------------------------------------------------------
# Jetty 12.1.14 ee8 runtime (default target for Jenkins pipeline)
# ---------------------------------------------------------------------------
# eclipse-temurin:21-jre-noble pinned by digest 2026-10-29
FROM eclipse-temurin@sha256:161310cd5bd41fd549d19cf9f90b614897cb4a1532555c613b43b7e0628fe5d6 AS jetty12
ARG JETTY12_VERSION MAVEN_CENTRAL GIT_COMMIT BUILD_NUMBER

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

RUN mkdir -p "${JETTY_BASE}/start.d" && \
    echo "--module=server"             > "${JETTY_BASE}/start.d/server.ini" && \
    echo "--module=http"              >> "${JETTY_BASE}/start.d/http.ini" && \
    echo "--module=ee8-deploy"        >> "${JETTY_BASE}/start.d/ee8-deploy.ini" && \
    echo "--module=ee8-apache-jsp"    >> "${JETTY_BASE}/start.d/ee8-apache-jsp.ini" && \
    echo "--module=ee8-glassfish-jstl" >> "${JETTY_BASE}/start.d/ee8-glassfish-jstl.ini"

COPY --from=builder /petclinic.war "${JETTY_BASE}/webapps/"
RUN printf 'environment=ee8\n' > "${JETTY_BASE}/webapps/petclinic.properties"

COPY stage2/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

LABEL org.opencontainers.image.title="petclinic" \
      org.opencontainers.image.version="${JETTY12_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.description="PetClinic v5.3.22 Jetty 12.1 ee8 — build ${BUILD_NUMBER}" \
      io.github.netrun-systems.legacy-lab.pci.sbom="sbom-${GIT_COMMIT}.json" \
      io.github.netrun-systems.legacy-lab.pci.signed="cosign"

ENTRYPOINT ["/entrypoint.sh"]

# ---------------------------------------------------------------------------
# Jetty 9.4.58 runtime (for legacy rebuild if needed)
# ---------------------------------------------------------------------------
# eclipse-temurin:21-jre-noble pinned by digest 2026-10-29
FROM eclipse-temurin@sha256:161310cd5bd41fd549d19cf9f90b614897cb4a1532555c613b43b7e0628fe5d6 AS jetty94
ARG JETTY94_VERSION MAVEN_CENTRAL GIT_COMMIT BUILD_NUMBER

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

COPY stage2/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
