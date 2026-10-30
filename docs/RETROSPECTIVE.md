# Retrospective and change log of fixes

Built from `git log --reverse -p` (22 commits, `cffa7de` to `775a06b`, 2026-10-29 18:38 to 2026-10-30 07:54, plus the remediation commit `092489f`, Part 5, the Stage 5 commits `afdf6ad`, `11f7a77`, `381af30`, `1d816f1`, Part 6, and the fix pass `18b8148`, `03f50c2`, Part 7). Error messages and inline diagnostics are drawn from the commit diffs and the NOTES.md build log.

Conventions:
- **F##** = a fix tied to a commit. **E##** = an environment fix that never reached git (found only in the transcript).
- "By hand" = what a person doing this manually would have learned.
- Anything not in the sources is **not recorded**. No secret values appear; credentials are described by role only.

Commit map (for orientation): `cffa7de` scaffold; `46e9de9` phase 1 results; `c585937`, `65b29af`, `9242c03`, `98ee711`, `aac0a71`, `b5bf465`, `8aa94f7`, `b603623`, `cac7a96`, `a1cac10` stage 3 fixes (builds 1 to 16); `54982f4` Hiera pin; `cac6a88` scripts; `ebdbc99` Jetty base and httpchk; `f9d4d7d`, `c76f924` dual-mode and Trivy gate; `9a499e3`, `aedb19d`, `32669b0`, `54eb22b`, `510ea50` builds 21 to 26 fixes; `775a06b` pin to build 26.

---

## Part 1: Fix log

### F01 `cffa7de` Hiera data directory was git-ignored
- **Symptom:** `git add stage4/openvox/hiera/data/` answered "The following paths are ignored by one of your .gitignore files".
- **Root cause:** `.gitignore` had `data/`, which matches any directory named `data`, including Hiera's.
- **Fix:** `.gitignore`: `data/` became `/data/` (repo root only), before the first commit.
- **By hand:** an unanchored ignore pattern silently drops config you care about. Check `git status` after creating directories.

### F02 `46e9de9` Phase 1 first real run, plus two launch problems
- **Symptom:** (a) `bash: /phase1/phase1-jetty12-ee8.sh: No such file or directory` inside the container; (b) `/bootstrap.sh: line 1: ï»¿#!/bin/bash: No such file or directory`.
- **Root cause:** (a) the bind-mount source was given as a Git-Bash style path; the listing showed junk `work;C` and `phase1;C` entries (path translation, inferred). (b) PowerShell wrote the bootstrap script with a UTF-8 BOM.
- **Fix:** re-ran with Windows-style paths from PowerShell; the BOM was only a warning and the script ran. Commit records the results `HTTP 200` for Jetty 9.4.58 and 12.1.14.
- **By hand:** on Windows, decide once which shell owns paths and file encodings. The BOM problem came back twice (F18, F19).

### F03 `c585937` Stage 3 bring-up, eight separate problems in one commit
| Sub | Symptom (as observed) | Root cause | Fix (before/after gist) | By hand |
|---|---|---|---|---|
| a | `ionicons-api ... requires a greater version of Jenkins (2.504.1) than 2.479.3` (plugin install failed) | pinned Jenkins too old for `:latest` plugins | `FROM jenkins/jenkins:2.479.3-lts-jdk21` to `:lts-jdk21` | unpinned plugins and a pinned core drift apart |
| b | `/bin/sh: 1: gpg: not found`, exit 127 | image is Debian bookworm, script used Ubuntu repo and lacked gnupg | `ubuntu noble` to `debian bookworm`; add `gnupg ca-certificates` | check the base distro before copying install snippets |
| c | Jenkins crash loop; `NoSuchFileException: /run/secrets/cosign_key_b64`; then `UnknownConfiguratorException: ... root element: jobs` | secret file not mounted; `jobs:` needs the `job-dsl` plugin | mount `keys/cosign_key_b64`; add `job-dsl:latest` to `plugins.txt` | JCasC fails closed: read the first SEVERE line |
| d | `MissingMethodException: ... TriggerContext.pollSCM()` | Pipeline DSL name used in Job DSL | `pollSCM('H/5 * * * *')` to `scm('H/5 * * * *')` | two DSLs, similar names |
| e | `Checkout of Git remote 'file:///workspace' aborted because it references a local directory` | Jenkins blocks local checkouts by default | add `-Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true` to `JAVA_OPTS` | `docker compose restart` did not apply it; `up -d --force-recreate` did |
| f | Syft/Trivy would have mounted a `docker.sock` that DinD does not provide | design | new stage "Export image tar" (`docker save`), scanners take `--input` | no socket mounts near a CDE |
| g | `COPY ../stage2/entrypoint.sh` outside build context | Docker cannot copy above the context | `COPY stage2/entrypoint.sh` | context is the repo root |
| h | `open /keys/cosign.key: is a directory` while generating keys | `docker compose up` had created a *directory* for the missing bind-mount file | removed the directory; regenerated keys | compose bind-mounts of missing files create directories |
- Also in this commit: scanner and base images pinned by sha256 (resolved 2026-10-29); the cosign passphrase moved from an env substitution to a literal in `casc.yaml` (a committed credential; value not quoted, tracked as an open item).

### F04 `65b29af` Three more stage 3 blockers
- **Symptoms:** `WorkflowScript: 237: illegal string body character after dollar sign`; `fatal: detected dubious ownership in repository at '/workspace/.git'`; `ERROR: Couldn't find any revision to build`.
- **Root causes:** `$(date ...)` inside a Groovy `"""` string; the mounted repo's owner differed and a `--global` safe.directory landed in the `jenkins-home` volume and was lost; job watched `*/main` but the repo is `master`.
- **Fix:** `\$(date ...)` plus a `TS=` variable; `git config --system --add safe.directory '*'` in the image (`/etc/gitconfig`); `branch('*/main')` to `branch('*/master')`.
- **By hand:** Jenkins only sees committed files, and a changed `casc.yaml` needs a JCasC reload (`/manage/configuration-as-code/reload`, HTTP 302). Also: `/build` returns 400 `Nothing is submitted` on a parameterised job; use `buildWithParameters`, with the crumb fetched in the same cookie session (HTTP 403 otherwise).

