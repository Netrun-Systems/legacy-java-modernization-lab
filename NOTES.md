# NOTES — What broke, what was fixed, and why it matters

Lessons derived from building this lab.
All phase1 results are reported honestly: the script had never run before this session.

---

## Phase 1: First real run of phase1-jetty12-ee8.sh

### Status: PASSED on first run (2026-10-29)

Actual terminal output:

```
== 1. Source: last javax-era tag
== 2. Tools: Maven 3.9.11, Jetty 9.4.58.v20250814, Jetty 12.1.14
== 3. Build the WAR (H2 default)
== 4. The one non-code fix
== 5. Jetty bases
== 6. Start both
Jetty 9.4.58 (before) -> HTTP 200  http://127.0.0.1:8094/petclinic/
Jetty 12.1.14 ee8 (after) -> HTTP 200  http://127.0.0.1:8012/petclinic/

Logs: /root/legacy-java-modernization-lab/phase1/base94.log  /root/legacy-java-modernization-lab/phase1/base12.log
```

Both Jetty versions served HTTP 200 on first attempt. The jetty-ee8-web.xml fix
(already in the script) was necessary — without it, Jetty 12 would have returned
503 with ClassNotFoundException on org.eclipse.jetty.webapp.WebAppContext.

One anomaly noted: PowerShell writes UTF-8-BOM files, which causes bash to
see `ï»¿#!/bin/bash: No such file or directory` for the bootstrap script shebang.
Harmless — bash fell through to posix mode and ran the script correctly anyway.
Fix: write bootstrap scripts from Git Bash or with explicit no-BOM encoding.

Run was inside `eclipse-temurin:21-jdk-noble` (Docker Desktop desktop-linux context).
No host JDK was used.

### If Jetty 12 shows HTTP 503: ClassNotFoundException

**Symptom:** `org.eclipse.jetty.webapp.WebAppContext` not found.

**Root cause:** In Jetty 12, the EE8 environment moves `WebAppContext` from
`org.eclipse.jetty.webapp` to `org.eclipse.jetty.ee8.webapp`. If the WAR's
`WEB-INF/jetty-web.xml` references the old class, Jetty 12 fails.

**Fix:** Add `WEB-INF/jetty-ee8-web.xml` to the WAR:
```xml
<Configure class="org.eclipse.jetty.ee8.webapp.WebAppContext">
    <Set name="parentLoaderPriority">true</Set>
</Configure>
```
And patch the WAR: `jar uf petclinic.war WEB-INF/jetty-ee8-web.xml`

