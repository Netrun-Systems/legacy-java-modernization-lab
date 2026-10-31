# legacy-java-modernization-lab: Moving a javax WAR off an end-of-life Jetty into a signed, container-delivered, zero-downtime-cutover pipeline

Technical white paper on the legacy-java-modernization-lab build.

## 0. How to read this paper

- Every digest, HTTP code, version, error message and count below comes from the repo and from `git log -p`. Where a fact is not in those sources the text says **not recorded**.
- "Exactly as recorded" blocks are copied from the git history. Where a block is abbreviated, it says so.
- Documentation notes follows the corrections you gave:
  - PCI DSS 4.0 req 6.3.3 means critical patches within one month.
  - The old v3.2.1 inventory requirement 2.4 is now 12.5.1.
  - No PCI SSC position says immutable images satisfy 11.5.2.
  - Jetty 9/10/11 public EOL was 2026-01-01.
  - MySQL 8.0 EOL was 2026-04-30.
- No secret values appear. Environment variable *names* do. The lab has default credentials in several committed files; they are described, never quoted.
- Stage 2 was reworked after the first write-up. Section 4 now carries the build-26 results on the Jenkins-signed digest. Two items from that rework are **not recorded** (listed in section 4.5).

## 1. Problem framing

The target is a legacy `javax.*` WAR on a Jetty line that no longer gets public releases. The goal is to move it to a supported runtime, packaged as an image that CI builds, scans and signs, delivered to hosts by digest, and cut over by moving load-balancer weight rather than by redeploying.

The stand-in application is Spring PetClinic `v5.3.22`, the last `javax`-era tag: Spring 5.3, `javax.servlet`, Java 8 bytecode, H2 by default, MySQL profile available. It contains no production-system code. The lab mirrors the *shape* of a typical legacy Java web application, not any specific real-world deployment.

Why this is a compliance problem, not only a modernisation one:

| Clock | Fact | Consequence |
|---|---|---|
| Jetty 9/10/11 | Public releases ended 2026-01-01 | Security fixes only via commercial support |
| PCI DSS 4.0 req 6.3.3 | Critical patches within one month | Needs a rebuild, rescan, redeploy cycle measured in days |
| MySQL 8.0 | EOL 2026-04-30 | The lab's database CT really ran 8.0.36 (Ubuntu package) until remediation `092489f`; it now runs MySQL 8.4.13 Community Server (section 6.1) |
| PCI DSS 12.5.1 | Inventory of in-scope components; guidance includes containers or images that may be instantiated | Image digests become inventory items |

The delivery strategy, in order, each step shippable alone:

1. Runtime currency in place: Jetty 12.1 `ee8`, so the WAR and its `javax.servlet` code do not change.
2. Externalise configuration so one artifact runs against any database.
3. CI builds one image, produces an SBOM, scans it, signs it by digest, pushes it.
4. Hosts run that digest under systemd. The digest lives in config management (Hiera). HAProxy weights move traffic.
5. Observability parity (Prometheus, Alertmanager, Grafana, Splunk): built and verified (section 7); two defects found and fixed along the way.

## 2. Architecture

```
 WORKSTATION workstation.lab.example   (Windows 11, Docker Desktop, context desktop-linux, 16 CPU)
 +-----------------------------------------------------------------------------------+
 |  docker compose, network lab-net                                               |
 |                                                                                   |
 |  lab-jenkins :8080  --DOCKER_HOST=tcp://lab-dind:2375-->  lab-dind       |
 |   (lts-jdk21, docker CLI,                                        (docker:27.4-dind,|
 |    cosign v2.5.0)                                                 privileged)     |
 |        |                                                              |           |
 |        | git file:///workspace (repo mounted :ro)                     | docker save -> .tar
 |        |                                                              v           |
 |        |                                     Syft, Trivy run as `docker run` of   |
 |        |                                     digest-pinned images against the tar |
 |        | push by digest, then cosign sign / verify                                |
 |        +------------------------------------------------> lab-registry :5000   |
 |                                                          (registry:2, plain HTTP) |
 +-----------------------------------------------------------------------------------+
                                  |  LAN  10.0.0.0/24 (example; replace with your LAN subnet)
                                  |  LXCs pull  registry.lab.example:5000/petclinic@sha256:...
 HYPERVISOR HOST hypervisor.lab.example  (Proxmox; also the NAT gateway for the CTs)
 +-----------------------------------------------------------------------------------+
 |  legacy-app legacy-app     legacy-app.lab.example  Jetty 9.4.58 under systemd, OpenJDK 21   |
 |  container-app container-app  container-app.lab.example  Docker 29.1.3; app container at a digest |
 |  lb lb    lb.lab.example  HAProxy 2.8.30; :80 front, :8404 stats   |
 |  db db      db.lab.example  MySQL 8.4.13 (was 8.0.36 until 092489f)   |
 |                                                                                   |
 |  monitor monitor    monitor.lab.example  Prometheus, Alertmanager, Grafana (Docker)|
 |  log-indexer log-indexer     log-indexer.lab.example  Splunk Enterprise 10.6.1.1 (trial)       |
 |  UF 10.6.1.1 on lab containers -> 9997 on log-indexer; Prometheus scrapes all 6 hosts (11 targets) |
 |  Planned in README, never created: openvox server, mysql replica.                 |
 +-----------------------------------------------------------------------------------+

 client -> lb:80 -> weighted round-robin -> legacy-app:8080 (legacy) | container-app:8080 (container)
```

Allocations, as read from Proxmox (`pct config`):

| CT | Name | IP | RAM | Disk |
|---|---|---|---|---|
| 730 | legacy-app | legacy-app.lab.example | 1536 MB | 20 GB |
| 731 | container-app | container-app.lab.example | 1536 MB | 20 GB |
| 732 | lb | lb.lab.example | 512 MB | 10 GB |
| 733 | db | db.lab.example | 2048 MB | 20 GB |
| 734 | monitor | monitor.lab.example | 2048 MB | 20 GB |
| 735 | log-indexer | log-indexer.lab.example | 6144 MB (2 cores) | 40 GB |

monitor and 735 sizes are `pct config` values. NOTES and an earlier draft of this paper said log-indexer had 4 GB / 32 GB; `03f50c2` corrected that to the measured 6144 MB / 40 GB (retrospective R15).

Pinning inventory (`NOTES.md` plus `docker-compose.yml`):