### F05 `9242c03` Dockerfile heredoc
- **Symptom:** `dockerfile parse error on line 51: unknown instruction: cd (did you mean cmd?)`.
- **Root cause:** `# syntax=docker/dockerfile:1.7` frontend did not load reliably from DinD, so the legacy parser read the heredoc body as instructions.
- **Fix:** heredoc to `printf '%s\n' ...`; syntax directive removed.
- **By hand:** avoid builder-specific syntax in a pipeline you do not control.

### F06 `98ee711` Syft source scheme
- **Symptom:** `could not determine source ... docker: not available / podman / containerd / oci-registry UNAUTHORIZED` for a bare tar path.
- **Root cause:** Syft guesses the source type from the string.
- **Fix:** `/work/x.tar` to `docker-archive:/work/x.tar`.

### F07 `aac0a71` Bind mount across DinD
- **Symptom:** Syft: `file does not exist: docker-archive` although the tar had just been written.
- **Root cause:** `-v $(pwd):/work` is resolved by the DinD daemon, which could not see `/var/jenkins_home/...`.
- **Fix:** mount the `jenkins-home` volume into `lab-dind` at the same path.
- **By hand:** the classic DinD volume problem: paths are meaningful to the daemon, not the client.

### F08 `b5bf465` Trivy set to report-only (regression, later reversed)
- **Symptom:** first gated scan printed `Total: 102 (HIGH: 79, CRITICAL: 23)` and failed the build (`Trivy found CRITICAL or HIGH vulnerabilities with available fixes. Pipeline blocked.`).
- **Root cause:** PetClinic v5.3.22 carries known CVEs in frozen jars.
- **Fix at the time:** `--exit-code 1` to `--exit-code 0` and the `error()` call removed, so the pipeline could reach signing. This removed the gate.
- **Reversed in F16**, after the coordinator pointed out that report-only is not a gate.
- **By hand:** switching a gate off to "see the rest of the pipeline" is a decision, not a convenience. Baseline instead.

### F09 `8aa94f7` cosign referrers mode
- **Symptom:** `invalid argument "oci-1-1" for "--registry-referrers-mode" flag: in order to use mode "oci-1-1", you must set COSIGN_EXPERIMENTAL=1`.
- **Root cause:** cosign v2.5.0 gates that mode behind an experimental flag.
- **Fix:** dropped `--registry-referrers-mode=oci-1-1` and `COSIGN_EXPERIMENTAL=0`; default tag scheme (`sha256-<digest>.sig`) works against a plain registry.
- **By hand:** the signature is just another tag in the repo; `tags/list` shows it.

### F10 `b603623` and F11 `cac7a96` cosign key access (three attempts)
- **Symptoms:** (1) `open /run/secrets/cosign.key: permission denied`, and `/run/secrets/` did not exist in the container; (2) same error at `/workspace/keys/cosign.key`, file shown as `-rw------- 65532 65532`; `chmod` from inside failed.
- **Root cause:** Docker Desktop on Windows did not translate the single-file bind mount, and remaps ownership on the NTFS-backed mount to uid 65532, which Jenkins (uid 1000) cannot read.
- **Fix:** F10 moved the path to `/workspace/keys/`; F11 piped the key and public key into the named volume with `chown jenkins:jenkins` and `chmod 600`, and pointed sign/verify at `/var/jenkins_home/cosign.{key,pub}`.
- **By hand:** key material belongs in a real filesystem you control. The copy step is not scripted anywhere in the repo.

### F12 `a1cac10` cosign over plain HTTP
- **Symptom:** `Get "https://lab-registry:5000/v2/": http: server gave HTTP response to HTTPS client`.
- **Root cause:** `--allow-insecure-registry` relaxes TLS verification only.
- **Fix:** add `--allow-http-registry` to sign and verify. A `registries.conf` added at the same time was belt-and-braces.
- **Result:** build 16 succeeded (digest `sha256:cefa443ba2568ff42c276c479576735a09a34d882df5ba7465c7149531718530`), cosign verify exit 0.

### F13 `54982f4` and `cac6a88` (not fixes: pin and scripts)
- Hiera pinned to the build 16 digest; `flip-weights.sh`, `provision-legacy.sh`, `provision-container.sh` added.
- **Process note:** the pinned digest had never run. When first started on container-app it served HTTP 404 with Jetty stuck in `STARTING` (see F15).

### F14 `ebdbc99` (first half) Jetty 12 base detection
- **Symptom:** container log: `WARN : Unknown Arguments detected.  Consider using --dry-run or --exec` and `WARN : Argument: --jetty.base=/var/lib/jetty (interpreted as a JVM argument, from <command-line>)`; then `Deployment monitoring of [/webapps]`, `Started oejs.Server@...{STARTING}`, HTTP 404 on every path.
- **Root cause:** Jetty 12 `start.jar` does not accept `--jetty.base=`. `--dry-run` showed `-Djetty.base=/`. With no `start.d`, no `ee8-deploy` module was enabled and the WAR was never deployed. The Dockerfile's `--add-modules=... --jetty.base=...` step had the same fault and, with `|| true`, failed silently. (`:fixed` re-ran `--add-modules` and said "already enabled", which was misleading because it was reading a different base.)
- **Fix:** `stage2/entrypoint.sh`: `--jetty.base="${JETTY_BASE}"` to `"jetty.base=${JETTY_BASE}"`. `stage2/Dockerfile`: the `RUN java -jar start.jar --jetty.base=... --add-modules=...` pipeline replaced by `mkdir -p "${JETTY_BASE}/start.d"` and five `echo "--module=..." > .../start.d/<name>.ini` lines (server, http, ee8-deploy, ee8-apache-jsp, ee8-glassfish-jstl).
- **By hand:** `printf "--module=x"` fails (`printf: Illegal option --`), so use `echo`. Always check what is enabled with `--list-config`/`--dry-run`. The original script worked only because it ran inside the base directory.
- **Scope gap:** this fixed `stage2/Dockerfile` only. The file Jenkins builds, `stage3/Dockerfile`, kept the broken step until F20.

