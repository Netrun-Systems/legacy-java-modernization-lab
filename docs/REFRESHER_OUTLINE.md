# Refresher outline: legacy-java-modernization-lab

Skim sheet, one section per stage. Facts are drawn from the repo; anything unproven is flagged.

Framing reminders (your corrections):
- PCI DSS 4.0 req 6.3.3: critical patches within one month.
- Old v3.2.1 req 2.4 (inventory) is now 12.5.1.
- No PCI SSC position says immutable images satisfy 11.5.2.
- Jetty 9/10/11 public EOL: 2026-01-01. MySQL 8.0 EOL: 2026-04-30.
- Say what you have done and what you have not (no Puppet, Splunk or PCI-assessment ownership claimed).

---

## Stage 1: Jetty 9.4 to 12.1 ee8

### Key concepts
1. Jetty 12 runs several *environments* (ee8, ee9, ee10, ee11) side by side; `ee8` = `javax.*`, Servlet 4.
2. A WAR with no pinned environment goes to the newest enabled one, which breaks `javax` code. Pin with `webapps/<name>.properties` containing `environment=ee8`.
3. The WAR's `jetty-web.xml` names the Jetty 9 class `org.eclipse.jetty.webapp.WebAppContext`; Jetty 12 moved it to `org.eclipse.jetty.ee8.webapp.WebAppContext`. Add `WEB-INF/jetty-ee8-web.xml`; Jetty 9.4 ignores it, so one WAR serves both.
4. Jetty 12 enables only core modules. Without an `ee8-deploy` module the WAR is silently not deployed.
5. `JETTY_HOME` (binaries) vs `JETTY_BASE` (your config, `start.d/*.ini`, `webapps/`).
6. Why now: no public 9.4 releases after 2026-01-01; fixes only via commercial support. 6.3.3 gives criticals a month.
7. Gitiles did the same 9.4 to 12.1 `ee8` hop and deferred `jakarta` (research notes).
8. Lab result: Jetty 9.4.58 and 12.1.14 both HTTP 200 on first run of a script that had never run before.

### Commands to know by heart
```
java -jar $JETTY_HOME/start.jar --list-modules
java -jar $JETTY_HOME/start.jar --list-config            # what is actually enabled
java -jar $JETTY_HOME/start.jar --dry-run                # shows -Djetty.base=... really in use
java -jar $JETTY_HOME/start.jar --add-to-start=http,deploy,jsp,jstl,annotations      # 9.4
java -jar $JETTY_HOME/start.jar --add-modules=server,http,ee8-deploy,ee8-apache-jsp,ee8-glassfish-jstl   # 12, run from INSIDE the base
printf 'environment=ee8\n' > webapps/petclinic.properties
jar uf petclinic.war WEB-INF/jetty-ee8-web.xml
```

### Likely questions
1. *Why Jetty 12 ee8 instead of jumping to jakarta?* Zero code change, ships alone, can be validated for a release cycle; jakarta/embedded is a later, separate release.
   - Points: smallest blast radius; supported patches now; rollback is trivial; namespace change is a code/library problem (OpenRewrite, Eclipse Transformer).
2. *Tie it to PCI.* 6.3.3 patch clock; 12.3.4 annual EOL review; Jetty 9.4 is out of public support.
3. *The app returns 503 after the move. First checks?* Environment pin, `ee8-deploy` enabled, `jetty-ee8-web.xml` present, `ClassNotFoundException` in the log.
4. *How do you prove the new runtime is equivalent?* Parity gates: real context path health check, logs, metrics, sessions, charset/timezone, egress IPs. Be clear the lab only proved HTTP behaviour.
5. *What if the app used JNDI datasources?* `ee8-plus` and the JDBC driver in `lib/ee8/ext` (research notes).

### Gotchas
- `--jetty.base=/path` is **not** a valid Jetty 12 start.jar argument. Symptom: `WARN : Argument: --jetty.base=/var/lib/jetty (interpreted as a JVM argument...)`, base falls back to the CWD. Use `jetty.base=/path`.
- The script worked because `--add-modules` ran with CWD inside the base. In a Dockerfile `RUN` the CWD is `/`.
- `--add-modules` against a wrong base fails quietly (`2>&1 | grep ... || true` hides it).
- The Jenkins container itself logs `jetty-12.1.14`; do not confuse it with the app runtime.
- HTTP 200 on `/petclinic/` is a welcome page; use `/petclinic/owners?lastName=` to touch the DB.