**Why Jetty 9.4 is unaffected:** It ignores `jetty-ee8-web.xml` entirely
(the `ee8-` prefix is meaningful only to Jetty 12's environment scanner).

**Lesson:** This is the exact configuration archaeology we'd face
on the production migration — finding all the places where internal class
names leaked into config files.

### If Jetty 12 WAR goes to wrong environment

**Symptom:** WAR deploys to `ee10`/`ee9` instead of `ee8`, breaking javax imports.

**Fix:** Add `petclinic.properties` next to the WAR in `webapps/`:
```
environment=ee8
```

**Why this matters:** PetClinic v5.3.22 is the last `javax.*`-era WAR (Spring 5.3,
Java EE 8 Servlet API). Without the pin, Jetty 12 may pick `ee9` or `ee10`
(both use `jakarta.*`) and the app fails at class-load time. The properties file
is a one-liner that pins environment without touching the WAR or rebuilding.

### If Maven OOM-kills during build

**Symptom:** Exit 137 during `turbo build` or `mvn package`.

**Root cause:** Container memory limit too low. See CodeBuild history:
`BUILD_GENERAL1_SMALL` was OOM-killed on a large Maven build;
same applies to large Maven builds.

**Fix:** Use `-e MAVEN_OPTS="-Xmx1g"` or increase container memory.
In the lab, `eclipse-temurin:21-jdk-noble` runs inside Docker Desktop with 23.4GB
allocated — Maven won't OOM here. But in CodeBuild or a Jenkins agent on a small
instance, set the memory explicitly.

---

## Stage 2: Runtime externalization

### What we proved
Spring Framework 5.x `PropertySourcesPlaceholderConfigurer` (registered by
`<context:property-placeholder>`) wraps sources in this precedence order:
1. Environment (JVM system properties + OS env) — highest
2. Local properties files (classpath)

So `-Djdbc.url=jdbc:mysql://...` OVERRIDES `datasource-mysql.properties` at
runtime. One WAR, multiple target databases.

### H2 ↔ MySQL switching without rebuild — PROVED (2026-10-30)

**Same image digest `sha256:f2f1cb5586a4932580f0d732b1b0591109baa8c72d4e5eaa2b03262e089db34f`
served both databases, no rebuild, HTTP 200 both cases.**

How we got here from the original "not proved" state:

1. Maven `-P MySQL` build omits `h2-2.1.214.jar` from `WEB-INF/lib`.
   Fix: `patch_war.py` downloads H2 v2.1.214 from Maven Central and injects it into the WAR.

2. `datasource-config.xml` hardcodes `p:driverClassName="com.mysql.cj.jdbc.Driver"`.
   Fix: `patch_war.py` replaces it with `p:driverClassName="${jdbc.driverClassName}"`.

3. `data-access.properties` has `jdbc.driverClassName=com.mysql.cj.jdbc.Driver` as default.
   This is the EXPECTED default value — it's overridden at runtime by
   `-Djdbc.driverClassName=org.h2.Driver` (set by `entrypoint.sh` from `JDBC_DRIVER_CLASS`).
   The JVM system property takes precedence over properties files in Spring's
   `PropertySourcesPlaceholderConfigurer`.

4. H2 init SQL scripts (`db/h2/schema.sql`, `db/h2/data.sql`) already exist in the WAR.
   `patch_war.py` adds `ignore-failures="ALL"` to `jdbc:initialize-database` to allow
   H2's idempotent init to succeed even with MySQL-syntax edge cases.

**Evidence (H2 test):**
- Image: `registry.lab.example:5000/petclinic:h2mysql-proof` (ID: sha256:f2f1cb55...)
- Env vars set (no credentials): `JDBC_DRIVER_CLASS=org.h2.Driver`, `DB_SCRIPT=h2`,
  `JPA_DATABASE=H2`, `JDBC_URL=jdbc:h2:mem:petclinic;DB_CLOSE_DELAY=-1;DB_CLOSE_ON_EXIT=FALSE`,
  `JDBC_USER=sa`, `JDBC_PASSWORD=(empty)`
- HTTP response: **200**

**Evidence (MySQL 8.4 test):**
- Same image digest `sha256:f2f1cb55...`
- Env vars set (no credentials): `JDBC_DRIVER_CLASS=com.mysql.cj.jdbc.Driver`,
  `DB_SCRIPT=mysql`, `JPA_DATABASE=MYSQL`,
  `JDBC_URL=jdbc:mysql://db.lab.example:3306/petclinic?...`,
  `JDBC_USER=petclinic`, `JDBC_PASSWORD=(not shown)`
- HTTP response: **200**

**grep proof — WAR holds no credentials:**
- `WEB-INF/classes/spring/datasource-config.xml`: `driverClassName` is `${jdbc.driverClassName}` (placeholder)
- `WEB-INF/classes/spring/data-access.properties`: default driver class name only (not a credential)
- `WEB-INF/lib/h2-2.1.214.jar`: present (injected by patch_war.py)
- `WEB-INF/lib/mysql-connector-java-8.0.28.jar`: present (from Maven build)
- No passwords, JDBC connection strings, or API keys in any WAR entry

**Lesson:** This is exactly the discussion a production Java team would have about
TWELVE-factor App compliance. Factor III (Config) says credentials belong in the
environment; it doesn't say database dialect switching is free. Separating "which
MySQL instance" from "H2 vs MySQL" is worth a story in the backlog.
The WAR patching pattern (`patch_war.py`) also demonstrates post-build artifact
mutation — a technique for applying last-mile configuration without access to
source or build system, directly relevant to legacy app migration.

### Insecure registry for the hypervisor host LXCs

The lab registry runs plain HTTP on `registry.lab.example:5000`. Docker refuses to pull
from insecure registries by default. Each the hypervisor host LXC that needs Docker must
add:
```json
{ "insecure-registries": ["registry.lab.example:5000"] }
```
to `/etc/docker/daemon.json`. In production: use TLS termination (nginx/Caddy)
in front of the registry, or use cloud container registries (ECR, GCR, etc.) where TLS is built in.

---

## Stage 3: Jenkins supply-chain incident

### Trivy gate — build 16 severity counts and .trivyignore rationale

**Build 16 Trivy results** (`--ignore-unfixed`, before `.trivyignore` was applied):
- CRITICAL: 23
- HIGH: 79
- All findings are in `WEB-INF/lib/*.jar` (legacy app JARs). Zero OS-level findings.
- The WAR bundles spring-framework 5.3.22, jackson 2.13.x, and logback 1.2.x — all EoL.

**Gate policy (restored from report-only to gating):**
- `--exit-code 1` — pipeline fails if any un-ignored CRITICAL/HIGH remains
- `--ignore-unfixed` — suppress findings with no available fix in any release
- `--ignorefile .trivyignore` — suppress findings documented with risk-acceptance rationale
- With both flags, all build-16 CRITICAL/HIGH are covered and the gate passes

**Why this is still useful gating:**
Any NEW vulnerability in a base OS package, a patched library upgrade, or a
developer-added JAR will trigger the gate and require either patching or
explicit acceptance with rationale in `.trivyignore`. The gate is not security
theater — it will catch things that matter.

### cosign verify — build 16

```
Verification for registry.lab.example:5000/petclinic@sha256:cefa443ba2568ff42c276c479576735a09a34d882df5ba7465c7149531718530 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The signatures were verified against the specified public key

[{"critical":{"identity":{"docker-reference":"lab-registry:5000/petclinic"},
  "image":{"docker-manifest-digest":"sha256:cefa443ba2568ff42c276c479576735a09a34d882df5ba7465c7149531718530"},
  "type":"cosign container image signature"},...}]
```
Exit code: 0 (verified)
Public key: `keys/cosign.pub` (EC P-256, generated 2026-10-29)

### Digest pins inventory

| Tool | Reference in Jenkinsfile | Pinned by sha256? |
|---|---|---|
| `aquasec/trivy` | `aquasec/trivy@sha256:94711c60051c6cab848a292e3a67f62623fcee361b2bb661f43b17184f4afdac` | YES |
| `anchore/syft` | `anchore/syft@sha256:f1099806495b4d2300adf03887bdfb69230c36a5e077061a12ee292bcd9bfd62` | YES |
| `gcr.io/projectsigstore/cosign` | `gcr.io/projectsigstore/cosign:v2.5.0` (tag only in Jenkinsfile) | NO — tag only |
| `eclipse-temurin` (JDK builder) | `eclipse-temurin@sha256:bd6ac06e2a2df928af21c75c4a8a0f2829a93377a65761d6a577bb32281e2ac3` | YES |
| `eclipse-temurin` (JRE runtime) | `eclipse-temurin@sha256:161310cd5bd41fd549d19cf9f90b614897cb4a1532555c613b43b7e0628fe5d6` | YES |
| `docker:27.4-dind` | tag `27.4` (in docker-compose.yml) | NO — tag only |
| `haproxy:2.8-alpine` | tag `2.8-alpine` (in docker-compose.yml) | NO — tag only |
| `jenkins/jenkins:lts-jdk21` | tag `lts-jdk21` (in docker-compose.yml) | NO — tag only |
| `registry:2` | tag `2` (in docker-compose.yml) | NO — tag only |

**Action:** `cosign`, `dind`, `haproxy`, `jenkins`, and `registry` are tag-pinned only.
Pinning them by sha256 in `docker-compose.yml` is the next hardening step.
For this lab, the build tools most critical to pin are Trivy and Syft (they inspect
security artifacts), and both are pinned. The cosign signing step uses a versioned tag,
which is an acceptable risk for a workstation lab; pin to digest for production.

### .gitignore — cosign key material

`keys/cosign_key_b64` is untracked. Confirmed `keys/` gitignore rules:
```
keys/cosign.key
keys/*.key
keys/*.p12
keys/cosign_key_b64
```
Verified: `git status` shows `keys/cosign_key_b64` as untracked (not staged, not committed).
`keys/cosign.pub` IS committed (public key is not secret).
No key material in any git commit.

### Trivy 0.69.4/0.69.5/0.69.6 — compromised

**What happened (2026-03-19):** Malicious actors published Trivy v0.69.4 to
Docker Hub and force-pushed the `trivy-action` GitHub Action tags. Versions
0.69.5 and 0.69.6 followed within hours. Any pipeline pulling `aquasec/trivy:latest`
or using the unpinned `trivy-action` during that window ran attacker-controlled
scanner code.

**Our mitigation:** Pin to `aquasec/trivy:0.67.0` by tag. For production,
also pin by digest: `aquasec/trivy@sha256:<known-good>`.

**Lesson:** "You audit your scanner as much as your app" — supply-chain
attacks increasingly target the security tooling itself. The practice of pinning
scanner versions by digest, and verifying the signature, is the same practice we
apply to the app image.

### Kaniko archived

**What happened (June 2025):** Google archived the Kaniko project. The last
release is v1.23.2.

**Why it matters:** Kaniko was the canonical "rootless Docker build in Kubernetes"
answer. Its archival means teams must choose an alternative:
- **Buildah** (Vox Pupuli / Red Hat) — rootless, daemonless, actively maintained
- **BuildKit** (`moby/buildkit`) — actively maintained, used by Docker Desktop

**Our approach:** The lab uses Docker-in-Docker (DinD) because this is a workstation
lab, not production Kubernetes. DinD requires `privileged: true` and is NOT
appropriate for production. The Jenkinsfile comment documents this explicitly.

**Lesson:** "Our Jenkins DinD setup is a lab shortcut. In a production
Kubernetes-based CI, we'd use BuildKit or Buildah — both rootless, no privileged
container required. The Dockerfile format is identical; only the `docker build`
invocation changes."

### cosign key-based vs Fulcio/OIDC

**Why not Fulcio/OIDC in this lab:**
1. Jenkins cannot issue OIDC tokens natively (requires oidc-provider plugin + IRSA/WIF)
2. CDE segmentation may prohibit outbound HTTPS to `fulcio.sigstore.dev` and
   `rekor.sigstore.dev`
3. Key-based signing has a simpler audit trail: sign = private key; verify = public key

**Production note:** In a cloud-native CI (GitHub Actions, GCP Cloud Build, or cloud CI
CodeBuild with IAM OIDC), keyless Fulcio/OIDC is preferred — no key rotation,
shorter-lived credentials, public Rekor transparency log.

**Lesson:** "We can wire Fulcio OIDC in an afternoon once the Jenkins
OIDC plugin is installed and the CDE team approves the Rekor egress rule. The
Jenkinsfile's `cosign sign` invocation changes from `--key` to `--oidc-issuer`;
nothing else changes. I designed it that way intentionally."

---

## Stage 4: HAProxy weight flip

### Why weight 0 is not weight remove

`set weight petclinic/container-app 0` keeps the server in the pool at zero weight.
HAProxy will drain active sessions to it but not route new requests.
`set weight petclinic/container-app 1` re-adds it instantly.
Compare to `disable server petclinic/container-app` which removes it from the pool
and requires re-enable for recovery — slower and stateful.

**Lesson:** "Weight 0 means instant rollback: `flip-weights.sh rollback`
takes milliseconds and requires no config file reload. For a payment processor
doing thousands of transactions per minute, minimizing the rollback window is
worth the extra complexity."

### OpenVox vs Puppet 8.11

OpenVox is the Vox Pupuli soft fork of Puppet 8.11 (January 2025).
The module syntax, Hiera 5, and agent API are functionally identical to
Puppet 8.11. Existing Puppet modules work unchanged. The fork exists for
continued community development after Perforce's acquisition of Puppet.

**Our Hiera approach:** `petclinic::image_digest` in node-specific Hiera data.
After each Jenkins build, update this value and commit. OpenVox picks it up
on the next agent run and enforces the exact digest — any drift (manual docker
pull, registry overwrite) triggers a re-create on the next run.

**Lesson:** "GitOps for config management: the desired state is in the
control repo. Every change is auditable, reversible, and PR-reviewed. The
Hiera digest is PCI evidence that a specific build artifact was deployed to
a specific host at a specific time."

---

## PCI DSS v4.0.1 mapping

| Requirement | What we built | Gap / Caveat |
|---|---|---|
| 2.4 → 12.5.1 | Hiera inventory of all hosts and versions | Manual update after OpenVox run; needs automation hook |
| 6.3.2 | CycloneDX SBOM via Syft in pipeline | Covers container contents; doesn't cover OS packages installed outside the image |
| 6.5.1.b | Digest log in Jenkins artifacts | Proves commit→image traceability; doesn't prove deploy date (that's in systemd journal) |
| 11.5.2 change detection | OpenVox digest enforcement | NOT equivalent to FIM (file integrity monitoring); no official SSC statement maps immutable containers to 11.5.2 without additional controls |

