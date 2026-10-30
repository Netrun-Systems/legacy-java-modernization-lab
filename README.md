# legacy-java-modernization-lab

A five-stage hands-on lab that walks through modernizing a legacy Java web
application running on bare-metal Jetty into a fully containerized, monitored,
and continuously delivered service — all on a self-hosted Proxmox hypervisor.

The workload is **Spring PetClinic** (a well-known open-source demo app, javax
WAR compiled for Jetty 9.4), migrated to Jetty 12 EE8 and then containerized.
No proprietary code is included.

## Architecture

```
  ┌─────────────────────────────────────────────────────────┐
  │  WORKSTATION (docker compose)                           │
  │  ┌──────────────┐  ┌──────────┐  ┌──────────────────┐  │
  │  │  Jenkins CI  │  │  DinD    │  │  Registry :5000  │  │
  │  └──────────────┘  └──────────┘  └──────────────────┘  │
  └───────────────────────────────────────────────────────┬─┘
                                                          │ LAN
  ┌───────────────────────────────────────────────────────┼─┐
  │  HYPERVISOR HOST hypervisor.lab.example               │  │
  │  (Proxmox; also the NAT gateway for the lab CTs)      │  │
  │                                                       │  │
  │  ┌────────────────────────────────────────────────┐   │  │
  │  │  LAN  10.0.lab.0/24 (example; use your subnet) │   │  │
  │  │                                                │   │  │
  │  │  legacy-app     (CT_LEGACY)    Jetty 9.4 WAR   │   │  │
  │  │  container-app  (CT_CONTAINER) Docker / Jetty  │   │  │
  │  │  lb             (CT_LB)        HAProxy canary  │   │  │
  │  │  db             (CT_DB)        MySQL 8          │   │  │
  │  │  monitor        (CT_MONITOR)   Prom+Graf+AM     │   │  │
  │  │  log-indexer    (CT_LOG)       Splunk Enterprise│   │  │
  │  └────────────────────────────────────────────────┘   │  │
  └───────────────────────────────────────────────────────┘  │
```

## Stages

| Stage | What it covers |
|-------|----------------|
| **1 — Legacy baseline** | Spring PetClinic WAR on bare Jetty 9.4; MySQL 8; OpenVox (Puppet) configuration management; cosign image signing baseline |
| **2 — Container migration** | Jetty 9.4 → 12 EE8 migration; WAR containerized with Eclipse Temurin; image signed with cosign; Trivy SBOM gating |
| **3 — CI/CD** | Jenkins with JCasC; Docker-in-Docker; automated build → sign → push → verify pipeline |
| **4 — Canary routing** | HAProxy weighted round-robin; `flip-weights.sh` for incremental traffic shift; blue/green rollback path |
| **5 — Observability** | Prometheus + Alertmanager + Grafana; JMX exporter (legacy + container Jetty); mysqld_exporter; node_exporter; Splunk log indexing; webhook alert sink |

Detailed notes on what was built, what broke, and what was learned are in
[NOTES.md](NOTES.md). A technical deep-dive is in
[docs/WHITEPAPER.md](docs/WHITEPAPER.md).

## Prerequisites