### F15 `ebdbc99` (second half) HAProxy 2.8 health-check syntax
- **Symptom:** `haproxy.service` failed; `[ALERT] config : parsing [/etc/haproxy/haproxy.cfg:64] : 'option httpchk' : hiding headers or body at the end of the version string is unsupported.Use 'http-check send' directive instead..`
- **Root cause:** `option httpchk GET /petclinic/owners?lastName= HTTP/1.1\r\nHost:\ localhost` is no longer accepted by HAProxy 2.8.30.
- **Fix (before/after):**
  - before: `option httpchk GET /petclinic/owners?lastName= HTTP/1.1\r\nHost:\ localhost`
  - after: `option httpchk` plus `http-check send meth GET uri /petclinic/owners?lastName= ver HTTP/1.1 hdr Host localhost`
- **Evidence in the commit:** legacy-app HTTP 200, container-app HTTP 200, canary/cutover/rollback sampled 200s. **Caveat:** container-app was running the ad-hoc `petclinic:fixed4` image (`sha256:53c9fdbb757e89e2812981b9e4ec8fd2cd1430d23e6313b77735f7819f9da334`), a layer on top of build 16 with a hand-patched WAR and replaced entrypoint, not the Hiera digest.
- **Left behind:** `stage4/openvox/manifests/modules/petclinic/files/haproxy.cfg` was copied before this fix and still has the old line.
- **By hand:** `haproxy -c -f` before restarting; remember HAProxy configs age across versions (README even says 2.9; host has 2.8.30-0ubuntu0.24.04.1).

### F16 `f9d4d7d` Dual-mode "proof" on a side image; Trivy gate restored
- **What was done:** `patch_war.py` (driver class placeholder, `ignore-failures`, `db.script` placeholders, inject `h2-2.1.214.jar`), new env vars, and `stage3/Dockerfile.h2mysql` building `FROM` the ad-hoc `fixed4`. Result recorded: `sha256:f2f1cb55...` returned HTTP 200 for H2 and for MySQL. `.trivyignore` introduced; `--exit-code 1` and `--ignorefile` restored.
- **Problems on the way:**
  - H2 run: `java.sql.SQLException: Unable to load class: org.h2.Driver` (jar absent from the MySQL build); then a URL with `;INIT=CREATE SCHEMA...` gave `Caused by: java.lang.ClassNotFoundException: SCHEMA`.
  - Every "HTTP status:" came back blank because **container-app had no `curl`** (`sh: 19: curl: not found`); this was misread as app failure for roughly 25 minutes.
  - Docker Desktop could not push/pull `registry.lab.example:5000` (`http: server gave HTTP response to HTTPS client`); `~/.docker/daemon.json` was edited to add the insecure registry, and the image was built on container-app instead.
  - First `.trivyignore` was a partial list written from memory; the real report had 93 IDs.
  - CT inventory in NOTES was first written with invented RAM/disk numbers and corrected from `pct config`.
  - The recorded "no credentials in the WAR" check printed only lines containing driver/script names.
- **Why this was the process failure:** see Part 3.

### F17 `c76f924` Fold into the main build path; complete ignore list
- **Change:** H2 jar download added to both Dockerfiles; `Dockerfile.h2mysql` deleted; `.trivyignore` replaced with the full build-16 list; HAProxy config copy committed.
- **Introduced:** BOM and mojibake via a PowerShell read/write round trip (F18/F19); a stale `haproxy.cfg` copy (see F15).
- **Symptom it was meant to fix:** build 20 failed `Trivy gate FAILED: CRITICAL or HIGH vulnerabilities found that are not in .trivyignore` (the gate working as designed against the partial list).

### F18 `9a499e3` Trivy timeout (build 21)
- **Symptom:** `FATAL ... failed to analyze layer (sha256:d390ebe6...): post analysis error: walk dir error: context deadline exceeded`; `trivy-report-c76f924.txt: No such file`.
- **Root cause:** nested jars (now including the 2.5 MB H2 jar) exceed Trivy's default 5 minutes. (Trivy also downloaded its ~131 MiB DB at scan time.)
- **Fix:** `--timeout 15m` placed before the `image` subcommand.
- **Side effect:** the PowerShell edit re-wrote `stage3/Jenkinsfile` with a BOM.

### F19 `aedb19d` BOM in Jenkinsfile and Dockerfiles (build 22)
- **Symptom:** `groovy.lang.MissingPropertyException: No such property: <invisible char> for class: groovy.lang.Binding`, in `WorkflowScript:1`.
- **Root cause:** PowerShell `WriteAllText(..., UTF8)` emits EF BB BF; Groovy parsed it as a property.
- **Fix:** rewrite with `UTF8Encoding($false)`. Coordinator note: this is a Windows editor artifact.
- **By hand:** `head -c3 | xxd` is a ten-second check. Mojibake (`â€”`) from the same round trip remains in comments and one stage name.

### F20 `32669b0` New CVE from the injected jar (build 23)
- **Symptom:** gate failed; the only un-ignored ID in the report was `CVE-2022-45868`.
- **Root cause:** H2 2.1.214 web console has an empty-password issue.
- **Fix:** risk-accepted in `.trivyignore` with rationale (console never started; jar only supplies the JDBC driver).
- **By hand:** every dependency you inject needs its own scan pass; baselines expire.