**11.5.2 caveat is important:** Immutable container images reduce the attack
surface but don't satisfy 11.5.2 alone. You still need FIM on the host OS
(e.g., Wazuh, Aide, Samhain) for the files HAProxy, systemd, and the JDK
write outside the container. The QSA will ask for this.

---

## Splunk stub

Splunk is staged in `stage4/splunk/` but NOT started.

### Splunk Docker Hub terms — SPLUNK_GENERAL_TERMS requirement

Source: https://hub.docker.com/r/splunk/splunk (**NOT VERIFIED** — tag and terms details below are unverified; confirm against Docker Hub before starting)

Current supported tag: `9.3.3` (unverified — check Docker Hub for the current 9.3.x latest)

The `docker-splunk` image requires the env var `SPLUNK_START_ARGS=--accept-license` OR
the newer `SPLUNK_GENERAL_TERMS=yes`. Both are accepted; the older `--accept-license`
form is still supported in 9.3.x. Setting `SPLUNK_GENERAL_TERMS=yes` is preferred for
9.3.3+ as it maps to the current Splunk General Terms rather than the older EULA wording.

**Before running the Splunk container:**
1. Review the Splunk General Terms at https://www.splunk.com/en_us/legal/splunk-general-terms.html
2. Accept by adding to the compose env: `SPLUNK_GENERAL_TERMS: "yes"` (or `SPLUNK_START_ARGS: --accept-license`)
3. Set a strong password: `SPLUNK_PASSWORD: <min 8 chars>`
4. Pull: `docker pull splunk/splunk:9.3.3`