---

## Stage 2: config out of the WAR (H2 / MySQL)

### Key concepts
1. Goal: one signed artifact, config injected at deploy time, no secrets in WAR or image (PCI 8.6.2).
2. Mechanism: container env var, then entrypoint turns it into `-Djdbc.*`, then Spring `<context:property-placeholder system-properties-mode="OVERRIDE">`.
3. The override only works if the XML uses a placeholder. Here the `-P MySQL` WAR had literal `p:url`, `p:username`, `p:password` (likely Maven resource filtering), so overrides did nothing until `patch_war.py` rewrote them.
4. Switching DB type also needs: driver class, init/data script directory (`db.script`), JPA dialect (`jpa.database`), and the H2 jar (absent from the MySQL build).
5. `ignore-failures="ALL"` on `jdbc:initialize-database` lets idempotent init run on H2, but it also hides real failures.
6. Env var names: `JDBC_URL`, `JDBC_USER`, `JDBC_PASSWORD`, `JDBC_DRIVER_CLASS`, `DB_SCRIPT`, `JPA_DATABASE`.
7. Spring Boot style `SPRING_DATASOURCE_*` is silently ignored by a plain Spring Framework WAR.
8. Result on the Jenkins-signed digest (build 26, `sha256:f1a2edaec143...`): H2 and MySQL both HTTP 200 on `/petclinic/` and `/petclinic/owners?lastName=`; same digest by `docker inspect`. Not recorded: Trivy counts for build 26, and the MySQL write plus read-back.

### Commands to know by heart
```
docker create --name probe <image>@sha256:...        # then:
docker cp probe:/var/lib/jetty/webapps/petclinic.war /tmp/p.war
python3 -c "import zipfile;print(zipfile.ZipFile('/tmp/p.war').read('WEB-INF/classes/spring/datasource-config.xml').decode())"
docker inspect --format '{{.Config.Image}}' <container>      # confirm the digest actually running
docker run -d -e JDBC_URL=... -e JDBC_USER=... -e JDBC_PASSWORD=... -e JDBC_DRIVER_CLASS=... image@sha256:...
```

### Likely questions
1. *How do you show the same artifact runs against two databases?* Pull by digest, run twice with different env, `docker inspect` both, hit a DB-backed URL, then write and read back.
2. *Why not bake config per environment?* Breaks digest-based traceability and promotion; secrets in images.
3. *Where should the password come from in prod?* A secrets store injected at runtime (Vault/KMS-backed); never Hiera plain text or entrypoint defaults.
4. *How do you know a property override took effect?* Look at the shipped artifact and the JVM command line, not the source repo.
5. *H2 in production?* No. H2 is a dev/test mode that proves externalisation.

### Gotchas
- **The first "proof" was invalid:** done on a side image (`Dockerfile.h2mysql` over an ad-hoc `fixed4` image) with a hand-patched WAR. On the real signed digests builds 24 and 25 failed (HTTP 000, then 503). Prove claims on the artifact you ship.
- H2 jar: the MySQL build omits it; `Unable to load class: org.h2.Driver`.
- H2 URL `;INIT=CREATE SCHEMA IF NOT EXISTS PUBLIC` broke the driver (`ClassNotFoundException: SCHEMA`) when passed through this chain.
- In the early H2 log Hibernate still printed `MySQL57Dialect`; `JPA_DATABASE=H2` did not take effect there.
- `&` in a systemd `ExecStart` URL and heredocs through `ssh | pct exec` mangle quotes; write files with a script.
- The WAR still embeds upstream PetClinic default credentials in `data-access.properties` (overridden at runtime by `-Djdbc.*`). Expect the 12-factor question: the control is the override, not the absence of a secret; fix by blanking them at build time and failing closed.
- Lab fallbacks inside `entrypoint.sh` include a default credential; H2 in-memory defaults (`sa`, empty password) are the only ones safe to mention.
- Latent bug from build 16 to 24: literal JDBC attributes in `datasource-config.xml`.