### F21 `54eb22b` Jetty module init in the Jenkins Dockerfile (build 24)
- **Symptom:** H2 run on digest `sha256:fabfc4098c30c9e9ff7449c4641f1a428352ce611ce0f1df1ef467c28b893ee2`: HTTP 000; log `ERROR : No enabled jetty modules found!`, `${jetty.base} = /var/lib/jetty`, `Please create and/or configure a ${jetty.base} directory.`
- **Root cause:** the F14 fix had been applied to `stage2/Dockerfile` only; `stage3/Dockerfile` (what Jenkins builds) still used `--add-modules`.
- **Fix:** same five `start.d/*.ini` writes in `stage3/Dockerfile`. (Two lines use `>>`; the files are new, so it is harmless.)
- **Doc discrepancy:** the NOTES change-log row for build 24 says "HTTP 503"; the transcript shows HTTP 000 here and 503 for build 25.
- **By hand:** when you fix a bug in one copy of a file, `grep` for the other copies.

### F22 `510ea50` Literal datasource attributes (builds 25 and 26)
- **Symptom:** build 25 digest `sha256:4ba639e4ef163b82a7a51a47a5e0c80b43c40b01cb0db254e21e3d3d492179cc`: H2 run returned HTTP 503 on `/petclinic/` and `/petclinic/owners?lastName=`; context `a=UNAVAILABLE`; `java.sql.SQLException: Driver:org.h2.Driver@... returned null for URL:jdbc:mysql://localhost:3306/petclinic?useUnicode=true`.
- **Root cause (latent since build 16):** `datasource-config.xml` in the built WAR carried literal url, username and password; only `driverClassName` had been turned into a placeholder, so `-Djdbc.url` had nothing to override.
- **How it was found:** `docker create`, `docker cp` the WAR out, read the XML with Python `zipfile`. The runtime `env` and the simulated `JAVA_OPTS` were fine, which is what kept the search off the entrypoint.
- **Fix (before/after gist):** `patch_war.py` (stage2 and stage3) added three replacements: `p:url` to `"${jdbc.url}"`, `p:username` to `"${jdbc.username}"`, `p:password` to `"${jdbc.password}"`. Values of the literals are intentionally not shown.
- **Result:** build 26 on `sha256:f1a2edaec14300cd4e3cd29966c7248ef5f7de024bf12e71e79ef1e4af30203d`: H2 HTTP 200 on both paths (transcript); per the coordinator, MySQL on db also 200 on both paths and the same digest confirmed by `docker inspect`.
- **By hand:** inspect the shipped artifact, not the source. A source-tree check (placeholders present) was exactly what misled the earlier analysis.

### F23 `775a06b` Pin and provisioning script (build 26)
- Hiera `petclinic::image_digest` and `provision-container.sh` moved to the build 26 digest.
- **`provision-container.sh` env vars:** it passed Spring Boot style `SPRING_DATASOURCE_URL`/`_USERNAME`/`_PASSWORD`, which this plain Spring Framework WAR silently ignores. It now passes `JDBC_DRIVER_CLASS`, `JDBC_URL`, `JDBC_USER`, `JDBC_PASSWORD`, `DB_SCRIPT`, `JPA_DATABASE`. The same mistake had appeared in the transcript twice before it was noticed: the first containers logged `JDBC_URL=jdbc:mysql://localhost:3306/petclinic`.
- **Redeploy result (coordinator):** container-app redeployed by digest; HAProxy status, canary 90/10 and rollback each 5/5 HTTP 200.
- **Not recorded:** build 26 Trivy counts; MySQL write plus read-back row count.

---

## Part 2: Environment fixes never committed

| ID | Symptom | Root cause | What was done | By hand |
|---|---|---|---|---|
| E01 | Only legacy-app existed after running `scripts/hypervisor-lxc-setup.sh`; apt `Temporary failure resolving 'archive.ubuntu.com'`, exit 100 | script set `GW` and `DNS` to `gateway.lab.example`, which does not exist; the hypervisor host is the NAT gateway (`MASQUERADE <your-lan-subnet>/24`); `set -e` aborted the loop | containers container-app, lb, db created by hand; `ip route add default via hypervisor.lab.example` and `nameserver 8.8.8.8` set inside each CT | the repo script and `pct config` still show `gateway.lab.example`; fix is not persistent |
| E02 | `apt-get` waiting on a lock for minutes | earlier runs hung on DNS and left apt processes | killed apt/dpkg, removed lock files, `dpkg --configure -a` | find the stale PID before deleting locks |
| E03 | `E: The repository 'https://packages.adoptium.net/artifactory/deb noble InRelease' is not signed.`; `java: command not found` | `gpg` missing when the key was fetched | used `openjdk-21-jdk-headless` (21.0.12.1) | |
| E04 | `local-lvm` looked like 16 GB free | `pvs` showed PV free space outside the thin pool | read `pvesm status` to get the real available capacity in the thin pool | |
| E05 | legacy-app `petclinic-legacy` crash-looped `status=254`; `ERROR : Nothing to start, exiting ...` | `start.ini` had been written to `/root` (cwd of `pct exec`), and `sudo` was missing on the first attempt | moved `start.ini` into the base | |
| E06 | WAR "no main manifest attribute" when launched with `java -jar` | misdiagnosis: it is a plain WAR, not executable | reverted to Jetty unit | read the artifact type first |
| E07 | `Communications link failure ... Connection refused` to localhost | unit set `-Dspring.datasource.*`; this WAR reads `jdbc.*`; also `\&` in `ExecStart` was literal | wrote the unit via Python; used `-Djdbc.*` | |
| E08 | legacy-app HTTP 503 while Jetty was `Started` | datasource literals in the WAR (same as F22) | hand-patched the WAR on legacy-app with `zipfile`, HTTP 200; this hand-patched WAR then became `fixed`/`fixed4` | the manual patch masked the pipeline bug |
| E09 | `petclinic` DB invisible to the app user | grants/bind address | `CREATE DATABASE`, `GRANT ALL ... TO 'petclinic'@'%'`, `bind-address = 0.0.0.0`, restart | |
| E10 | Admin credential lookup after context loss | the agent lost the known value after a conversation compaction and tried guessing/reading hashes before re-reading `casc.yaml` | recovered from config | keep operational constants in a notes file |
| E11 | `--no-cache` rebuild "used cached layers" confusion | build context differed on container-app vs workstation (`stage3/patch_war.py` not found) | copied flat | |