**Compose snippet (do not start until terms reviewed):**
```yaml
services:
  splunk:
    image: splunk/splunk:9.3.3
    environment:
      SPLUNK_START_ARGS: "--accept-license"
      SPLUNK_GENERAL_TERMS: "yes"
      SPLUNK_PASSWORD: "[SPLUNK_PASSWORD]"   # placeholder; set in .env
    ports:
      - "8000:8000"   # web UI
      - "8088:8088"   # HEC (HTTP Event Collector)
    volumes:
      - splunk-data:/opt/splunk/var
```

Note: `9.3.3` vs `9.3.2` — use `9.3.3` to avoid the tag drift that caused the Trivy
compromise (same pattern: pinning to a minor release that was already superseded).
Pin by sha256 once pulled.

---

## Lab CT inventory (the hypervisor host Proxmox)

All lab containers are named with a lab- prefix and tagged for easy removal.

| Role | Name | IP (example) | RAM | Disk | Status | Purpose |
|---|---|---|---|---|---|---|
| 730 | legacy-app | legacy-app.lab.example | 1536 MB | 20 GB | running | Jetty 9.4 legacy app host |
| 731 | container-app | container-app.lab.example | 1536 MB | 20 GB | running | Jetty 12 container-app host + Docker |
| 732 | lb | lb.lab.example | 512 MB | 10 GB | running | HAProxy 2.8 load balancer |
| 733 | db | db.lab.example | 2048 MB | 20 GB | running | MySQL 8.4 database |
| 734 | monitor | monitor.lab.example | 2048 MB | 20 GB (2.5G used) | running | Prometheus 2.54.1 + Alertmanager 0.27.0 + Grafana 11.2.0 + webhook-sink; Prometheus retention 15d |
| 735 | log-indexer | log-indexer.lab.example | 6144 MB | 40 GB (7.7G used) | running | Splunk Enterprise 10.6.1.1 + node_exporter 1.8.2 |


**workstation.lab.example — the Windows workstation (confirmed)**
This is the LAN IP of the Windows 11 workstation running Docker Desktop.
It is confirmed as the workstation via: (a) `docker-compose.yml` comment
`# workstation.lab.example = Windows workstation (Docker Desktop)`, and (b) ARP table
on container-app shows `workstation.lab.example dev eth0` with the workstation's MAC.
The registry (`registry.lab.example:5000`) is the Docker Desktop registry container
running on the workstation. It is LAN-only; nothing is exposed to the internet.

---

## Prometheus/Grafana/Alertmanager

Stubs are in `stage4/monitoring/` — configs written but containers NOT started.
These are reference architecture only for the reference discussion.

---

## Things that took longer than expected

1. **`pvesh get /cluster/nextid` returned 100 on first call** — unexpected; re-ran
   and got correct next available ID. Proxmox API can return a cached value.
   Always verify with `pct status <id>` before claiming an ID is free.

2. **DinD `--insecure-registry` timing** — must set at DinD start time (`docker run`
   args), not after. Restarting DinD clears its state (`/var/lib/docker`) because
   `dind-storage` is a named volume. First build after restart re-pulls base images.

3. **Jetty 12 `--add-modules` vs `--add-to-start`** — Jetty 9.4 uses `--add-to-start`;
   Jetty 12 uses `--add-modules`. Mixing them gives a confusing error about unknown
   modules. The `ee8-*` prefixed modules (ee8-deploy, ee8-apache-jsp, ee8-glassfish-jstl)
   exist only in Jetty 12 and are not present in Jetty 9.4.

4. **`echo EXIT_CODE=$?` pattern in Jenkinsfile** — `returnStatus: true` on `sh()` in
   Groovy returns the exit code of the shell command. But the trivy `docker run`
   command's `echo EXIT_CODE=$?` at the end means the shell always exits 0 (because
   `echo` succeeds). This is a known Groovy/Jenkins trap. Correct approach: use
   `returnStatus: true` on the `sh()` call directly and remove the trailing echo.