- A Proxmox hypervisor with six available CT slots
- A workstation on the same LAN that can run Docker (compose v2)
- Splunk Enterprise license (free tier covers ≤ 500 MB/day)
- cosign ≥ 2.4 (`brew install cosign` or `apt install cosign`)
- Trivy — any version **except 0.69.4, 0.69.5, and 0.69.6** (supply-chain
  compromise; see [Trivy security advisory](https://github.com/aquasecurity/trivy/security/advisories))

## Quick start

### 1. Configure environment

```bash
cp .env.example .env
# Edit .env: set real IPs, CT IDs, registry host, and passwords
```

### 2. Provision lab containers (Proxmox)

```bash
# Review scripts/proxmox-example/lxc-setup.sh — set env vars to match your
# hypervisor, then run it on the hypervisor host:
source .env
bash scripts/proxmox-example/lxc-setup.sh
```

### 3. Stage 1 — legacy baseline

```bash
# On legacy-app: provision Jetty 9 + JDK + PetClinic WAR
bash stage4/scripts/provision-legacy.sh

# On db: provision MySQL 8 (then configure datasource via OpenVox)
# See stage4/openvox/ for the Puppet manifests
bash stage4/openvox/site.pp   # apply via OpenVox agent on each CT
```

### 4. Stage 2 — containerize

```bash
# On workstation: explore the Jetty 9→12 EE8 migration
bash phase1/phase1-jetty12-ee8.sh

# Build and sign the container image
cd stage2
docker build -t ${REGISTRY_HOST}/petclinic:latest .
cosign sign --key cosign.key ${REGISTRY_HOST}/petclinic:latest
```

### 5. Stage 3 — CI/CD

```bash
# Start Jenkins + registry + DinD on the workstation
docker compose up -d
# Jenkins UI: http://workstation.lan.example:8080
```

### 6. Stage 4 — canary routing

```bash
# On lb (HAProxy CT): set initial weights (100% legacy)
bash scripts/flip-weights.sh rollback
# Shift traffic gradually (canary = 90/10, cutover = 0/100)
bash scripts/flip-weights.sh canary
bash scripts/flip-weights.sh cutover
# Emergency rollback
bash scripts/flip-weights.sh rollback
```

### 7. Stage 5 — observability

```bash
cd stage4/monitoring
docker compose up -d   # runs on monitor CT
# Prometheus: http://monitor.lab.example:9090
# Grafana:    http://monitor.lab.example:3000
```

## Key files

| File | Purpose |
|------|---------|
| `NOTES.md` | Build log — decisions, failures, and lessons per stage |
| `docs/WHITEPAPER.md` | Technical deep-dive (Jetty EE model, WAR migration, canary math) |
| `docs/RETROSPECTIVE.md` | Post-build retrospective: what worked, what did not, what to improve |
| `docs/REFRESHER_OUTLINE.md` | Condensed reference covering all five stages |
| `docker-compose.yml` | Workstation CI stack (Jenkins, DinD, registry) |
| `stage4/monitoring/docker-compose.yml` | Monitor CT stack (Prometheus, Grafana, Alertmanager, webhook sink) |
| `stage3/jenkins/casc.yaml` | Jenkins Configuration-as-Code |
| `stage4/haproxy/haproxy.cfg` | HAProxy canary config |
| `scripts/verify.sh` | End-to-end smoke test (all six CTs) |
| `scripts/flip-weights.sh` | HAProxy weight shift via admin socket over SSH |
| `.env.example` | Environment variable shape reference |
| `scripts/proxmox-example/` | Proxmox LXC provisioning scripts (not tested on non-Proxmox) |

## Security notes

- `cosign.key` is **never committed**; only `keys/cosign.pub` is in the repo.
- `.env` is git-ignored; `.env.example` has variable names only.
- Splunk admin password lives in a gitignored `admin_password.txt` on the log
  indexer CT and is never printed to the console.
- Splunk Web is bound to the LAN interface only (no public exposure).
- Trivy gates are enforced in the Jenkins pipeline; images with unfixed CRITICAL
  CVEs do not reach the registry.

## Limits and honest caveats

- This is a **lab**, not a production blueprint. The Proxmox scripts assume a
  flat LAN with NAT; no VLANs, no mTLS between services.
- Splunk requires a separate license; the free tier is sufficient for the lab
  but not for production log volumes.
- HAProxy state is managed manually via `flip-weights.sh`; a real deployment
  would use a CD tool (ArgoCD, Spinnaker, etc.).
- OpenVox (Puppet fork) is used for configuration management; its API is
  compatible with Puppet 7 but community support is smaller.
- Alertmanager receivers use `webhook_configs` only — no email or Slack is
  wired up, keeping the lab LAN-only.

## License

MIT — see [LICENSE](LICENSE).