---

## Stage 3: Jenkins, Syft, Trivy, cosign, registry

### Key concepts
1. Pipeline: Checkout, Build Image, Export tar, SBOM (CycloneDX), Trivy gate, Push, Sign, Verify, Record commit-to-digest.
2. Pin bases and scanners by sha256; tags are mutable. Trivy 0.69.4 to 0.69.6 were malicious (2026-03-19); lab uses 0.67.0 by digest.
3. Gate: `--severity CRITICAL,HIGH --ignore-unfixed --exit-code 1` plus `.trivyignore`. Lab baseline: 102 findings (23 CRITICAL, 79 HIGH), 93 CVE IDs, all in app jars, zero in OS packages. Added `CVE-2022-45868` for the H2 jar: 94 lines.
4. Key-based cosign by digest, not tag. Production would use KMS/Vault; public Fulcio/Rekor may be blocked in a CDE and Jenkins has no native OIDC.
5. DinD needs `--privileged`; a mounted `docker.sock` is root-equivalent. Kaniko was archived June 2025; rootless BuildKit/Buildah is the production answer.
6. PCI mapping: 6.3.2 SBOM, 6.3.3 patch clock, 6.5.1 traceability, 12.5.1 image inventory.
7. A report-only scan is not a gate. The lab briefly had `--exit-code 0` (commit `b5bf465`) and restored the gate in `f9d4d7d`.
8. Builds 21 to 26 each failed for a different reason; see the retrospective.

### Commands to know by heart
```
docker save <img> -o x.tar
syft docker-archive:/work/x.tar -o cyclonedx-json=/work/sbom.json
trivy image --timeout 15m --severity CRITICAL,HIGH --ignore-unfixed --ignorefile .trivyignore --exit-code 1 --input x.tar
cosign generate-key-pair
cosign sign   --key cosign.key --yes --allow-http-registry --allow-insecure-registry host:5000/repo@sha256:...
cosign verify --key cosign.pub     --allow-http-registry --allow-insecure-registry host:5000/repo@sha256:...
curl http://<registry>:5000/v2/<repo>/tags/list        # signatures appear as sha256-<digest>.sig tags
```
Jenkins REST: fetch crumb with a cookie jar, POST `buildWithParameters` for parameterised jobs (plain `/build` returns 400 `Nothing is submitted`).

### Likely questions
1. *Walk me through the pipeline and where the PCI evidence comes from.* SBOM per build, digest log, signature, scan report, all archived.
2. *Your scan finds 100+ CVEs. Do you ship?* Baseline with owner, rationale and expiry; gate on anything new; plan the upgrade. Be honest the baseline here is un-remediated.
3. *Why sign by digest, and what does verify prove?* Tag mutability; verify proves the digest was signed by the key holder, not that it is safe.
4. *Pinned scanner, floating data?* Trivy pulled its ~131 MiB vulnerability DB at scan time; discuss mirroring.
5. *How would you remove DinD?* Rootless BuildKit/Buildah on an isolated agent with no registry-push creds for the scanner.

### Gotchas
- Docker CLI repo: `jenkins/jenkins:lts-jdk21` is Debian bookworm, not Ubuntu; also needs `gnupg`.
- Plugins need a newer Jenkins than the pinned 2.479.3 (`requires a greater version of Jenkins (2.516.3)`).
- JCasC `jobs:` needs `job-dsl`; trigger is `scm(...)` in Job DSL, not `pollSCM`.
- `docker compose restart` does not re-read env; use `up -d --force-recreate`.
- Jenkins builds from *committed* files only. Reload JCasC after editing casc.
- Groovy: `$(date)` in `"""` strings must be `\$(date)`.
- git `safe.directory` must be system-level (`/etc/gitconfig`); `--global` lands in the mounted volume and is lost.
- Bind mounts in DinD: the workspace path must exist in the daemon's container too (share the `jenkins-home` volume).
- Syft needs the `docker-archive:` scheme for a tar.
- cosign: `--allow-insecure-registry` is TLS verification only; plain HTTP needs `--allow-http-registry`; `--registry-referrers-mode=oci-1-1` needs `COSIGN_EXPERIMENTAL=1`.
- Docker Desktop on Windows: a bind-mounted key arrives `600` owned by uid 65532; copy it into a named volume.
- Compose bind-mounting a missing file creates a *directory* (`open /keys/cosign.key: is a directory`).
- PowerShell writes a UTF-8 BOM; Groovy then fails with `No such property:` plus an invisible character.
- Trivy default timeout is 5 minutes; `--timeout` is a global flag before `image`.
- Every injected jar needs another scan pass.
- Do not guess the Jenkins admin password; read it from the committed config/env names.