---

## Change log (running)

| Build | Symptom | Root cause | Fix | Lesson |
|---|---|---|---|---|
| 21 | Trivy: `context deadline exceeded` during WAR scan | H2 JAR added 10 MB of nested JARs; Trivy default 5 min timeout expired while walking WAR layers | Added `--timeout 15m` global flag in Jenkinsfile before the `image` subcommand | Trivy global flags must precede the subcommand (`image`). Container scan time grows with WAR classpath depth. |
| 22 | Jenkins: `MissingPropertyException: No such property: ﻿` | PowerShell `[System.Text.Encoding]::UTF8.WriteAllText()` injects a UTF-8 BOM (EF BB BF). Groovy sees the BOM byte-sequence as a property name. | Stripped BOM from Jenkinsfile, stage3/Dockerfile, stage2/Dockerfile using `[System.Text.UTF8Encoding]::new($false)` | PowerShell writes BOM by default. Any file destined for bash/groovy/Java must be written with explicit no-BOM UTF-8. |
| 23 | Trivy gate FAILED: `CVE-2022-45868` not in .trivyignore | Injected H2 2.1.214 JAR introduced CVE-2022-45868 (H2 web console empty password). `.trivyignore` covered spring/jackson/logback but not H2. | Added `CVE-2022-45868` to `.trivyignore` with documented rationale: H2 web console (`-web` flag) is never started; JAR is present for JDBC driver class only. | Every new JAR injected into the WAR requires a separate Trivy analysis pass. Don't assume existing ignore lists cover new dependencies. |
| 24 | Jetty: app context `UNAVAILABLE`; HTTP `000` (no response) despite `--add-modules` | `--add-modules` with `--jetty.base=` is silently ignored in Jetty 12 `start.jar`; Jetty falls back to CWD as base, finds no modules, exits. | Changed Dockerfile to write `start.d/*.ini` files directly (e.g., `--module=server > server.ini`), bypassing the broken flag. | Jetty 12 start.jar argument parsing changed from Jetty 9.4. Never assume `--add-modules` behaves the same across major versions. |
| 25–26 | App context loads; HTTP `503`; `Driver:org.h2.Driver returned null for URL:jdbc:mysql://...` | `datasource-config.xml` has hardcoded literals: `p:url="jdbc:mysql://..."`, `p:username="petclinic"`, `p:password="petclinic"`. Only `p:driverClassName` was patched to a placeholder. So `-Djdbc.url=...` had nothing to override. | Extended `patch_war.py` in stage2 and stage3 to also replace `p:url`, `p:username`, `p:password` with `${jdbc.url}`, `${jdbc.username}`, `${jdbc.password}` placeholders. | Always extract and inspect the actual XML from the built WAR before claiming a property is overridable. Grep for hardcoded values, not just placeholder patterns. |
| item1 | db MySQL 8.4 upgrade | MySQL APT repo: (a) signing key expired 2025-10-22 — refreshed from `RPM-GPG-KEY-mysql-2025` (expiry 2027-10-23). (b) `mysql-apt-config` wrote component `mysql-8.4` but repo uses `mysql-8.4-lts`. (c) Package is `mysql-community-server`, not `mysql-server-8.4`. | Updated sources.list component to `mysql-8.4-lts`; installed `mysql-community-server`; verified bind-address, petclinic@% grant, and owners count (10) preserved post-upgrade. | Oracle periodically renames APT components without a redirect. Always `apt-cache show` to confirm exact package name after adding a new repo. |
| item2 | OpenVox install on container-app — `apt.voxpupuli.org` 404 | APT repo uses `openvox7-release-ubuntu24.04.deb` (not a standard `dists/` tree). Signing key at `openvox7-release-keyring.gpg`. Service ERB template omitted `JDBC_DRIVER_CLASS`, `DB_SCRIPT`, `JPA_DATABASE` env vars. Hiera `haproxy.cfg` used deprecated `option httpchk GET ...` syntax. | Installed release deb, fixed template vars, fixed haproxy.cfg to `http-check send meth GET ...`. Run `puppet apply` masterless (exit 2 = changes). | Vox Pupuli APT repo does not follow standard Debian repo layout. Probe `https://apt.voxpupuli.org/` listing first. |
| item4-followup | Trivy HIGH count 79→82; `.trivyignore` rationale said "2.13.x, fix requires 2.15+" | WAR actually bundles TWO jackson-core versions: 2.12.4 (app direct dep) and 2.9.6 (spring-test transitive). Three new CVEs (CVE-2025-52999, CVE-2026-68494, CVE-2026-89425) all target jackson-core with fixes in 2.15–2.21. Rationale updated; per-CVE annotations added (scanner version, DB date, review-by 2027-01-31). | Always check InstalledVersion in Trivy JSON — the WAR classpath can carry multiple versions of the same groupId via transitive deps. |
| item3 | Secrets in git: `secret: "lab-key"` in casc.yaml; `mysql::password: "petclinic"` in Hiera common.yaml; `:-lab-admin` fallback in docker-compose.yml and casc.yaml | Hardcoded defaults left from initial lab setup. cosign passphrase and Jenkins admin password were literals; MySQL password was in tracked Hiera file. | Moved all secrets to `.env` (gitignored) and `stage4/openvox/hiera/data/secrets.yaml` (gitignored). Changed all references to `${VAR}` env var interpolation. Rotated cosign keypair, Jenkins admin password, MySQL app password. Updated .gitignore, Hiera hierarchy, and verified `git grep` finds no hardcoded values in tracked files. | Lab secrets belong in gitignored env files from day one — never default-values-as-fallbacks in YAML. Add `.env` and secrets layers to .gitignore before the first commit. |
| s5-gap-A | monitor gateway/DNS: needed proof of persistence across reboots | Proxmox-level config at `/etc/pve/lxc/734.conf` holds `gw=hypervisor.lab.example` and `nameserver hypervisor.lab.example` — written at CT creation time, persists across reboots without any in-CT config file. | Network config lives in Proxmox host, not in the CT. The CT `/etc/network/interfaces` doesn't define the default route; Proxmox injects it via veth. |
| s5-gap-B | sha256 pins for monitoring images; full scrape target matrix; metric-name parity | Pins confirmed from `stage4/monitoring/docker-compose.yml`. All 10 Prometheus scrape targets `up=1`. JVM metric names (`jvm_memory_used_bytes`, `jvm_memory_max_bytes`) identical on legacy and container — only values differ. | JMX exporter uses the same metric namespace regardless of deployment mode (JAR javaagent vs Docker port mapping). |
| s5-gap-C | 3 drills: stop container-app, stop mysqld, stop legacy-app — need fire+resolve timestamps | 18:00:44Z container-app stopped → 18:02:44Z mysqld stopped → 18:03:21Z MysqlDown fired → 18:03:34Z legacy-app stopped → 18:04:51Z JmxExporterDown fired → 18:05:06Z HAProxyAllBackendsDown fired → 18:05:12Z all restored → 18:05:41Z all resolved. | `absent()` requires ALL series in the selector to be absent. Stopping one JMX CT doesn't trigger JmxExporterDown if the other CT is still sending. Must stop both. |
| s5-gap-E-fix | exit 137 not triggering with /dev/shm write loop | LXC cgroup doesn't kill the container on /dev/shm writes because those pages aren't committed to cgroup memory. JVM with default lazy allocation also avoids OOM. | Add `-XX:+AlwaysPreTouch` to force heap commit at JVM startup. With a 60m heap inside a 32m container, OOM fires before `main()` runs. `OOMKilled=true ExitCode=137` confirmed via `docker inspect`. |
| s5-gap-openvox | Three OpenVox manifests (haproxy.cfg, petclinic-container.service.erb, petclinic-legacy.service.erb) uncommitted | Files modified for HAProxy Prometheus exporter and JMX javaagent port mapping but not staged. | Committed as `11f7a77`. Ran `puppet apply --noop` on container-app post-sync: zero drift (no "Would have triggered" lines). |
| s5-gap-splunk-sched | Splunk scheduler not running `lab_no_app_events` | KVStore warning `Can't persist saved-search history` at startup (17:33:16) halted ALL scheduled search execution. The DMC search ran once then stopped. | Restart Splunk with `--run-as-root` after KVStore is confirmed ready (port 8191 listening). Scheduler resumes and picks up all saved searches within 1 cron cycle. |
| s5-defect-1-jmx | JMX exporter on container-app reported "connection refused" in Prometheus after gap-closure commit `11f7a77`; `docker port petclinic` showed only 8080 (no 5556); `JAVA_TOOL_OPTIONS` unset in container env. `puppet apply --noop` had shown zero drift. | The on-CT module copy at `/etc/openvox/code/environments/production/modules/petclinic/templates/petclinic-container.service.erb` was stale — it lacked the `-p 5556:5556`, `JAVA_TOOL_OPTIONS`, and `-v /opt/jmx:/jmx:ro` lines. The Windows git repo had the correct template but the CT copy was never updated after `11f7a77`. `--noop` ran against the stale CT copy, which matched the already-deployed stale unit file, so no diff was detected — a false zero. | Wrote committed template content to container-app via heredoc. Ran real `puppet apply` (not --noop): unit file sha256 changed from `9d957b0a` to `bca0909c`, daemon-reload triggered, service refreshed. `docker port petclinic` showed `5556/tcp -> 0.0.0.0:5556`. Prometheus `jmx-container up=1` and `jmx-legacy up=1` confirmed. Digest `sha256:f1a2edae…` unchanged. | `puppet apply --noop` proves only that the on-CT manifests match the deployed state — it does NOT prove the on-CT manifests match the git repo. Always `pct push` changed template files before trusting a `--noop` result. |
| s5-fix1-webhook | Alertmanager had no real receiver — alerts visible in UI only, no delivery proof outside the container. No way to capture a firing payload for drill evidence. | `log-only` no-op receiver was the only configured route. The coordinator requirement was a lab-local webhook sink with `send_resolved: true` and a persisted payload file. | Added `webhook-sink` container on monitor (`python:3.12-alpine` sha256:e6dae589..., port 5001:5001, `lab-monitoring` network). Python HTTP server persists each POST to `/data/webhooks.jsonl` on `webhook-sink-data` volume. Updated `alertmanager.yml` to route default to `http://webhook-sink:5001/webhook, send_resolved: true`. Alertmanager `/api/v2/status` shows `receiver=webhook-sink`, `url=<secret>`. | Alertmanager masks the webhook URL as `<secret>` in its API — confirm routing by actually inducing an alert and checking the payload file, not just the API response. |
| s5-fix2-ct735-node | log-indexer (log-indexer) was running but not monitored by Prometheus — 10/11 targets only. Coordinator required 11/11. | log-indexer was added late (Stage 5 Item F) and node_exporter install was never extended to it. | Installed node_exporter 1.8.2 on log-indexer using existing `setup_node_exporter.sh`; sha256 `0c9219b9...` verified at install and matches the lab containers byte-for-byte. Added `${LOG_INDEXER_HOST}:9100` to prometheus.yml node job. POST `/-/reload` on Prometheus. `/api/v1/targets` shows 11/11 up. | sha256 of node_exporter binary is identical across all six CTs — confirms same binary, not just same version tag. |
| s5-fix3-drills | Three alert rules (HighJvmHeapUsage, MysqlExporterDown, HighNodeCpu) had never been drilled end-to-end with firing + resolved webhook payloads. | Original drills (s5-gap-C) only exercised JmxExporterDown and HAProxyAllBackendsDown by stopping CTs. The three new rules were not yet drilled. | Used throwaway rule files (lower threshold to below current metrics) for HighJvmHeapUsage (`> 0.001`, heap at 1.2%/0.2%) and HighNodeCpu (`> 25`, monitor at 30% and log-indexer at 59%); stopped mysqld_exporter service for MysqlExporterDown. Each drill: (1) induce, (2) confirm activeAt in Alertmanager, (3) capture firing webhook payload, (4) restore, (5) wait for resolved webhook, (6) confirm no active alerts. All three drills showed firing + resolved payloads in webhooks.jsonl. | Resolved webhook delivery is governed by `group_interval` (5m), not `resolve_timeout`. After restoring the service, Alertmanager sends the resolved notification at the next group eval — up to 5 minutes later. `send_resolved: true` does not bypass the group_interval. |
| s5-defect-2-perhost | `lab_no_app_events` was a global zero-count search: `\| stats count \| where count=0`. It only fired when ALL hosts were silent. Required stopping both legacy-app and container-app UFs to trigger. Cannot detect one host going dark. | Search aggregated events across all hosts before filtering. A single active host contributes non-zero count, suppressing the alert entirely. Also: the search ran as owner=nobody; nobody lacked `tstats` index permissions, so any tstats-based replacement always returned 0 rows; and a stale admin-user savedsearches.conf entry (`/etc/users/admin/search/local/savedsearches.conf`) overrode REST API updates until explicitly deleted and Splunk was restarted. | Replaced search with `\| tstats latest(_time) as last_seen where index=lab_app sourcetype=jetty_access by host \| eval seconds_silent=now()-last_seen \| where seconds_silent > 300 \| eval status="SILENT " + tostring(round(seconds_silent/60,1)) + "min" \| table host, status`. Set `owner=admin` via `metadata/local.meta`. Drill result: container-app UF stopped 18:38:54Z; scheduler at 19:15:00Z (dispatch_time=1793387700) logged `user=admin result_count=1` with `container-app SILENT 36.5min`; legacy-app legacy-app seconds_silent=1s (healthy). container-app UF restarted 19:15:35Z; container-app seconds_silent dropped to 5s within 30s. Scheduler at 19:20:00Z logged `result_count=0`. | Splunk REST API updates to a saved search may silently write to the admin user namespace (`/etc/users/admin/...`), which survives a conf file push. Always delete all namespace copies and restart Splunk to guarantee the scheduler picks up a new SPL. Also: test scheduled searches with the `nobody` user separately; `tstats` returns empty for users lacking index access even when `index=<name>` works fine with normal SPL. |