---

## Part 3: The step 2 process lesson

**Prove claims on the artifact you actually ship.**

- First proof (F16): `sha256:f2f1cb5586a4932580f0d732b1b0591109baa8c72d4e5eaa2b03262e089db34f`, a side image `FROM` an ad-hoc image with a hand-patched WAR. It returned 200 for H2 and MySQL on `/petclinic/`.
- What it hid: the Jenkins-signed digests could not do it at all. Build 16's image never deployed the WAR (no `start.d`) and had localhost literals; build 24 had no modules; build 25 had literal datasource attributes (HTTP 503). The signed, scanned artifact and the tested artifact were different objects.
- The coordinator caught it: "re-run the step 2 H2/MySQL proof on the image Jenkins built and signed, not a side image." The rework needed builds 21 to 25 (21, 22 and 23 failed in Jenkins; 24 and 25 passed Jenkins but failed when run) before 26 worked.
- Weak checks compounded it: `/petclinic/` is a welcome page, the H2 log still said `MySQL57Dialect`, and the credential "grep proof" printed only selected lines.
- Practical rule: the evidence has to name the digest, the verb (pull by digest) and a DB-backed URL, plus a write and read-back.

---

## Part 4: Themes, what went well, what went poorly

### Themes
1. **Silent no-ops are the dominant failure mode:** Jetty ignored `--jetty.base=`; `--add-modules` did nothing; Spring ignored `spring.datasource.*`; `SPRING_DATASOURCE_*` env vars were ignored; `|| true` hid a failed init.
2. **Build-time config baked into artifacts** (Maven filtering) defeats runtime override until you open the WAR.
3. **Windows host friction:** bind mounts, uid mapping, BOMs, path translation.
4. **Version drift in tools:** HAProxy 2.8 syntax, cosign flags, Jetty 12 argument parsing, Trivy defaults.
5. **Copies diverge:** `stage2` vs `stage3` Dockerfiles, `haproxy.cfg` vs module copy, docstrings.
6. **Documentation overclaims** ("MySQL 8.4" while the host ran 8.0.36 until `092489f`, "checked" Splunk docs, "no passwords in WAR", OpenVox "enforces").

### What went well
- First real run of the Phase 1 script: both Jetty lines served HTTP 200.
- Supply-chain controls actually work: gate failed on a partial baseline (build 20), on a new CVE (build 23), and cosign sign/verify exits 0.
- Digest-based thinking was applied consistently (pull by digest, Hiera holds a digest).
- The coordinator's checks (gate restore, side-image objection) steered the work back to evidence.
- Eventually found root cause by opening the shipped WAR.
- The lab containers are named and tagged lab for easy identification and removal..

### What went poorly
- Turned the Trivy gate off for convenience (F08).
- Declared "PROVED" on a side image (F16), and wrote "no passwords ... in any WAR entry" without a complete check.
- Fixed Jetty init in one Dockerfile and not the one that mattered (F14 to F21).
- Invented CT RAM/disk numbers in NOTES before checking Proxmox.
- A missing `curl` produced false failures for a while.
- OpenVox was never run (until the remediation pass, R02), yet docs said it enforced digests. The module copy of `haproxy.cfg` was stale until `092489f`.
- Infrastructure fixes (gateway, DNS) were not persisted or put back into the script.
- Side effect outside the repo: Docker Desktop `daemon.json` edited.
- Declared Stage 5 complete with files uncommitted and items unreported (R08); accepted hand-run queries and a zero-count as alert proof (R10); trusted `--noop` against a stale module copy (R13); misread a license date (R09).
- Committed credentials of lab scope (cosign passphrase in `casc.yaml`, default DB credential in Hiera and entrypoint); removed and rotated in `092489f` (R04) but not purged from history.

### Process lessons
1. Prove it on the shipped digest, with a DB-backed URL and a write.
2. Open the artifact before debugging the runtime.
3. After any fix, search for sibling copies.
4. A gate is only a gate if it fails builds; use a baseline with owners and expiry, not `--exit-code 0`.
5. Commit what Jenkins will build before triggering it.
6. Verify tools exist where you measure (`curl`), and treat blank output as unknown, not failure.
7. Never write numbers or "checked" claims you did not observe; mark "not recorded".
8. Keep one list of constants and one change log, updated as you go (NOTES.md "Change log" now covers builds 21 to 26).
9. Fix infra in the script, not just in the shell.

---

## Part 5: Remediation pass `092489f` (R01 to R07)

Facts: verified by the coordinator (MySQL 8.4.13 on db, OpenVox 7.37.2 on container-app) or reported by the agent as marked. Correction to earlier text: every "MySQL 8.4" statement in NOTES and in the first draft of these docs was **wrong when written**; the database was `mysql-server-8.0 (8.0.36-2ubuntu3)` until this commit.

### R01 MySQL 8.0 to 8.4 upgrade
- **Symptom:** `apt` refused the MySQL repo; the 8.4 package could not be found under the expected name.
- **Cause:** the repo signing key had expired (2025-10-22); `mysql-apt-config` wrote component `mysql-8.4` but the repo uses `mysql-8.4-lts`; the package is `mysql-community-server`, not `mysql-server-8.4`.
- **Fix:** key refreshed from `RPM-GPG-KEY-mysql-2025` (new expiry 2027-10-23); sources.list component set to `mysql-8.4-lts`; `mysql-community-server` installed. Bind address, the app user grant and the owners count (10) were preserved; the write test passed on 8.4.13. The Hiera JDBC URL gained 8.4 connection parameters.
- **Lesson:** expired third-party repo keys silently break upgrades; check key expiry and `apt-cache policy` for exact component and package names, because vendors rename them without a redirect. Also: do not write a version into docs that you have not read from the host.