---

## Stage 4: OpenVox/Hiera pinning, HAProxy canary/cutover/rollback

### Key concepts
1. Config management owns the OS, runtime and unit file; the only per-release change is the digest in Hiera.
2. Containers join the existing pool at weight 0; traffic moves by weight; rollback is a weight change.
3. HAProxy weight 0 keeps the server health-checked but idle. `disable server` is heavier.
4. Admin-socket weight changes are runtime-only; they do not survive a full restart.
5. Compliance angle: each cutover wave is a PCI significant change (scope confirmation, rescans). Immutable digest enforcement supports 11.5.2 but does not replace host FIM.
6. OpenVox is a Vox Pupuli soft fork of Puppet 8.11 (January 2025). Lab: OpenVox 7.37.2 on container-app, run masterless (`puppet apply`); first apply exit 2 = changes applied; drift test (container swapped to `:latest`) was corrected back to the pinned digest on the next apply.
7. Expand/contract DB changes so old and new builds can run together.
8. Lab: legacy legacy-app and container container-app behind lb; all sampled requests HTTP 200 at baseline, canary, cutover, rollback. Final rework on the build-26 digest: status, canary 90/10 and rollback each 5/5 HTTP 200.

### Commands to know by heart
```
echo "set weight petclinic/container-app 10" | socat - UNIX-CONNECT:/var/run/haproxy/admin.sock
echo "show servers state petclinic" | socat - UNIX-CONNECT:/var/run/haproxy/admin.sock
echo "show stat" | socat - UNIX-CONNECT:/var/run/haproxy/admin.sock
haproxy -c -f /etc/haproxy/haproxy.cfg
docker pull host:5000/petclinic@sha256:...        # pull by digest, never by tag
docker inspect petclinic --format '{{.Image}}'
journalctl -u petclinic-container -n 30 --no-pager
pct exec <ct> -- <cmd> ; pct push / pct pull ; pct config <ct>
```

### Likely questions
1. *Describe the cutover.* Pool at 100/0, readiness and parity green, 10%, watch error budget, ramp, keep legacy warm, rollback by weight.
2. *What do you check before shifting weight?* Health check on the real path, Splunk fields, Prometheus metric names, alert drill, sessions (sticky or JDBC store), memory (heap ~75% of limit), charset/timezone, egress IPs.
3. *Why a digest in Hiera?* Reviewable, auditable intent; drift is detectable; supports 12.5.1 inventory and 6.5.1 traceability.
4. *Does an immutable image satisfy 11.5.2?* No SSC position says so. Combine digest drift detection, host FIM, log-store FIM; agree with the QSA first.
5. *Docker or Podman Quadlet or Kubernetes for a small team?* Systemd plus config management adds least machinery; Kubernetes adds PCI scope (control plane, CNI, admission) and an owner you may not have.