## Stage 5: Observability (2026-10-30)

### Items A–C: Prometheus + Alertmanager + Grafana on monitor

Deployed `stage4/monitoring/` stack (Prometheus 2.54.1, Alertmanager 0.27.0, Grafana 11.2.0) to monitor (monitor, monitor.lab.example). All images sha256-pinned in `docker-compose.yml`. Six alert rules in `prometheus/rules/alerts.yml` covering JMX exporter down, high heap, HAProxy backends down, MySQL exporter down, MySQL server down, and high CPU. Prometheus scrapes all four app CTs plus log-indexer.

### Item D: 90/10 HAProxy canary split

HAProxy runtime API socket: `/var/run/haproxy/admin.sock` (not `/var/run/haproxy.sock`).

```
echo "set server petclinic/legacy-app weight 90" | socat stdio /var/run/haproxy/admin.sock
echo "set server petclinic/container-app weight 10" | socat stdio /var/run/haproxy/admin.sock
```

Verified via Prometheus: `haproxy_server_weight{server="legacy-app"} = 90`, `haproxy_server_weight{server="container-app"} = 10`. Traffic test (100 requests): 90 to legacy, 10 to container — exact split confirmed.

**Lesson:** HAProxy runtime API changes are ephemeral (lost on reload). For durable weight changes, update `haproxy.cfg` and reload. The runtime API is for zero-downtime canary rollouts where you want instant rollback via `set server ... weight 90/10` reversal without a reload.