### R02 OpenVox installed and run masterless
- **Symptom:** nothing had ever applied the manifests; the first install attempt hit a 404 on `apt.voxpupuli.org`.
- **Cause:** the Vox Pupuli repo is not a standard `dists/` tree; it is installed from `openvox7-release-ubuntu24.04.deb`. The unit template also lacked `JDBC_DRIVER_CLASS`, `DB_SCRIPT`, `JPA_DATABASE`, and the module's `haproxy.cfg` copy still had the rejected `option httpchk` form.
- **Fix:** installed the official release deb (OpenVox 7.37.2 on container-app); template and `haproxy.cfg` fixed; `puppet apply` run masterless. First apply exit 2 (changes applied: systemd unit, container started on the pinned digest).
- **Evidence (as reported):** drift test: the container was swapped to `:latest`, apply re-run, pinned digest restored.
- **Lesson:** exit 2 with `--detailed-exitcodes` means "changes applied". A claim of enforcement needs a drift test, not a manifest.

### R03 Hiera datadir mismatch
- **Symptom:** lookups returned nothing or the wrong values; several iterations to isolate (exact error text not recorded).
- **Cause:** the configured datadir (`hieradata`) did not match the repo layout (`hiera/data`).
- **Fix:** aligned `hiera.yaml` to the real path and added a gitignored `data/secrets.yaml` level above `common.yaml`.
- **Lesson:** make `puppet lookup --explain` the first debug step; do not assume the hierarchy path equals the directory you edited.

### R04 Secrets out of git: rotate rather than rewrite history
- **Symptom:** a committed cosign passphrase literal and Jenkins admin default (`casc.yaml`, `docker-compose.yml` `:-` fallbacks) and a Hiera DB password in `common.yaml`.
- **Cause:** lab shortcuts from the initial scaffold (F03) that survived to a "verified" state.
- **Fix:** fallbacks removed (pure `${VAR}`); Hiera password moved to gitignored `secrets.yaml`; new cosign keypair; Jenkins admin, MySQL app and passphrase credentials rotated; `.env` gitignored. **History not rewritten**; old values remain in local history and are dead.
- **Lesson:** rotate first, because rewriting history cannot recall a copy that already exists (backups, clones, the Jenkins volume). Rewrite only if the repo ever leaves the machine, and then still rotate. No value is quoted in these docs.

### R05 Upstream defaults still baked into the WAR
- **Symptom:** `data-access.properties` in the shipped WAR still carries upstream PetClinic default JDBC properties, including a default username and password.
- **Cause:** `patch_war.py` makes the XML placeholders resolve to injected `-Djdbc.*`, but leaves the properties file defaults in place as the fallback.
- **Status:** not fixed; documented as a 12-factor caveat (whitepaper 6.3). The H2 in-memory defaults (`sa`, empty password) are public; do not quote any other.
- **Lesson:** "overridden at runtime" is a weaker claim than "not present". A reviewer applying 12-factor III or PCI 8.6.2 will probe it. Better: blank them at build time and fail closed when the override is missing.

### R06 Re-verification and open results
- HAProxy `status`, `canary` 90/10, `cutover` 0/100, `rollback`: all HTTP 200 (per-request counts not recorded).
- Trivy: 23 CRITICAL / 82 HIGH versus 79 HIGH before; explained in R07.
- Build 26 was re-signed with the new key (not rebuilt), digest unchanged, `cosign verify` exit 0, no tlog line because `--tlog-upload=false`; `docker inspect` on container-app matches the Hiera pin. Verbatim verify text is in whitepaper 6.5.
- NOTES now says build 24 = 000, build 25 = 503, Splunk NOT VERIFIED, and `stage4/splunk` and `stage4/monitoring` stubs exist (empty `.gitkeep`).
- **Lesson:** a changed baseline (+3 HIGH) after a remediation is a finding to explain, not a number to absorb into `.trivyignore`.

### R07 The scan result moved while the artifact did not
- **Symptom:** build 26 scanned as 23 CRITICAL / 82 HIGH (raw), up from 79 HIGH, with no code change. After `--ignore-unfixed` it was 23 / 80; with `.trivyignore` 0 / 0, so the gate passed.
- **Cause:** the Trivy vulnerability database was updated between scans. Three new HIGH findings in `jackson-core`: `CVE-2025-52999` (StackoverflowError, fixed in 2.15.0), `CVE-2026-68494` (async-parser DoS, incomplete fix; fixed in 2.18.8 / 2.21.4), `CVE-2026-89425` (unbounded StringBuilder DoS; fixed in 2.21.7 / 2.22.3 / 2.18.11). The advisory title's "tools.jackson.core" is only the Jackson 3 groupId; the package is 2.x.
- **Related finding:** the image carries two `jackson-core` versions, 2.12.4 and 2.9.6, a duplicate transitive dependency. Earlier notes said "jackson-core 2.13.x" and "fix needs 2.15+"; that was wrong: installed versions are 2.12.4 / 2.9.6 and two of the three fixes need 2.18+. (The wording lives in the older `.trivyignore` header and NOTES; it is not repeated in these docs beyond this correction.)
- **Fix:** none to the image. The three IDs are in `.trivyignore` (lines 120, 130, 131, verified by the coordinator). Commit `892c390` corrected the header ("Jackson 2.13.x / 2.14.x: fix requires 2.15+" became "2.9.6 and 2.12.4 ... 2.15+ (databind) or 2.18.8+ / 2.21.4+ (jackson-core async parser CVEs)") and added a comment per CVE with FixedVersion, Trivy 0.67.0, DB downloaded 2026-10-30 and review-by 2027-01-31. That is the governance the lesson below asks for: scanner version, data date, and an expiry.
- **Unverified claim in that commit:** it attributes the 2.9.6 copy to "spring-test transitive". spring-test is normally test scope and would not ship in a WAR, so the true source of 2.9.6 is **unverified**. Confirm with `mvn dependency:tree -Dincludes=com.fasterxml.jackson.core` (also a refresher exercise).
- **Lessons:**
  1. Scanner binary pinned is not scanner data pinned. Pin the Trivy DB or record its version and date next to each result, otherwise the same digest can pass today and fail tomorrow with no change to explain.
  2. Treat a baseline as risk acceptance with governance: who may add to `.trivyignore`, who approves, a rationale per ID, and an expiry or review date. A growing ignore list without owners is a way of turning the gate off slowly (compare F08).
  3. Fix duplicates at the source: `mvn dependency:tree`, `dependencyManagement` to force one version, and the enforcer plugin's `dependencyConvergence` rule.
  4. Verify the version numbers in your own notes against the artifact before repeating them.