### Gotchas
- HAProxy 2.8 rejects `option httpchk GET ... HTTP/1.1\r\nHost:\ x`. Error: `'option httpchk' : hiding headers or body at the end of the version string is unsupported.Use 'http-check send' directive instead..` Use `option httpchk` plus `http-check send meth GET uri ... ver HTTP/1.1 hdr Host localhost`.
- Hiera datadir mismatch (`hieradata` vs `hiera/data`) cost several iterations. Exit code 2 from `puppet apply --detailed-exitcodes` means changes applied, not failure.
- CT created with `gw`/`nameserver` gateway.lab.example (non-existent): no internet, apt hangs, locks left behind. Fixed at runtime only.
- The setup script aborted after legacy-app under `set -e`; the other CTs were created by hand.
- Ubuntu's Adoptium repo gave `The repository ... is not signed`; used `openjdk-21-jdk-headless`.
- Jetty 9.4 `--add-to-start` run via `pct exec` writes `start.ini` into the CWD (`/root`), not the base: `ERROR : Nothing to start, exiting ...`.
- Wrong property names (`spring.datasource.*`) are silently ignored; this WAR reads `jdbc.*`.
- `provision-container.sh` used `SPRING_DATASOURCE_*`; fixed to `JDBC_*`.
- container-app had no `curl`, so blank HTTP codes looked like failures.
- MySQL grants and `bind-address` must be set for remote clients.
- Earlier flip evidence was on an ad-hoc image; the Hiera digest at that time (build 16) had never served 200.
- `latest` tag moves on every SCM-polled build; deploy by digest only.

---

## Stage 5: observability (built and verified)

Prometheus, Alertmanager, Grafana on monitor; Splunk Enterprise 10.6.1.1 on log-indexer (60-day trial); Universal Forwarder 10.6.1.1 on legacy-app, container-app, lb, and db. Prometheus: 11/11 targets up (log-indexer node_exporter 1.8.2 added), retention 15d. monitor is 2048 MB / 20 GB; log-indexer is 6144 MB / 40 GB, 2 cores.

### Key concepts
1. **Prometheus pull model.** The server scrapes `/metrics` on a schedule (15 s here); targets are static configs with labels. Pull makes "target down" a first-class signal (`up == 0`, `absent()`), which push systems lack.
2. **Exporters.** JMX exporter as a javaagent (port 5556) for JVM metrics; `mysqld_exporter` (9104); `node_exporter` (9100); HAProxy's built-in `prometheus-exporter` service on the stats frontend (`:8404/metrics`, HAProxy 2.0.4+), so no extra process. Same JMX metric names on legacy and container is the parity point.
3. **PromQL for canary weights.** `haproxy_server_weight{server="legacy-app"}` and `{server="container-app"}` show 90 and 10; compare with request rates per server and `haproxy_backend_active_servers{proxy="petclinic"}`. Runtime-API weight changes vanish on reload.
4. **Alertmanager routing.** `group_by` (here `alertname, instance`), `group_wait` (30s: delay before the first notification of a new group), `group_interval` (5m: wait before notifying about new alerts added to a group, and the cadence of resolved notices), `repeat_interval` (1h: re-send a still-firing group), `receiver`, `inhibit_rules` (critical suppresses warning on the same instance). `send_resolved: true` still waits for `group_interval`: resolved notices arrived about 5 min after restore. `for:` durations decide when a pending alert becomes firing.
4a. **Webhook receivers.** A `webhook_configs` receiver POSTs JSON to a URL; here `http://webhook-sink:5001/webhook`, a pinned `python:3.12-alpine` container on monitor that appends each POST to `/data/webhooks.jsonl`. LAN-only; email, chat or a pager needs credentials. A sink makes alert delivery testable and auditable.
5. **`absent()` pitfall.** `absent(metric{job=~"jmx-.*"})` fires only when every matching series is gone; one host down is invisible. Use per-target `up == 0` for single failures.
6. **Grafana provisioning-as-code.** Datasource and dashboard providers under `provisioning/`, dashboards as JSON (`canary.json`); no click-ops state to lose.
7. **Splunk forwarder to indexer.** UF reads files and sends to the indexer's receiving port 9997; inputs set the index and sourcetype; indexes `lab_app`, `proxy_logs`, `db_logs`.
8. **Sourcetype parity.** `index=lab_app sourcetype=jetty_access | stats count by host` returned 521 (container) and 428 (legacy): the same sourcetype and fields on both populations is the gate before ramping.
9. **Per-host silence detection.** A global `stats count | where count=0` is blind to one dead host. Use `tstats latest(_time) by host` and alert on `now()-last_seen > 300`.
10. **JVM container awareness.** `MaxRAMPercentage` (50 % of a 256 MB limit gave a 128 MB heap), CPU limit below 2 selects SerialGC, SIGTERM handling (exit 0), `AlwaysPreTouch` to force an OOM kill, `-XX:+ExitOnOutOfMemoryError`.

