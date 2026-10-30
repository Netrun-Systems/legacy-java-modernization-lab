FROM jenkins/jenkins:lts-jdk21

# Install: Docker CLI (to talk to DinD), Maven, cosign.
# Trivy and Syft run via docker run in the pipeline (pinned image digest),
# so they don't live in this image.
USER root

RUN apt-get update -qq && apt-get install -y -qq \
    curl wget git maven socat gnupg ca-certificates 2>/dev/null

# Docker CLI only (no daemon - connects to DinD sidecar via DOCKER_HOST)
# jenkins/jenkins:lts-jdk21 is Debian Bookworm-based
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] \
      https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update -qq && apt-get install -y -qq docker-ce-cli 2>/dev/null

# cosign v2.5.0 - key-based signing for lab (not Fulcio/OIDC;
# Jenkins can't issue OIDC tokens, and CDE segmentation may rule out public Rekor)
RUN curl -fsSL -o /usr/local/bin/cosign \
    "https://github.com/sigstore/cosign/releases/download/v2.5.0/cosign-linux-amd64" && \
    chmod +x /usr/local/bin/cosign && \
    cosign version

# Skip setup wizard (credentials/plugins configured via JCasC / init.groovy)
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
ENV JENKINS_OPTS="--httpPort=8080"

# Allow Jenkins to run Docker commands without sudo
RUN groupadd -f docker && usermod -aG docker jenkins

# Allow git to access the workspace volume (mounted from Windows host, uid mismatch).
# Set as system-level config (/etc/gitconfig) so it survives the /var/jenkins_home volume mount.
RUN git config --system --add safe.directory '*'

USER jenkins

# Pre-install required plugins list (resolved at container start)
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