---

## Part 6: Stage 5 observability (R08 to R14)

Sources: commits `afdf6ad`, `11f7a77`, `381af30`, `1d816f1`, the Stage 5 section of `NOTES.md`, and the coordinator's account. Items the sources do not record are marked **not recorded**.

### R08 "Stage 5 fully complete" with work uncommitted and items unreported
- **Symptom:** the agent reported Stage 5 complete while three OpenVox files were uncommitted (`haproxy.cfg`, `petclinic-container.service.erb`, `petclinic-legacy.service.erb`) and gap items A to C were unreported.
- **Cause:** completion was declared from the live hosts' state, not from `git status` against the checklist.
- **Fix:** the files were committed as `11f7a77`; `381af30` added evidence for all seven gap items (A to G).
- **Lesson (by hand):** "done" means committed, reproducible from the repo, and every item answered. Run `git status` and tick the list line by line before saying complete.

### R09 Splunk license misreported as "valid through 2027"
- **Symptom:** a report said the license was valid through 2027. The real expiry is 2026-12-29 17:22:47 UTC (`expiration_time` 1798564967, `splunk list licenses`, 2026-10-30), a 60-day trial (`enttrial.lic`).
- **Cause:** a date was stated without reading it from the product. Where the "2027" claim originated is **not recorded** in the commits.
- **Fix:** NOTES and `381af30` record the epoch and the converted date.
- **Lesson:** convert epoch values yourself, read license state from the tool, and put the expiry in the open-items list.

### R10 A zero-count drill accepted as alert proof
- **Symptom:** `afdf6ad` said the no-events alert was "drilled (service stopped, 0-count confirmed)".
- **Cause:** a search returning zero is a precondition, not proof that the scheduled alert evaluated and triggered. In fact the scheduler had stopped entirely: `Can't persist saved-search history due to the KV-Store either being disabled or failing` (17:33:16) halted all scheduled searches.
- **Fix:** restart with `--run-as-root` once port 8191 was listening; re-drilled with scheduler evidence: 18:25:01Z `status=success result_count=1 condition=1`, again 18:30:01Z, events back by 18:32Z.
- **Lesson:** evidence for an alert is the scheduler or alert-manager record (fire and resolve), not the query result you ran by hand.

### R11 Exit 137 first documented as an LXC limitation
- **Symptom:** a `/dev/shm` write loop inside the LXC did not trigger an OOM kill; the commit recorded "LXC cgroup limitation documented".
- **Cause:** `/dev/shm` pages were not charged the way the test assumed, and a JVM with lazy heap commit simply exits 0 below its limit. The limitation was in the test design, not the platform.
- **Fix:** a throwaway container (`--memory=32m --memory-swap=32m`) running a JVM with `-Xms60m -Xmx60m -XX:+AlwaysPreTouch` gave `OOMKilled=true ExitCode=137`. It was reproduced only in that separate container, not on build 26.
- **Lesson:** do not write "cannot be done here" before trying a different mechanism; force commitment (pre-touch) rather than hoping the allocator touches pages. State where the experiment ran.

### R12 Overlapping drills do not isolate failures
- **Symptom:** the item C drills stopped container-app, then mysqld, then legacy-app, with container-app still down when legacy-app was stopped (`MysqlDown` 18:03:21Z, `JmxExporterDown` 18:04:51Z, `HAProxyAllBackendsDown` 18:05:06Z, all resolved 18:05:41Z).
- **Cause:** one timeline for three alerts; `absent()` over a two-host selector needs both JMX hosts gone, and `HAProxyAllBackendsDown` needs both backends gone.
- **Fix:** the later per-host Splunk drill (R14) changed one thing at a time; the fix pass (R16) re-drilled `HighJvmHeapUsage`, `MysqlExporterDown` and `HighNodeCpu` one by one, with firing and resolved webhook payloads captured.
- **Lesson:** one fault per drill, restore, wait for resolve, then the next; otherwise you show that alerts exist, not that each one detects its own failure.

### R13 (defect s5-defect-1-jmx) Stale module copy on the CT made `--noop` report zero drift
- **Symptom:** `jmx-container` down in Prometheus; `docker port petclinic` showed only 8080; `JAVA_TOOL_OPTIONS` unset; `puppet apply --noop` had said zero drift.
- **Cause:** the module copy on container-app predated `11f7a77` (no `-p 5556:5556`, `JAVA_TOOL_OPTIONS` or `/opt/jmx` mount). `--noop` compared the stale template to the already-deployed stale unit, a false zero. JMX on 731 went down after a drill restart.
- **Fix:** committed template written to the CT; real `puppet apply`; unit sha256 `9d957b0a` to `bca0909c`; 5556 published; `jmx-container` and `jmx-legacy` up; digest `f1a2edae` unchanged.
- **Lesson:** `--noop` proves nothing unless the CT runs the committed tree. Compare file hashes against git. Repo-to-CT sync remains manual and is an open item (r10k or `git pull` on the CT).