### Commands to know by heart
```
# Prometheus
curl -s localhost:9090/api/v1/targets | head ; promtool check rules rules/alerts.yml
up == 0 ; absent(mysql_up) ; haproxy_server_weight ; haproxy_backend_active_servers{proxy="petclinic"}
# HAProxy canary
echo "set server petclinic/legacy-app weight 90"   | socat stdio /var/run/haproxy/admin.sock
echo "set server petclinic/container-app weight 10" | socat stdio /var/run/haproxy/admin.sock
curl -s http://lb.lab.example:8404/metrics | grep haproxy_server_weight
# Splunk
/opt/splunk/bin/splunk version ; /opt/splunk/bin/splunk list licenses
/opt/splunk/bin/splunk enable listen 9997
index=lab_app sourcetype=jetty_access | stats count by host
| tstats latest(_time) as last_seen where index=lab_app sourcetype=jetty_access by host | eval seconds_silent=now()-last_seen | where seconds_silent > 300
index=_internal source=*scheduler.log savedsearch_name=* | table _time savedsearch_name status result_count
# JVM / container
docker run --memory=256m -e JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=50 <img> java -XX:+PrintFlagsFinal -version | grep -E 'MaxHeapSize|UseSerialGC'
docker inspect --format '{{.State.OOMKilled}} {{.State.ExitCode}}' <ctr>
docker stop <ctr> ; docker inspect --format '{{.State.ExitCode}}' <ctr>
```

### Likely questions
1. *How would you prove the container platform did not blind monitoring?* Same JMX metric names on both hosts, same Splunk sourcetype on both, alert drills, per-host silence alert.
   - Points: show the parity search, the metric-name comparison, and a drill with scheduler evidence.
2. *Your alert says it fired. Prove it.* Not a zero count: show the scheduler log (`condition=1`, `result_count`), fire and resolve timestamps, and a delivered notification (here: webhook payloads in `/data/webhooks.jsonl`, firing and resolved).
   - Be candid: two of the three fix-pass drills lowered a threshold, which proves the rule-to-receiver path, not detection.
3. *How do you detect one host going silent?* Per-host `tstats` staleness, not a global count.
4. *Container killed with exit 137 and no `OutOfMemoryError`?* Cgroup limit hit by non-heap memory or pre-touched heap; check `OOMKilled`, then heap/metaspace/threads/direct buffers.
5. *Why not rebuild the image to add JMX?* Javaagent via `JAVA_TOOL_OPTIONS` plus a read-only mount keeps the signed digest unchanged.
6. *What does `puppet apply --noop` prove?* Only that the manifests present on that host match the deployed state; if the host runs a stale copy, a false zero.
7. *Splunk trial ends.* Know the date (2026-12-29) and that an earlier note wrongly said 2027.

### Gotchas
- **Splunk 10 first boot:** default `defaultKVStoreType = cohosted` (PostgreSQL) deadlocks with admin-user creation. Set `defaultKVStoreType = local` (MongoDB) before first start; diagnose in `sup-pkg-kvstore-pdl.log`, not `splunkd.log`.
- Scheduler stops if the KV store fails at start (`Can't persist saved-search history...`); restart with `--run-as-root` after 8191 listens.
- A saved search owned by `nobody` cannot use `tstats` on restricted indexes; a stale `etc/users/admin/.../savedsearches.conf` overrides REST writes.
- `absent()` needs all series gone; overlapping drills (731 still down when 730 stopped) blur which alert did what.
- Exit 137 via `/dev/shm` writes in an LXC does not trigger an OOM kill; a heap with `AlwaysPreTouch` over the limit does, in a separate container, not on build 26.
- Stale on-CT module copy: repo-to-CT sync is manual; run a real apply (and compare file hashes), not only `--noop`.
- The Splunk alert uses defaults (no explicit `counttype`/`relation`/`quantity`, empty `alert_actions`); no `fired_alerts` entry shown.
- Webhook sink is the only receiver: LAN-only, nothing pages anyone.
- Lowering a threshold (`> 0.001`, `> 25`) to force a firing proves routing, not detection; `HighNodeCpu` fired on baseline load (monitor about 30%, log-indexer about 59%) with no CPU burn.
- `send_resolved` does not bypass `group_interval`.
- One untagged firing POST (19:30:48Z, no `alertname`) sits in the sink, probably a test: not recorded.