| Item | Reference | By sha256? |
|---|---|---|
| Trivy | `aquasec/trivy@sha256:94711c60051c6cab848a292e3a67f62623fcee361b2bb661f43b17184f4afdac` (v0.67.0) | yes |
| Syft | `anchore/syft@sha256:f1099806495b4d2300adf03887bdfb69230c36a5e077061a12ee292bcd9bfd62` | yes |
| JDK builder | `eclipse-temurin@sha256:bd6ac06e2a2df928af21c75c4a8a0f2829a93377a65761d6a577bb32281e2ac3` | yes |
| JRE runtime | `eclipse-temurin@sha256:161310cd5bd41fd549d19cf9f90b614897cb4a1532555c613b43b7e0628fe5d6` | yes |
| cosign | `v2.5.0` tag; binary fetched by `curl` in the Jenkins Dockerfile, no checksum step | no |
| dind, jenkins, registry | `docker:27.4-dind`, `jenkins/jenkins:lts-jdk21`, `registry:2` | no |
| Jenkins plugins | `:latest` | no |

Digests for the unpinned images were resolved on 2026-10-29 but only Trivy, Syft and the two Temurin images use them in the build.

## 3. Stage 1: Jetty 9.4 to Jetty 12.1 `ee8`

### What it does
Runs the identical WAR on Jetty 9.4.58.v20250814 ("before") and Jetty 12.1.14 with the `ee8` environment ("after"). Two things are needed for Jetty 12:

- `WEB-INF/jetty-ee8-web.xml` pointing at `org.eclipse.jetty.ee8.webapp.WebAppContext`, because the WAR's `jetty-web.xml` names the Jetty 9 class that moved. Jetty 9.4 ignores the file, so one artifact serves both.
- A `webapps/petclinic.properties` containing `environment=ee8`, because an unpinned WAR is deployed to the newest enabled environment (a `jakarta` one would fail on `javax` classes).

### Why it matters
Operationally: the app moves to a supported servlet container with zero application code change, and the move can be validated on its own for a release cycle. For PCI: this is the 6.3.3 enabler, because patches exist again; and it feeds the annual end-of-life review (12.3.4). Per the research notes the Gitiles project made the same move (9.4.57 to 12.1.10 on the `ee8` modules) and deferred `jakarta`.

### Key config, quoted from `phase1/phase1-jetty12-ee8.sh`
```bash
cat > patch/WEB-INF/jetty-ee8-web.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE Configure PUBLIC "-//Jetty//Configure//EN" "https://jetty.org/configure_10_0.dtd">
<Configure class="org.eclipse.jetty.ee8.webapp.WebAppContext">
    <Set name="parentLoaderPriority">true</Set>
</Configure>
EOF
( cd patch && jar uf ../petclinic.war WEB-INF/jetty-ee8-web.xml )
...
mkdir base12 && ( cd base12 && java -jar "../jetty-home-$JETTY12/start.jar" --add-modules=server,http,ee8-deploy,ee8-apache-jsp,ee8-glassfish-jstl >/dev/null 2>&1 )
...
printf 'environment=ee8\n' > base12/webapps/petclinic.properties
```
Note `--add-modules` is run with the working directory *inside* the base. That is why it worked in the script and failed in the Dockerfile (section 4.3).

### Verification, exactly as recorded
The script had never run anywhere before this lab (you corrected the "tested" claim). First run: 2026-10-29, inside `eclipse-temurin:21-jdk-noble` on Docker Desktop, no host JDK.
```
== 1. Source: last javax-era tag
== 2. Tools: Maven 3.9.11, Jetty 9.4.58.v20250814, Jetty 12.1.14
== 3. Build the WAR (H2 default)
== 4. The one non-code fix
== 5. Jetty bases
== 6. Start both
Jetty 9.4.58 (before) -> HTTP 200  http://127.0.0.1:8094/petclinic/
Jetty 12.1.14 ee8 (after) -> HTTP 200  http://127.0.0.1:8012/petclinic/
```
The script's own `check()` curls `/petclinic/owners?lastName=` (a database-backed page) although the label prints `/petclinic/`. The checked copy in `phase1/` is byte-identical to the original downloaded WAR.

The Jetty 9.4 legacy host (legacy-app) was also brought up under systemd and returned HTTP 200 after its own fixes (retrospective, E05 to E08).

## 4. Stage 2: configuration moved out of the WAR (H2 / MySQL)

### What it does
`stage2/entrypoint.sh` turns environment variables into JVM system properties; Spring's property placeholder resolves them ahead of the file defaults. The intent: **one signed artifact**, with the database chosen at deploy time and no secrets in the WAR or image.

Environment variable names (values never recorded here): `JDBC_URL`, `JDBC_USER`, `JDBC_PASSWORD`, `JDBC_DRIVER_CLASS`, `DB_SCRIPT`, `JPA_DATABASE`, plus `PORT`, `TZ`, `JAVA_OPTS`.

### Why it matters
Operationally: the same digest is promoted unchanged from dev (H2) to prod (MySQL); a rebuild per environment would break traceability. For PCI: 8.6.2 forbids system-account passwords in scripts, config or property files, and the digest-to-deploy trail (6.5.1) only means something if the artifact is not mutated per environment.

### Key config
`entrypoint.sh` (current):
```bash
JAVA_OPTS="${JAVA_OPTS} -Djdbc.url=${JDBC_URL:-jdbc:mysql://localhost:3306/petclinic}"
JAVA_OPTS="${JAVA_OPTS} -Djdbc.username=${JDBC_USER:-<default omitted>}"
JAVA_OPTS="${JAVA_OPTS} -Djdbc.password=${JDBC_PASSWORD:-<default omitted>}"
JAVA_OPTS="${JAVA_OPTS} -Djdbc.driverClassName=${JDBC_DRIVER_CLASS:-com.mysql.cj.jdbc.Driver}"
JAVA_OPTS="${JAVA_OPTS} -Djdbc.initLocation=classpath:db/${DB_SCRIPT:-mysql}/schema.sql"
JAVA_OPTS="${JAVA_OPTS} -Djdbc.dataLocation=classpath:db/${DB_SCRIPT:-mysql}/data.sql"
JAVA_OPTS="${JAVA_OPTS} -Djpa.database=${JPA_DATABASE:-MYSQL}"
...
exec java ${JAVA_OPTS} -jar "${JETTY_HOME}/start.jar" "jetty.base=${JETTY_BASE}" "jetty.http.port=${PORT:-8080}"
```
The entrypoint's MySQL fallbacks include a default credential. That is a finding (see 6.3 for the WAR's own upstream defaults).