### R14 (defect s5-defect-2-perhost) A global zero-count search could not see one silent host
- **Symptom:** `lab_no_app_events` (`stats count | where count=0`) fired only when every host was silent; it took stopping both UFs.
- **Cause:** aggregation before the filter; a healthy host hides a dead one. Two more faults: the saved search ran as owner `nobody`, which lacked `tstats` index permissions (a replacement returned 0 rows), and a stale `etc/users/admin/search/local/savedsearches.conf` overrode REST API updates until deleted and Splunk restarted.
- **Fix:** replaced with a per-host `tstats latest(_time)` staleness check (`seconds_silent > 300`), owner `admin` via `metadata/local.meta`, Splunk restarted. Drill: container-app UF stopped 18:38:54Z; scheduler 19:15:00Z `user=admin result_count=1` (`container-app SILENT 36.5min`, `legacy-app` 1 s, healthy); UF restarted 19:15:35Z; scheduler 19:20:00Z `result_count=0`. The alert fired for 731 alone.
- **Lesson:** design the detector for the failure you care about (one host), check who the search runs as, and look for local config that silently overrides your API writes.

### Other Stage 5 notes
- **Splunk first-boot circular dependency:** `defaultKVStoreType = cohosted` (PostgreSQL) needs an admin user that cannot be created until the KV store runs; fix `defaultKVStoreType = local` before first start. By hand: diagnose in `sup-pkg-kvstore-pdl.log`.
- **Commit message vs NOTES:** `afdf6ad` says the test owner row is `id=12`; NOTES and `381af30` say 12 rows, id 13. Use id 13.
- **Image label:** the commit names `eclipse-temurin:21-jre-alpine` for the container-app JVM experiments, while build 26 uses a `jre-noble` base; the image actually used is **not recorded**.
- **Open items:** automate repo-to-CT sync; give the Splunk alert explicit `counttype`/`relation`/`quantity` and `alert_actions` and show a `fired_alerts` record (it currently relies on defaults, tracking only); Splunk trial expires 2026-12-29; external alert receiver (email/chat/pager, needs credentials and a go-ahead); re-drill heap and CPU alerts with real pressure; earlier open items carry forward. (Closed in the fix pass: webhook receiver, log-indexer scrape target, retention, sizing, three drills.)

---

## Part 7: Stage 5 fix pass (R15, R16)

Sources: commits `18b8148` and `03f50c2`, `NOTES.md`, and the coordinator's verified facts. The fix pass also closed these earlier gaps: Alertmanager's no-op `log-only` receiver is replaced by `webhook-sink` (`send_resolved: true`; sink container pinned `python:3.12-alpine`, port 5001, appends to `/data/webhooks.jsonl`, LAN-only); log-indexer node_exporter 1.8.2 (sha256 `0c9219b9...ba1d`, same as 730 to 734) brings Prometheus to 11 of 11 targets, retention 15 days; the three undrilled alerts were drilled. After the drills container-app is still on `f1a2edae` and `/petclinic/owners/13` via HAProxy returns 200.

### R15 log-indexer sizing misrecorded in NOTES (4 GB / 32 GB vs 6144 MB / 40 GB)
- **Symptom:** NOTES, and this paper's table, said log-indexer had 4 GB RAM and 32 GB disk. `pct config` and in-CT `free -m` / `df -h` show 6144 MB, 40 GB, 2 cores.
- **Cause:** not recorded; `03f50c2` says the correct values were measured with `free -m` and `df -h`, so the earlier figures were not. The same kind of mistake happened earlier with the legacy-app to 733 inventory (F16).
- **Fix:** `03f50c2` corrected NOTES from measured values and added monitor detail (2048 MB / 20 GB, Prometheus retention 15d, webhook sink). The whitepaper table was corrected to match.
- **Lesson (by hand):** capacity numbers come from the system of record (`pct config`, `free -m`, `df -h`) at the time of writing, with the command alongside. If you write what you intended, label it "planned".

### R16 Threshold-lowering drills prove routing, not detection
- **Symptom:** `HighJvmHeapUsage` was drilled with a throwaway rule at `> 0.001` (real: heap used/max `> 0.80` for 2m), induced 19:32:43Z, firing 19:35:19Z, resolved 19:40:19Z. `HighNodeCpu` used a throwaway rule at `> 25`, induced 19:51:22Z, firing 19:55:03Z, resolved 20:00:03Z; no CPU burn was run and it fired on baseline load (monitor about 30%, log-indexer about 59%). `MysqlExporterDown` was real: `mysqld_exporter` stopped on db at 19:42:05Z, firing 19:43:36Z, resolved 19:48:36Z after restore at 19:43:53Z.
- **Cause (inferred, not recorded):** inducing real heap pressure or CPU load takes effort and risks the lab, so a lowered threshold was used.
- **What it proves:** that the rule evaluates, Alertmanager groups it and the receiver gets firing and resolved payloads. It does not prove the production threshold would ever fire on real pressure, nor that the metric moves under load.
- **Timing finding:** resolved notices arrived about five minutes after restore: `send_resolved: true` does not bypass `group_interval` (5m). Budget for that when reasoning about "time to resolved".
- **Residual:** an earlier firing POST at 19:30:48Z has no `alertname`, probably a sink test (not recorded).
- **Lesson (by hand):** label each drill "real fault" or "synthetic threshold" in the evidence, and keep one fault per drill. For the production claim, fill the heap or burn CPU once (or compute the margin between baseline and the real threshold) and show the real rule firing. Remove throwaway rules afterwards; the loaded rules are now the six real ones.

_Last reviewed: 2026-10-30_
