#!/usr/bin/env bash
# Phase 1 lab: runtime currency with zero Java code changes.
#
# Builds the last javax-era Spring Framework PetClinic (tag v5.3.22: Spring 5.3,
# javax.servlet, Java 8 bytecode, H2 by default, MySQL profile available) and runs
# the SAME WAR side by side on:
#   - Jetty 9.4.58  (the "before": end of community support, no public releases after 2026-01-01)
#   - Jetty 12.1.14 (the "after": ee8 environment, so javax code runs unchanged)
#
# Needs: git, curl, a JDK 17+ (JDK 21 recommended; Jetty 12 requires 17+), ~600 MB disk.
# Usage:   ./phase1-jetty12-ee8.sh            # H2 in-memory database
#          PROFILE="-P MySQL" ./phase1-jetty12-ee8.sh   # MySQL at localhost:3306/petclinic (user/pass petclinic)
# Stop:    kill $(cat "$WORK"/*.pid)

set -euo pipefail

WORK=${WORK:-$HOME/legacy-java-modernization-lab/phase1}
JETTY12=12.1.14
JETTY94=9.4.58.v20250814
MAVEN=3.9.11
CENTRAL=https://repo.maven.apache.org/maven2   # repo1.maven.org rate-limits aggressively; this mirror is the same content
PORT94=${PORT94:-8094}
PORT12=${PORT12:-8012}

mkdir -p "$WORK" && cd "$WORK"

fetch() { [ -s "$2" ] || curl -fsSL --retry 3 -o "$2" "$1"; }
untar() { [ -d "$2" ] || tar xzf "$1"; }

echo "== 1. Source: last javax-era tag"
[ -d spring-framework-petclinic ] || git clone -q https://github.com/spring-petclinic/spring-framework-petclinic.git
git -C spring-framework-petclinic checkout -q v5.3.22

echo "== 2. Tools: Maven $MAVEN, Jetty $JETTY94, Jetty $JETTY12"
fetch "$CENTRAL/org/apache/maven/apache-maven/$MAVEN/apache-maven-$MAVEN-bin.tar.gz" maven.tgz
untar maven.tgz "apache-maven-$MAVEN"
fetch "$CENTRAL/org/eclipse/jetty/jetty-home/$JETTY94/jetty-home-$JETTY94.tar.gz" jetty94.tgz
untar jetty94.tgz "jetty-home-$JETTY94"
fetch "$CENTRAL/org/eclipse/jetty/jetty-home/$JETTY12/jetty-home-$JETTY12.tar.gz" jetty12.tgz
untar jetty12.tgz "jetty-home-$JETTY12"
mkdir -p "$HOME/.m2"
[ -f "$HOME/.m2/settings.xml" ] || cat > "$HOME/.m2/settings.xml" <<EOF
<settings><mirrors><mirror><id>central-mirror</id><mirrorOf>central</mirrorOf><url>$CENTRAL</url></mirror></mirrors></settings>
EOF

echo "== 3. Build the WAR ${PROFILE:-(H2 default)}"
( cd spring-framework-petclinic && "../apache-maven-$MAVEN/bin/mvn" -q -B -DskipTests -Djacoco.skip=true ${PROFILE:-} package )
cp spring-framework-petclinic/target/petclinic.war petclinic.war

echo "== 4. The one non-code fix"
# The WAR ships WEB-INF/jetty-web.xml naming Jetty 9's org.eclipse.jetty.webapp.WebAppContext.
# On Jetty 12 that class moved to org.eclipse.jetty.ee8.webapp.WebAppContext, and the context
# fails with ClassNotFoundException (HTTP 503). Jetty 12 reads WEB-INF/jetty-ee8-web.xml first;
# Jetty 9.4 ignores it. Adding it keeps ONE artifact deployable on both runtimes.
mkdir -p patch/WEB-INF
cat > patch/WEB-INF/jetty-ee8-web.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE Configure PUBLIC "-//Jetty//Configure//EN" "https://jetty.org/configure_10_0.dtd">
<Configure class="org.eclipse.jetty.ee8.webapp.WebAppContext">
    <Set name="parentLoaderPriority">true</Set>
</Configure>
EOF
( cd patch && jar uf ../petclinic.war WEB-INF/jetty-ee8-web.xml )

echo "== 5. Jetty bases"
if [ ! -d base94 ]; then
  mkdir base94 && ( cd base94 && java -jar "../jetty-home-$JETTY94/start.jar" --add-to-start=http,deploy,jsp,jstl,annotations >/dev/null 2>&1 )
fi
if [ ! -d base12 ]; then
  # Jetty 12 enables only core modules by default. Without an eeN-deploy module the WAR is silently NOT deployed.
  mkdir base12 && ( cd base12 && java -jar "../jetty-home-$JETTY12/start.jar" --add-modules=server,http,ee8-deploy,ee8-apache-jsp,ee8-glassfish-jstl >/dev/null 2>&1 )
fi
cp petclinic.war base94/webapps/
cp petclinic.war base12/webapps/
# Pin the environment explicitly; an unpinned WAR is deployed to the newest enabled environment.
printf 'environment=ee8\n' > base12/webapps/petclinic.properties

echo "== 6. Start both"
start() { # $1=base $2=jetty-home $3=port
  ( cd "$1" || exit 1
    nohup java -jar "../$2/start.jar" "jetty.http.port=$3" > "../$1.log" 2>&1 < /dev/null &
    echo $! > "../$1.pid" )
}
start base94 "jetty-home-$JETTY94" "$PORT94"
start base12 "jetty-home-$JETTY12" "$PORT12"

check() { # $1=port $2=label
  local code=000
  for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/petclinic/owners?lastName=" || true)
    [ "$code" = 200 ] && break
    sleep 2
  done
  echo "$2 -> HTTP $code  http://127.0.0.1:$1/petclinic/"
}
check "$PORT94" "Jetty 9.4.58 (before)"
check "$PORT12" "Jetty 12.1.14 ee8 (after)"

echo
echo "Logs: $WORK/base94.log  $WORK/base12.log"
echo "Stop: kill \$(cat $WORK/*.pid)"