`stage3/patch_war.py` rewrites the built WAR (abbreviated):
```python
xml = xml.replace('p:driverClassName="com.mysql.cj.jdbc.Driver"', 'p:driverClassName="${jdbc.driverClassName}"')
xml = xml.replace('p:url="jdbc:mysql://localhost:3306/petclinic?useUnicode=true"', 'p:url="${jdbc.url}"')
xml = xml.replace('p:username="<lab default>"', 'p:username="${jdbc.username}"')
xml = xml.replace('p:password="<lab default>"', 'p:password="${jdbc.password}"')
xml = xml.replace('<jdbc:initialize-database data-source="dataSource">',
                  '<jdbc:initialize-database data-source="dataSource" ignore-failures="ALL">')
# data-access.properties: initLocation/dataLocation -> classpath:db/${db.script}/...
# inject WEB-INF/lib/h2-2.1.214.jar when /tmp/h2.jar exists (MySQL-profile build omits H2)
```
The Dockerfile downloads the H2 jar from Maven Central into `/tmp/h2.jar` before the patch step and deletes it after.

Why the patch is needed: the cloned source has `${jdbc.*}` placeholders, but the WAR built with `-P MySQL` contains literals (the transcript compared the two). That is consistent with Maven resource filtering applying the profile's values at package time; the mechanism was inferred, not read from the pom.

### 4.1 The first "proof" and why it was not one
`f9d4d7d` recorded H2 and MySQL both returning 200 on `sha256:f2f1cb5586a4932580f0d732b1b0591109baa8c72d4e5eaa2b03262e089db34f`. That image (`h2mysql-proof`) was a side build `FROM` an ad-hoc image (`petclinic:fixed4`) with a WAR hand-patched on legacy-app. It was never signed by Jenkins. The check URL was `/petclinic/` only, and the H2-mode log line `HHH000400: Using dialect: org.hibernate.dialect.MySQL57Dialect` showed the Hibernate dialect had not followed `JPA_DATABASE=H2`. The same build 16 digest, and builds 24 and 25, failed when tested for real (4.3).

### 4.2 The Jenkins-signed digests, as recorded
| Build | Commit | Registry digest | Result on that digest |
|---|---|---|---|
| 16 | `a1cac10` | `sha256:cefa443ba2568ff42c276c479576735a09a34d882df5ba7465c7149531718530` | App container up, Jetty `STARTING`, HTTP 404; no `start.d` in image; DB URL baked to localhost |
| 24 | `32669b0` | `sha256:fabfc4098c30c9e9ff7449c4641f1a428352ce611ce0f1df1ef467c28b893ee2` | H2 run: HTTP 000, `ERROR : No enabled jetty modules found!` |
| 25 | `54eb22b` | `sha256:4ba639e4ef163b82a7a51a47a5e0c80b43c40b01cb0db254e21e3d3d492179cc` | H2 run: HTTP 503 on both paths; `Driver:org.h2.Driver@... returned null for URL:jdbc:mysql://localhost:3306/petclinic?useUnicode=true` |
| 26 | `510ea50` | `sha256:f1a2edaec14300cd4e3cd29966c7248ef5f7de024bf12e71e79ef1e4af30203d` | See 4.4 |

### 4.3 Root causes found along the way (detail in the retrospective)
- `--add-modules` combined with `--jetty.base=...` is silently ignored by Jetty 12's `start.jar`; the Dockerfile now writes `start.d/*.ini` directly. The log symptom was `WARN : Argument: --jetty.base=/var/lib/jetty (interpreted as a JVM argument, from <command-line>)`.
- The entrypoint used `--jetty.base=`; Jetty 12 wants `jetty.base=` with no dashes.
- The WAR held literal JDBC url, username and password in `datasource-config.xml`, so `-Djdbc.url` had nothing to override. This was latent from build 16.

### 4.4 Build 26 results (rework complete)
Source of these results: `git log -p` through the rework commits. Where a detail is not recorded there, the text says **not recorded**.

- Build 26, commit `510ea50`, digest `sha256:f1a2edaec14300cd4e3cd29966c7248ef5f7de024bf12e71e79ef1e4af30203d`.
- SBOM: `sbom-510ea50.json`.
- Trivy gate passed with `--ignore-unfixed` plus `.trivyignore` (`--exit-code 1`).
- `cosign verify` exited 0 against that digest.
- Image pulled strictly by digest (`docker pull registry.lab.example:5000/petclinic@sha256:f1a2...`); `docker inspect` confirmed the same digest for each run.
- H2 (in-memory) and MySQL (db): each returned HTTP 200 on `/petclinic/` and `/petclinic/owners?lastName=`, with no rebuild.
- The transcript's H2 run, exactly as recorded:
```
=== HTTP / ===
200
=== HTTP /owners?lastName= ===
200
=== docker inspect (proves digest) ===
registry.lab.example:5000/petclinic@sha256:f1a2edaec14300cd4e3cd29966c7248ef5f7de024bf12e71e79ef1e4af30203d
```
- Env var names used for the two runs: `JDBC_DRIVER_CLASS`, `JDBC_URL`, `JDBC_USER`, `JDBC_PASSWORD`, `DB_SCRIPT`, `JPA_DATABASE`. For H2 the values are the public in-memory defaults (user `sa`, empty password); no other credential is quoted anywhere.

### 4.5 Not recorded
- (Resolved in 6.5.) Trivy counts for build 26 are now recorded: raw 23C/82H, 23C/80H after `--ignore-unfixed`, 0/0 with the ignore file.
- The MySQL write plus read-back row count (a `SELECT count` on the owners table before and after an insert). The 200 on `/owners?lastName=` shows a database-backed page rendered; it does not show a write.
- (Resolved in 6.5.) The new-key `cosign verify` text for build 26 is recorded verbatim there; the original build-26 verify text (old key) is not.

> PENDING (closed): build N = 26. Fields above are filled from the coordinator's report. The two not-recorded items remain open. Build 26's Trivy counts are now in section 6.5 (raw 23C/82H, 23C/80H after `--ignore-unfixed`, 0/0 with the ignore file).

## 5. Stage 3: Jenkins build, Syft SBOM, Trivy gate, cosign sign/verify, private registry

### What it does
`stage3/Jenkinsfile` stages: Checkout, Build Image, Export image tar, SBOM (Syft, CycloneDX), Scan (Trivy), Push, Sign (cosign), Verify, Record commit to digest. The image is built in DinD from `stage3/Dockerfile`, saved to a tar (the Jenkins container has no `docker.sock`), and Syft and Trivy run as digest-pinned containers against the tar.

