# Proxmox LXC Example Runbook

These scripts are an **example runbook** for creating and destroying the lab's
LXC containers on a Proxmox VE host. They are written for Proxmox `pct` and
assume Ubuntu 24.04 LXC templates.

**To use on a different hypervisor**, port the equivalent container/VM creation
commands for your platform (libvirt, ESXi, Hyper-V, etc.).

## Scripts

| Script | Purpose |
|--------|---------|
| `lxc-setup.sh` | Create the six lab containers |
| `lxc-teardown.sh` | Destroy all lab containers |

## Required environment

- A Proxmox VE host reachable by SSH from your workstation
- Ubuntu 24.04 LXC template available on the hypervisor host's local storage
- `HYPERVISOR_HOST` set to the Proxmox host's SSH address (e.g. `root@hypervisor.lab.example`)

## Customization

Before running, edit the following variables at the top of each script:

- `HYPERVISOR_HOST` — SSH address of your Proxmox host
- CT IDs and IP addresses — match your LAN subnet
- `STORAGE` — Proxmox storage pool name
- `TEMPLATE` — path to the Ubuntu 24.04 LXC template

## Container layout

| Role | Hostname | Purpose |
|------|----------|---------|
| legacy-app | legacy-app | Jetty 9.4 legacy app host |
| container-app | container-app | Jetty 12 container-app host + Docker |
| lb | lb | HAProxy 2.x load balancer |
| db | db | MySQL 8.x database |
| monitor | monitor | Prometheus + Alertmanager + Grafana |
| log-indexer | log-indexer | Splunk Enterprise log indexing |