### Remediation additions (`092489f`)
- MySQL 8.4 LTS APT: component `mysql-8.4-lts`, package `mysql-community-server`. An expired repo signing key (`RPM-GPG-KEY-mysql-2025`, refreshed, expires 2027-10-23) is why `apt update` rejects the repo.
- Rotate, don't rewrite: secrets removed from tracked files and rotated (cosign keypair, Jenkins admin, MySQL app, passphrase); history not rewritten, old values dead.
- Re-sign without rebuild: `cosign sign --key /keys/cosign.key --allow-http-registry --allow-insecure-registry --yes --tlog-upload=false`; same digest `sha256:f1a2edaec143...`; verify exit 0. No tlog line because upload was disabled (offline/air-gapped signing trade-off: no public proof of signing time, no outbound dependency). `docker inspect` Image and RepoDigests on container-app match the Hiera pin.
- Trivy build 26: raw 23C/82H, 23C/80H after `--ignore-unfixed`, 0/0 with `.trivyignore`; gate passed. +3 HIGH = `CVE-2025-52999`, `CVE-2026-68494`, `CVE-2026-89425` in `jackson-core`, caused by a Trivy DB update, not an image change.
- The image ships two jackson-core versions (2.12.4 and 2.9.6). Lessons: use `mvn dependency:tree`, `dependencyManagement`, and the enforcer `dependencyConvergence` rule to resolve duplicates. Fixes: 2.15.0 for one, 2.18+ for the other two.
- Reproducible gates: pin or record the Trivy DB version and date; same artifact can scan differently tomorrow.
- Ignore-list governance: who approves an addition, expiry date, review owner. `.trivyignore` entries now carry FixedVersion, Trivy version, DB date and a review-by date (2027-01-31).
- Exercise: find where the 2.9.6 jackson-core comes from. The commit says "spring-test transitive" but spring-test is normally test scope and would not be in a WAR, so the source is **unverified**. Run `mvn dependency:tree -Dincludes=com.fasterxml.jackson.core` on the PetClinic v5.3.22 `-P MySQL` build and read which dependency path pulls each version.
- Verify output with `--tlog-upload=false`: no tlog line and `"optional":null`; know how to explain it.

## Cross-cutting: honest numbers to remember

| Item | Value |
|---|---|
| Phase 1 | 9.4.58 HTTP 200, 12.1.14 ee8 HTTP 200 (first ever run) |
| Trivy baseline | 102 findings, 23 CRITICAL, 79 HIGH, 93 CVE IDs; +1 for H2 |
| Build 16 digest | `sha256:cefa443ba2568ff42c276c479576735a09a34d882df5ba7465c7149531718530` |
| Build 26 digest (reworked) | `sha256:f1a2edaec14300cd4e3cd29966c7248ef5f7de024bf12e71e79ef1e4af30203d` |
| Side image (invalid proof) | `sha256:f2f1cb5586a4932580f0d732b1b0591109baa8c72d4e5eaa2b03262e089db34f` |
| Hosts | legacy-app, container-app, lb, db |
| Stage 5 | Prometheus 2.54.1, Alertmanager 0.27.0, Grafana 11.2.0 (monitor); Splunk 10.6.1.1 build b2ae2962645c (log-indexer, trial); 11/11 targets, retention 15d; monitor 2048 MB/20 GB, log-indexer 6144 MB/40 GB; owners 12 rows, id 13 |
| Versions | HAProxy 2.8.30, Docker 29.1.3, MySQL 8.4.13 (was 8.0.36 until 092489f), OpenVox 7.37.2, Jetty 9.4.58 / 12.1.14, cosign v2.5.0, Trivy 0.67.0 |
| Not recorded | Build 26 Trivy counts; MySQL write plus read-back |
| Not built | OpenVox server and scheduled runs; external alert delivery (email/chat/pager); automated repo-to-CT sync; MySQL replica |

_Last reviewed: 2026-10-30_