### Why it matters
Operationally: a rebuild-rescan-redeploy cycle that is automatic, so 6.3.3's one-month clock is achievable. For PCI: 6.3.2 (SBOM of bespoke software and third-party components), 6.5.1 (changes traceable to records; the `digest-log.txt` line carries commit, build, image tag and digest), 12.5.1 (image inventory). The Trivy supply-chain compromise of 2026-03-19 (v0.69.4 to 0.69.6) is why Trivy is pinned by digest at 0.67.0. Key-based cosign is used because Jenkins does not issue OIDC tokens natively and CDE egress policy may block public Rekor.

### Key config (`stage3/Jenkinsfile`, current)
```groovy
TRIVY_IMAGE = "aquasec/trivy@sha256:94711c60051c6cab848a292e3a67f62623fcee361b2bb661f43b17184f4afdac"
SYFT_IMAGE  = "anchore/syft@sha256:f1099806495b4d2300adf03887bdfb69230c36a5e077061a12ee292bcd9bfd62"
...
docker run --rm -v $(pwd):/work ${env.SYFT_IMAGE} docker-archive:/work/petclinic-<sha>.tar -o cyclonedx-json=/work/sbom-<sha>.json
...
docker run --rm -v $(pwd):/work ${env.TRIVY_IMAGE} --timeout 15m image \
  --severity CRITICAL,HIGH --ignore-unfixed --ignorefile /work/.trivyignore \
  --format table --output /work/trivy-report-<sha>.txt --exit-code 1 --input /work/petclinic-<sha>.tar
...
cosign sign --key /var/jenkins_home/cosign.key --yes --allow-insecure-registry --allow-http-registry "<registry>/petclinic@<digest>"
cosign verify --key /var/jenkins_home/cosign.pub --allow-insecure-registry --allow-http-registry "<registry>/petclinic@<digest>"
```
Gate policy: fail on any un-ignored CRITICAL or HIGH that has a fix. `.trivyignore` holds 94 `CVE-` lines: 93 IDs from the build-16 report (102 findings, 23 CRITICAL, 79 HIGH, all in `petclinic.war` jars, zero in Ubuntu packages) plus `CVE-2022-45868` for the injected H2 jar (web console never started). It is a risk-acceptance baseline, not a fix.

### Verification, exactly as recorded
Build 16 (commit `a1cac10`, 2026-10-30T02:47:12Z):
```
2026-10-30T02:47:12Z commit=a1cac10 build=16 image=lab-registry:5000/petclinic:a1cac10-20261030T024410Z digest=sha256:cefa443ba2568ff42c276c479576735a09a34d882df5ba7465c7149531718530
Total: 102 (HIGH: 79, CRITICAL: 23)

Verification for lab-registry:5000/petclinic@sha256:cefa443ba2568ff42c276c479576735a09a34d882df5ba7465c7149531718530 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The signatures were verified against the specified public key
```
(The verify JSON that follows is omitted here; `cosign` exit code 0.) The same verify also passed from container-app against `registry.lab.example:5000/petclinic@sha256:cefa443...`, exit 0.

Gate behaviour seen live: build 20 failed with `Trivy gate FAILED: CRITICAL or HIGH vulnerabilities found that are not in .trivyignore` against the partial first ignore list, proving the gate had teeth. Build 21 hit `walk dir error: context deadline exceeded`; builds 23 and 24 are in the retrospective. Build 24 passed the gate.

Registry tag list at 03:50Z shows the SCM poll built an image for each commit and `latest` moved; only digests are used downstream.

### Caveats
- SBOM contents were never opened; component counts are not recorded.
- Trivy fetches its vulnerability DB (about 131 MiB) at scan time. The scanner binary is pinned; its data is not.
- The cosign key is copied into the `jenkins-home` volume by hand; no script in the repo does it. After `092489f` the key pair was replaced, and the passphrase and Jenkins admin password are `${VAR}` references to a gitignored `.env` (old values are dead but remain in local git history). `scripts/gen-keys.sh` still says "empty passphrase".
- The PowerShell UTF-8 BOM round-trip that caused the Mojibake issue (see Retrospective F19) has been corrected; no mojibake sequences remain in the repository.

## 6. Stage 4: OpenVox/Hiera digest pinning and HAProxy weighted canary, cutover, rollback

### What it does
Hiera holds `petclinic::image_digest`. The `petclinic::container` class pulls `registry/image@digest`, renders a systemd unit that runs that digest, and re-creates the container if the running image differs. HAProxy fronts both hosts with legacy weight 100 and container weight 0; weights move through the admin socket without a reload.

**Status of OpenVox (updated by `092489f`):** OpenVox 7.37.2 is installed on container-app from the official Vox Pupuli deb and the manifests are applied **masterless** (`puppet apply`; no server). The first apply exited 2 (changes applied: a systemd unit, and the container started on the pinned digest). Before this pass nothing had been applied; hosts had been built by shell scripts.

### Why it matters
Operationally: rollback is a weight change, not a redeploy, and the artifact on the host is provably the one CI signed. For PCI: Hiera in git gives an auditable, reviewable record of which digest was intended on which host (6.5.1, 12.5.1). Drift detection against the signed digest is a *component* of 11.5.2 change detection, not a replacement for host file-integrity monitoring: no PCI SSC position says immutable images satisfy 11.5.2.

### Key config
`stage4/haproxy/haproxy.cfg` (current):
```
backend petclinic
    balance roundrobin
    option httpchk
    http-check send meth GET uri /petclinic/owners?lastName= ver HTTP/1.1 hdr Host localhost
    server legacy-app    legacy-app.lab.example:8080 weight 100 check inter 5s
    server container-app container-app.lab.example:8080 weight 0   check inter 5s
```
Hiera, `container-app.yaml` (pinned to build 26 by `775a06b`):
```yaml
petclinic::image_digest: "sha256:f1a2edaec14300cd4e3cd29966c7248ef5f7de024bf12e71e79ef1e4af30203d"
petclinic::jdbc_url: "jdbc:mysql://db.lab.example:3306/petclinic"
```
`petclinic-container.service.erb`:
```
ExecStart=/usr/bin/docker run --name petclinic --rm -p <%= @port %>:8080 \
  -e JDBC_URL=... -e JDBC_USER=... -e JDBC_PASSWORD=... \
  <%= @registry %>/<%= @image_name %>@<%= @image_digest %>
```
Weight changes: `echo "set weight petclinic/container-app 10" | socat - UNIX-CONNECT:/var/run/haproxy/admin.sock` (wrapped by `stage4/scripts/flip-weights.sh canary|cutover|rollback|status`). Weight 0 keeps the server in the pool (health-checked, no new traffic), so rollback takes effect immediately.