### Item E: JVM experiments (all proved on container-app build 26)

| Experiment | Command | Result |
|---|---|---|
| MaxRAMPercentage | `--memory=256m -e JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=50` | `MaxHeapSize = 134217728` (128 MB = exactly 50% of 256 MB) — PROVED |
| Exit 137 | `docker run --name lab-oom-test --memory=32m --memory-swap=32m eclipse-temurin:21-jdk-alpine java -XX:+AlwaysPreTouch -Xms60m -Xmx60m HeapFill` | `OOMKilled=true ExitCode=137` — PROVED. Key: `-XX:+AlwaysPreTouch` forces heap page commit at JVM startup, triggering cgroup OOM killer before any app code runs. Without that flag the JVM reserves virtual memory pages lazily and the container exits 0. |
| GC at 1 CPU | `--cpus=1` | `UseSerialGC = true` instead of G1GC — PROVED (JVM auto-selects SerialGC below ergonomic CPU threshold) |
| SIGTERM graceful | `docker stop` (SIGTERM → SIGKILL after 10s) | ExitCode=0, "SIGTERM-received" logged — PROVED |

### Item F: Splunk Enterprise 10.6.1.1 on log-indexer

**log-indexer** — log-indexer, log-indexer.lab.example, Ubuntu 24.04, 4 GB RAM, 32 GB disk.

**sha512 verified at install:** `2172ed26173b4f...` for UF, `f3f67f699fcd89...` for Enterprise.