### Verification, exactly as recorded
Earlier run (commit message `ebdbc99`; raw transcript output below). **Caveat: container-app was then running the ad-hoc `petclinic:fixed4` image (`sha256:53c9fdbb757e89e2812981b9e4ec8fd2cd1430d23e6313b77735f7819f9da334`), not the Jenkins-signed digest.**
```
legacy-app        wght=100   status=UP       rq_tot=0
container-app     wght=0     status=UP       rq_tot=0
Sample request: 200 200 200 200 200 200 200 200 200 200          (baseline)
CANARY legacy=90 container=10   -> 200 x10, then 200 x10
CUTOVER legacy=0 container=100  -> 200 x10, then 200 x5
ROLLBACK legacy=100 container=0 -> 200 x10, then 200 x3
```
The commit text summarises these as 10x, 10x and 3x HTTP 200.

Rework on the Jenkins-signed build-26 digest (coordinator's report, after `775a06b`): container-app redeployed by digest; HAProxy `status`, `canary` (90/10) and `rollback` each returned HTTP 200 on 5 of 5 requests. Per-request detail beyond that is not recorded.

### Caveats
- Resolved in `092489f`: the OpenVox module's `files/haproxy.cfg` now uses `http-check send`, matching `stage4/haproxy/haproxy.cfg`.
- The CTs' gateway and DNS were fixed at runtime only; `pct config` still shows `gw=gateway.lab.example`. A CT reboot would lose them.
- The README still says HAProxy 2.9; the host runs HAProxy 2.8.30-0ubuntu0.24.04.1. The earlier "MySQL 8.4" claims in NOTES were wrong when written (the host ran 8.0.36); they became true only with `092489f`.
- Resolved in `092489f`: the Hiera DB password moved to gitignored `stage4/openvox/hiera/data/secrets.yaml` (a new hierarchy level) and the credential was rotated.

### 6.1 Remediation pass `092489f` (facts as reported)
Verified by the coordinator: db runs MySQL 8.4.13 (Community Server); container-app runs OpenVox 7.37.2. Reported by the agent:
- MySQL: the APT component was fixed from `mysql-8.4` to `mysql-8.4-lts`; an expired MySQL repo signing key was refreshed (`RPM-GPG-KEY-mysql-2025`, new expiry 2027-10-23); the package is `mysql-community-server`; the owners count (10) was preserved across the upgrade. The write test passed on 8.4.13.
- Config: `petclinic-container.service.erb` gained the missing `JDBC_DRIVER_CLASS`, `DB_SCRIPT`, `JPA_DATABASE`; the Hiera JDBC URL gained MySQL 8.4 connection parameters.

### 6.2 OpenVox masterless run and drift test
- First `puppet apply` exited 2 (changes applied): systemd unit written, container started on the pinned digest.
- Drift test, as reported: the running container was swapped to `:latest`, apply was re-run, and the pinned digest came back. This is the evidence behind the "digest enforcement" claim, on one host and masterless.
- A Hiera datadir mismatch (`hieradata` vs `hiera/data`) took several iterations to find (retrospective R03).
- Still not done: an OpenVox server, scheduled runs, host file-integrity monitoring.

### 6.3 Twelve-factor caveat: upstream defaults are still baked into the WAR
`WEB-INF/classes/spring/data-access.properties` still contains the upstream PetClinic default JDBC properties, including a default username and password (values not quoted). The entrypoint overrides them at runtime with `-Djdbc.*`, so the running app uses injected values, but the defaults remain in the shipped artifact and image layers. A reviewer applying 12-factor III or PCI 8.6.2 will ask: "if the override is missing, what does the app connect with?" Honest answer: it falls back to those upstream defaults (and localhost), so the control is the override, not the absence of a secret. Mitigations to propose: blank them at build time in `patch_war.py`, fail closed when `JDBC_PASSWORD` is unset, and scan layers for credential patterns. The public H2 in-memory defaults (`sa`, empty password) are the only credentials safe to mention.

### 6.4 Secrets out of git (rotate, not rewrite)
The `:-` fallbacks in `casc.yaml` and `docker-compose.yml` were removed (pure env references); the Hiera `mysql::password` moved to gitignored `secrets.yaml`. A new cosign keypair was made (`keys/cosign.pub` changed) and the Jenkins admin, MySQL application and cosign passphrase credentials were rotated. **Git history was not rewritten**: old values remain in local history and are now dead.

### 6.5 Re-verification after remediation (as reported)
- HAProxy `status`, `canary` 90/10, `cutover` 0/100 and `rollback` all returned HTTP 200. Per-request counts are not recorded.
- **Build 26 re-signed, not rebuilt.** The digest is unchanged: `sha256:f1a2edaec14300cd4e3cd29966c7248ef5f7de024bf12e71e79ef1e4af30203d`. Command as reported:
```
cosign sign --key /keys/cosign.key --allow-http-registry --allow-insecure-registry --yes --tlog-upload=false
```
  `cosign verify` with the new public key, exactly as recorded:
```
[{"critical":{"identity":{"docker-reference":"registry.lab.example:5000/petclinic"},"image":{"docker-manifest-digest":"sha256:f1a2edaec14300cd4e3cd29966c7248ef5f7de024bf12e71e79ef1e4af30203d"},"type":"cosign container image signature"},"optional":null}]

Verification for registry.lab.example:5000/petclinic@sha256:f1a2edaec14300cd4e3cd29966c7248ef5f7de024bf12e71e79ef1e4af30203d --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
verify exit: 0
```
  Compare with build 16: the transparency-log line ("Existence of the claims in the transparency log was verified offline") is absent, and `optional` is `null` instead of a Bundle with a SignedEntryTimestamp, because `--tlog-upload=false` was used. This is the offline/air-gapped signing trade-off: no public Rekor entry proving when the signature was made, but no outbound dependency from a CDE. On container-app, `docker inspect` (both `Image` and `RepoDigests`) matches the Hiera pin byte for byte. Re-signing, not rebuilding, is why the digest is unchanged.
- **Trivy on build 26 (reported):** raw 23 CRITICAL / 82 HIGH; after `--ignore-unfixed` 23 / 80; with `.trivyignore` 0 / 0, so the gate passed. The previous baseline was 23 / 79.
  - The three new HIGH IDs, all in `com.fasterxml.jackson.core:jackson-core`: `CVE-2025-52999` (StackoverflowError; fixed in 2.15.0), `CVE-2026-68494` (async-parser DoS, incomplete fix; fixed in 2.18.8 / 2.21.4) and `CVE-2026-89425` (unbounded StringBuilder DoS; fixed in 2.21.7 / 2.22.3 / 2.18.11).
  - They appeared because the **Trivy vulnerability DB was updated, not because the image changed**. The "tools.jackson.core" text in one advisory title is only the Jackson 3 groupId; the package is 2.x.
  - The image ships **two** `jackson-core` versions, 2.12.4 and 2.9.6 (a duplicate transitive dependency). Correction: earlier notes said "jackson-core 2.13.x" and "fix needs 2.15+"; the installed versions are 2.12.4 / 2.9.6 and two of the three fixes need 2.18+.
  - Lesson: use `mvn dependency:tree`, `dependencyManagement` to force one version, and the enforcer plugin's `dependencyConvergence` rule.
  - The three IDs are in `.trivyignore` (lines 120, 130 and 131, verified by the coordinator). Commit `892c390` annotated each with FixedVersion, Trivy 0.67.0, DB downloaded 2026-10-30 and review-by 2027-01-31, and corrected the header to name both installed versions.
  - **Source of the 2.9.6 copy: unverified.** `892c390` says "spring-test transitive", but spring-test is normally test scope and would not ship in a WAR. Confirm with `mvn dependency:tree -Dincludes=com.fasterxml.jackson.core`.

## 7. Stage 5: observability (Prometheus, Alertmanager, Grafana, Splunk): built and verified

Sources: commits `afdf6ad`, `11f7a77`, `381af30`, `1d816f1`, the Stage 5 section of `NOTES.md`, and the coordinator's verified facts. Anything those do not record is marked **not recorded**.

### What it does
- **Metrics (pull model).** The `monitor` host runs Prometheus 2.54.1, Alertmanager 0.27.0 and Grafana 11.2.0 in Docker, with images pinned by sha256 in `stage4/monitoring/docker-compose.yml`. Prometheus scrapes every 15 s: JMX exporters on legacy-app and container-app (port 5556), HAProxy (`:8404/metrics`), `mysqld_exporter` on db (9104), node exporters on all six hosts (log-indexer added in the Stage 5 fix pass; node_exporter 1.8.2, sha256 `0c9219b9...ba1d`), and itself. **11 of 11 targets up** (was 10 of 10 before log-indexer node_exporter was added). Prometheus retention is 15 days. Grafana provisions its datasource and a `canary.json` dashboard from files.
- **Logs.** The `log-indexer` host runs Splunk Enterprise 10.6.1.1 (build b2ae2962645c). Universal Forwarders 10.6.1.1 run on legacy-app, container-app, lb and db, and send to the indexer on 9997. Indexes: `lab_app` (Jetty), `proxy_logs` (HAProxy), `db_logs` (MySQL).
- **No image rebuild.** container-app keeps running build 26 (`sha256:f1a2edae...0203d`); the JMX javaagent is attached through `JAVA_TOOL_OPTIONS` with `/opt/jmx` mounted read-only.

### Why it matters
Operationally: weights can only be moved safely if you can see error rate, latency and per-backend traffic on both populations at once, and a silent log source must page someone. For PCI: 10.7.2 (failure of logging controls detected and alerted), 10.2 to 10.5 (central, retained logs), and the parity gates from the research notes: same sourcetypes, same metric names, alert drills before the ramp.

### Key config and evidence
**Prometheus and alerts.** Six rules in `prometheus/rules/alerts.yml`: `JmxExporterDown` (`absent(jvm_memory_used_bytes{job=~"jmx-.*"})`, 1m), `HighJvmHeapUsage` (2m), `HAProxyAllBackendsDown` (`haproxy_backend_active_servers{proxy="petclinic"} == 0`, 1m), `MysqlExporterDown` (`absent(mysql_up)`, 1m), `MysqlDown` (`mysql_up == 0`, 30s), `HighNodeCpu` (3m). Alertmanager groups by `alertname, instance` and routes to a receiver `webhook-sink` (`send_resolved: true`; commit `18b8148` replaced the earlier no-op `log-only` receiver). The sink is a pinned `python:3.12-alpine` container (`webhook-sink`) on monitor, port 5001, that appends every POST to `/data/webhooks.jsonl` on a named volume. Delivery stays on the LAN with no credentials or external URLs; email, chat or a pager would need credentials and a go-ahead.

**HAProxy built-in exporter.** `files/haproxy.cfg` (commit `11f7a77`) turned the `listen stats` block into a `frontend stats` with:
```
http-request use-service prometheus-exporter if { path /metrics }
```
(HAProxy 2.0.4+). No separate exporter process is needed.

**JMX javaagent.** `petclinic-container.service.erb` exposes port 5556, sets `JAVA_TOOL_OPTIONS` for `jmx_prometheus_javaagent` and mounts `/opt/jmx` read-only; the legacy template adds the javaagent to `ExecStart`. Metric names (`jvm_memory_used_bytes`, `jvm_memory_max_bytes`) are identical on legacy and container; only values differ.

**Canary visible in metrics.** Weights were set through the runtime socket `/var/run/haproxy/admin.sock` (`set server petclinic/legacy-app weight 90`, `... container-app weight 10`). Prometheus showed `haproxy_server_weight{server="legacy-app"} = 90` and `{server="container-app"} = 10`, and a 100-request test split exactly 90 / 10. Runtime-API changes are lost on reload; durable changes belong in `haproxy.cfg`.

**Alert drills (item C), as recorded in NOTES.** container-app stopped 18:00:44Z; mysqld stopped 18:02:44Z; `MysqlDown` fired 18:03:21Z; legacy-app stopped 18:03:34Z; `JmxExporterDown` fired 18:04:51Z; `HAProxyAllBackendsDown` fired 18:05:06Z; everything restored 18:05:12Z; all resolved 18:05:41Z. Caveat: the drills overlapped (container-app was still down when legacy-app was stopped), so these timings show that alerts fire and resolve, not that each alert isolates one failure (retrospective R12). `absent()` over a multi-target selector needs all series gone, which is why both JMX hosts had to be stopped. The other three rules were drilled in the fix pass (next table).

**Alert drills, fix pass (`18b8148`, `03f50c2`; times from the webhook sink, coordinator-verified).** One alert at a time, each with firing and resolved payloads captured:
| Alert | How induced | Firing | Resolved | Proves |
|---|---|---|---|---|
| `HighJvmHeapUsage` | throwaway rule at `> 0.001` (real rule: heap used/max `> 0.80` for 2m), induced 19:32:43Z | 19:35:19Z (2 alerts) | 19:40:19Z (2) | rule to receiver path, not real heap pressure |
| `MysqlExporterDown` | stopped `mysqld_exporter` on db at 19:42:05Z, restored 19:43:53Z | 19:43:36Z | 19:48:36Z | real detection |
| `HighNodeCpu` | throwaway rule at `> 25`, induced 19:51:22Z; no CPU burn run | 19:55:03Z (2) | 20:00:03Z (2) | rule to receiver path only |
For `HighNodeCpu` the alert fired on baseline load: monitor at about 30% and log-indexer (Splunk) at about 59%. The sink also holds one earlier firing POST at 19:30:48Z with no `alertname`, probably a sink test (**not recorded**). Resolved notices arrived about five minutes after restore: `send_resolved` does not bypass `group_interval` (5m), so a resolved notice waits for the next group evaluation. The rules loaded now are the six real ones; no throwaway rule remains. After the drills container-app is still on `f1a2edae` and `/petclinic/owners/13` through HAProxy lb.lab.example returns 200. Lowering a threshold proves routing, not detection (R16).

**Splunk first boot.** Splunk 10 defaults `defaultKVStoreType = cohosted` (PostgreSQL). The PostgreSQL supervisor needs a password from a REST endpoint that returns 404 until an admin user exists, and `user-seed.conf` cannot create the admin until the KV store runs. Fix, set before first start:
```ini
# /opt/splunk/etc/system/local/server.conf
[kvstore]
disabled = 0
defaultKVStoreType = local
```
(MongoDB on 8191; PostgreSQL disabled). A related race: `Can't persist saved-search history due to the KV-Store either being disabled or failing` (17:33:16) stopped all scheduled searches until Splunk was restarted with `--run-as-root` after port 8191 was listening.

**License.** The trial license (`enttrial.lic`, 60 days) expires **2026-12-29 17:22:47 UTC** (`expiration_time` 1798564967, read with `splunk list licenses` on 2026-10-30). An earlier report said "valid through 2027"; that was wrong (R09).

**Forwarders and parity.** sha512 was verified at install for UF and Enterprise packages. Sourcetypes: `jetty_access` and `syslog` on CTs 730 and 731 (`lab_app`), `haproxy` on lb (`proxy_logs`), `mysql:error` and `mysql:slow` on db (`db_logs`). Parity search, as recorded:
```
index=lab_app sourcetype=jetty_access | stats count by host
container-app 521 PASS, legacy-app 428 PASS
```
Event counts at close (about 18:00Z, NOTES): `lab_app` 72,804+ (1,398 `jetty_access`, 71,863 `syslog`), `proxy_logs` 1,185, `db_logs` 525 (116 error, 409 slow). The Petclinic units on CTs 730 and 731 were redirected to `/var/log/petclinic/app.log` by a systemd drop-in.

**Silent-source alert, version 1 and version 2.**
- v1 (`lab_no_app_events`): `index=lab_app sourcetype=jetty_access earliest=-5m | stats count | where count=0`, scheduled `*/5 * * * *`. It aggregated across hosts, so it could fire only when every host was silent. Its first drill (UFs stopped 18:05:52Z and 18:13:12Z, count 0 at 18:20Z) is backed by scheduler evidence: 18:25:01Z `status=success`, `result_count=1`, `condition=1`, again at 18:30:01Z; UFs restarted 18:30:35Z, events resumed by 18:32Z.
- v2 (defect `s5-defect-2-perhost`, commit `1d816f1`): a per-host `tstats latest(_time)` staleness check, `seconds_silent > 300`, owner `admin`. Drill: container-app UF stopped 18:38:54Z; scheduler 19:15:00Z logged `user=admin result_count=1` (`container-app SILENT 36.5min`, with `legacy-app` healthy at `seconds_silent=1s`); UF restarted 19:15:35Z; scheduler 19:20:00Z `result_count=0`.

**JVM container awareness (item E; container-app, build 26).**
| Experiment | Result |
|---|---|
| `MaxRAMPercentage=50` with `--memory=256m` | `MaxHeapSize` 134217728 bytes (128 MB) |
| `--cpus=1` | `UseSerialGC = true` instead of G1 |
| SIGTERM (`docker stop`) | exit code 0, "SIGTERM-received" logged |
| Exit 137 | `OOMKilled=true ExitCode=137` reproduced **only in a separate throwaway container** (`eclipse-temurin` JDK 21 alpine, `--memory=32m --memory-swap=32m`, `-Xms60m -Xmx60m -XX:+AlwaysPreTouch`), **not on build 26** |
`-XX:+AlwaysPreTouch` forces the heap to be committed at startup so the cgroup OOM killer fires before application code. The first attempt (writing to `/dev/shm` inside the LXC) did not trigger an OOM kill and was initially written up as an LXC limitation (R11). The commit labels the experiment image `eclipse-temurin:21-jre-alpine`; build 26's Dockerfile uses a `jre-noble` base pinned by digest, so which base the 128 MB and SerialGC runs actually used is **not recorded**.

**Write and read-back (item G).** `owners` went from 11 to 12 rows; the new row has id 13 (an `INSERT` of a test owner) and was read back through HAProxy lb.lab.example (`/petclinic/owners/13`), HTTP 200. The commit message `afdf6ad` says "id=12"; NOTES and `381af30` say id 13, 12 rows, max id 13. Use 12 rows / id 13. Reading through the load balancer, not the app host, is the point: a direct test can pass while production routing is wrong.

### Defect: stale OpenVox module on the CT (`s5-defect-1-jmx`)
After `11f7a77`, `jmx-container` was down: `docker port petclinic` showed only 8080 and `JAVA_TOOL_OPTIONS` was unset, although `puppet apply --noop` had reported zero drift. The module copy on container-app (`/etc/openvox/code/environments/production/modules/petclinic/...`) predated the commit, so `--noop` compared a stale template against the already-deployed stale unit. The committed template was written to the CT, a real `puppet apply` changed the unit sha256 from `9d957b0a` to `bca0909c`, port 5556 appeared, `jmx-container` and `jmx-legacy` went up, and the image digest stayed `f1a2edae`. **Repo-to-CT sync is still manual.**

### Caveats and not recorded
- Delivery is a LAN-only webhook sink; no email, chat or pager. Grafana dashboard rendering evidence is **not recorded**. Two of the three fix-pass drills used a lowered threshold and prove routing, not detection. The earlier untagged POST at 19:30:48Z is unexplained.
- The Splunk alert's `savedsearches.conf` sets no explicit `counttype`/`relation`/`quantity`, and `alert_actions` is empty; it relies on defaults with tracking only, and no `fired_alerts` entry was shown. "Fired" is evidenced by `condition=1` in `scheduler.log`, not by a delivered alert.
- Splunk is a 60-day trial expiring 2026-12-29. Behaviour after expiry is **not recorded**.
- Commit `afdf6ad` claims "Stage 5 complete" while three OpenVox files were uncommitted and some items unreported (R08).

## 8. Limitations

### 8.1 Environment realism
- Docker-in-Docker is privileged; it is a lab shortcut. Production would use rootless BuildKit or Buildah.
- Registry is plain HTTP on a LAN; Docker Desktop's `~/.docker/daemon.json` was edited to trust it (a workstation change outside the repo, not reverted per the transcript).
- db ran MySQL 8.0.36 (past the 2026-04-30 EOL) until `092489f`; it now runs 8.4.13. There is still no replica.
- Splunk runs on a 60-day trial license (expires 2026-12-29); Alertmanager delivers only to a LAN webhook sink.
- The application is PetClinic, with 93 known CVE IDs in frozen jars accepted via `.trivyignore`. That baseline demonstrates the gate; it is not a security posture.

### 8.2 Evidence quality
- HTTP 200 on `/petclinic/` is a weak check (a welcome page). The meaningful checks use `/petclinic/owners?lastName=`.
- The `latest` tag moves on every commit (SCM poll); only digest references are trustworthy.
- NOTES.md's earlier claim "No passwords, JDBC connection strings, or API keys in any WAR entry" is not supported: the recorded check printed only driver/script lines, while the extracted WARs showed literal datasource attributes and a `jdbc.password` property line. The build-26 credential grep requested by the coordinator is **not recorded** in my sources.
- The NOTES change-log entry for build 24 says "HTTP 503"; the transcript shows HTTP 000 and `No enabled jetty modules found!` for build 24, and 503 for build 25.

## 9. Open items

1. Record the MySQL write plus read-back row count for build 26, and the build-26 Trivy totals.
2. (Done in `092489f`.) `stage4/.../files/haproxy.cfg` re-synced with `stage4/haproxy/haproxy.cfg`.
3. (Done masterless in `092489f`.) Consider an OpenVox server and scheduled applies.
4. Make CT networking persistent (`pct set` gateway/nameserver; fix `scripts/hypervisor-lxc-setup.sh`, which still has `GW`/`DNS` `gateway.lab.example` and aborted after legacy-app).
5. Script the cosign-key install into the Jenkins volume. (Literal passphrase removed in `092489f`.)
6. Remove default-credential fallbacks from `entrypoint.sh` and blank the upstream defaults in the WAR (see 6.3); fail closed when `JDBC_PASSWORD` is unset. (Hiera plain text fixed in `092489f`.)
7. Pin `docker:27.4-dind`, `jenkins/jenkins`, `registry:2` and cosign by digest; verify the cosign download checksum; pin Jenkins plugins.
8. (Done in `092489f`: MySQL 8.4.13.) Re-run full parity checks on the new version.
9. (Done: Stage 5 built.) New Stage 5 items:
   - Automate repo to CT module sync (r10k, or `git pull` on the CT); until then `--noop` proves nothing about the committed tree.
   - Give the Splunk silent-source alert explicit `counttype`, `relation`, `quantity` and a real `alert_actions` entry; show a `fired_alerts` record.
   - Add a real external receiver (email, chat or pager) once credentials and a go-ahead exist; re-drill `HighJvmHeapUsage` and `HighNodeCpu` with real pressure (heap fill, CPU burn) instead of a lowered threshold.
   - Splunk trial license expires 2026-12-29 17:22:47 UTC.
   - Earlier open items above carry forward.
10. Fix mojibake and the stale `stage3/patch_war.py` docstring (it still lists four changes, not five).

## 10. Next steps

- **Jakarta / embedded Jetty (planned step 6):** move `javax` to `jakarta` (OpenRewrite for source, Eclipse Transformer for third-party jars), then switch to embedded Jetty 12.1 `ee10`/`ee11` behind a small `main()` so the entrypoint is `java -jar`. Do it as ordinary releases through the same pipeline; the gate is that the pipeline and parity checks have been boring for a few cycles. Embedded Jetty is the smaller change than Spring Boot 4 (research notes, inference).
- **Kill Bill (planned step 7):** named in your plan only; no repo file defines its scope. General knowledge, not from the sources: Kill Bill is an open-source Java billing/payments platform, which would make it a payments-flavoured second workload for the same pipeline.
- Each production wave is a PCI significant change (scope confirmation, rescans, possible segmentation retest). Agree the 11.5.2 interpretation with the QSA before relying on image immutability.

## Appendix A: PCI DSS 4.0.1 mapping (as built)

| Requirement | What the lab produces | Gap |
|---|---|---|
| 6.3.2 | CycloneDX SBOM per build (`sbom-<sha>.json`) | Contents not inspected |
| 6.3.3 | Automated rebuild, scan, sign cycle (builds take about 3 to 8 minutes) | Findings are baselined, not patched |
| 6.5.1.b | `digest-log.txt` line, commit to digest, archived | Deploy date is only in journals |
| 8.6.2 | Secrets moved out of tracked files; creds rotated | WAR still embeds upstream defaults (6.3); history not rewritten |
| 11.5.2 | Digest enforcement via Hiera/OpenVox, drift-tested masterless (6.2) | One host, masterless; no host FIM; no SSC position on immutability |
| 10.7.2 | Per-host Splunk staleness alert drilled on container-app (result_count=1 for the silent host, 0 for the healthy one); Prometheus down-alerts drilled | Delivery is LAN-only webhook; savedsearch relies on defaults; two of three fix-pass drills used lowered thresholds |
| 12.3.4 | EOL findings are visible (Jetty 9.4; MySQL 8.0 until `092489f`) | MySQL now 8.4.13; keep reviewing annually |
| 12.5.1 | Image digests in Hiera and registry | No inventory report generated |

_Last reviewed: 2026-10-30_