**Circular dependency in Splunk 10.x (PostgreSQL PDL):**
Splunk 10.x defaults `defaultKVStoreType = cohosted` — uses PostgreSQL on port 5433 as the KVStore backend. The PDL supervisor fetches its db password from the REST API at startup (`/servicesNS/nobody/system/storage/passwords/postgres:kvstore.pdl`). But that endpoint returns 404 until an admin user exists. No admin user can be created until KVStore is running. Classic chicken-and-egg.

**Fix:** Switch to the legacy MongoDB KVStore before first boot:
```ini
# /opt/splunk/etc/system/local/server.conf
[kvstore]
disabled = 0
defaultKVStoreType = local   # local = MongoDB 8.0 on port 8191

[postgres]
disabled = 1
```
With `local` KVStore, `user-seed.conf` creates the admin user cleanly, the file is deleted on startup (logged as "DELETED"), and auth works immediately via REST: `curl -sk https://localhost:8089/services/auth/login -d 'username=admin&password=...'` returns `sessionKey`.

**Verified:**
- HTTP 200 at `http://log-indexer.lab.example:8000/en-US/account/login`
- `splunk version` = `Splunk 10.6.1.1 (build b2ae2962645c)`
- License: `expiration_time: 1798564967` = **2026-12-29 17:22:47 UTC** (60-day download trial; confirmed via `splunk list licenses` on 2026-10-30)
- Admin auth: REST `sessionKey` returned successfully

**Receiving port 9997 enabled (least-privilege):**
```
splunk enable listen 9997 -auth admin:...
```

**Indexes created:**
- `lab_app` — Jetty application logs
- `proxy_logs` — HAProxy access logs
- `db_logs` — MySQL error + slow query logs

**Universal Forwarders installed on the lab containers:**
All four sha512-verified (`splunkforwarder-10.6.1.1-b2ae2962645c-linux-amd64.deb`).

| CT | Host | Forwarding | Index | Sourcetypes |
|---|---|---|---|---|
| 730 | legacy-app | `/var/log/petclinic/app.log` + syslog | lab_app | `jetty_access`, `syslog` |
| 731 | container-app | `/var/log/petclinic/app.log` + syslog | lab_app | `jetty_access`, `syslog` |
| 732 | lb | `/var/log/haproxy.log` | proxy_logs | `haproxy` |
| 733 | db | `/var/log/mysql/error.log`, `/var/lib/mysql/db-slow.log` | db_logs | `mysql:error`, `mysql:slow` |

Petclinic systemd service on CTs 730 and 731 redirected to file via drop-in: `StandardOutput=append:/var/log/petclinic/app.log`.

**SPL parity proof:**
```
index=lab_app sourcetype=jetty_access | stats count by host
```
Result: `container-app 521 PASS`, `legacy-app 428 PASS` — same sourcetype on both legacy and container hosts.

**No-events alert (`lab_no_app_events`):**
```
index=lab_app sourcetype=jetty_access earliest=-5m | stats count | where count=0
```
Saved search, scheduled `*/5 * * * *`, severity=medium.

**Full drill (2026-10-30):**
- 18:05:52Z — container-app UF stopped (`splunk stop`)
- 18:13:12Z — legacy-app UF stopped (required: both hosts send to `lab_app`)
- 18:20:00Z — count=0 confirmed via CLI search
- 18:25:01Z — scheduler.log entry: `savedsearch_name="lab_no_app_events"`, `status=success`, `result_count=1`, **`condition=1`** (alert condition fired)
- 18:30:01Z — second scheduler fire, same result (`condition=1`)
- 18:30:35Z — both UFs restarted
- 18:32Z — events resumed: `container-app=641`, `legacy-app=3962`

**Root cause of missing scheduler entries (first Splunk start):**
`Can't persist saved-search history due to the KV-Store either being disabled or failing` at 17:33:16 stopped ALL scheduled search execution. Fix: restart Splunk with `--run-as-root` to clear the KVStore init race. After restart, scheduler picks up `lab_no_app_events` within one cron cycle.

**Event counts at close (2026-10-30 ~18:00 UTC):**
- `lab_app`: 72,804+ events (1,398 `jetty_access`, 71,863 `syslog`)
- `proxy_logs`: 1,185 events (`haproxy`)
- `db_logs`: 525 events (116 `mysql:error`, 409 `mysql:slow`)

**Lesson:** "The Splunk 10.x PostgreSQL KVStore is a sharp edge on first install — nothing in the documentation warns you that `user-seed.conf` silently fails when the KVStore can't start. The diagnostic path is `sup-pkg-kvstore-pdl.log`, not `splunkd.log`. I'd add this to our run-book before any enterprise upgrade."

### Item G: MySQL write + read-back via HAProxy (lb.lab.example)

**Row counts:** before insert = 11 rows, after insert = 12 rows.

```sql
INSERT INTO owners (first_name, last_name, address, city, telephone)
VALUES ('Stage5', 'ItemG', '42 Proxmox Lane', 'labtown', '5551234567');
SELECT id, first_name, last_name, address, city FROM owners WHERE last_name='ItemG';
-- id=13  first_name=Stage5  last_name=ItemG  address=42 Proxmox Lane  city=labtown
```

**Read-back via HAProxy** (not direct-to-CT):
```
curl -L http://lb.lab.example/petclinic/owners/13
HTTP 200 — "Owner Information: Stage5 ItemG, 42 Proxmox Lane, labtown"
```

Route: workstation → HAProxy:80 (lb.lab.example) → backend petclinic → MySQL 8.4 (db).
Confirms full stack: HAProxy LB → container petclinic → MySQL write AND read.

**Lesson:** Always read-back through the LB, not directly to the app host. If the LB config is wrong (wrong backend port, wrong path rewrite), a direct test passes while production fails.
