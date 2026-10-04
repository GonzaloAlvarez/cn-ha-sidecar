# cn-ha-sidecar

Tailscale sidecar stack for Home Assistant (supervised mode). Connects HA
to the CloudNet tailnet via Headscale and provides:

- **Tailnet access**: `https://ha.<LAB_DOMAIN>` with Let's Encrypt TLS (via traefik-lab on VPS)
- **LAN access**: `https://homeassistant.lan` with TLS from step-ca (ACME)
- **Service discovery**: Consul registration for automatic traefik-lab routing
- **Logging**: Promtail ships HA container logs to Loki on VPS
- **Updates**: nightly `systemd/cn-ha-sidecar-update.timer` runs `update.sh` (pull + recreate + prune). No Watchtower on this host: `containrrr/watchtower` is on the HA Supervisor's unhealthy-image list, and its presence blocks `ha core update` and add-on updates

## Prerequisites

- Home Assistant running in supervised mode on Debian
- Docker 20.10+ on the HA host
- CloudNet VPS stack running (cn-root-docker)
- cn-pki running (for LAN TLS certificates)

## Setup

### 1. Create a Headscale pre-auth key (on VPS)

```bash
docker exec cloudnet-headscale-1 headscale preauthkeys create --user 1 --tags tag:svc --reusable --expiration 1h
```

Copy the key — you'll need it for `HA_AUTHKEY` below.

### 2. Run the setup script (on HA host)

```bash
git clone <repo-url> cn-ha-sidecar
cd cn-ha-sidecar
./setup.sh            # production mode
# or
./setup.sh staging    # staging mode (Let's Encrypt staging certs)
```

The script will prompt for all required environment variables and generate
config files from templates.

### 3. Configure Home Assistant trusted proxies (in the HA UI)

Both Traefiks forward to HA with `X-Forwarded-For`, so HA must trust them or it
answers every proxied request with `400 Bad Request`. Since Home Assistant
2026.9 the `http` integration is configured from the UI, not YAML: open
**Settings -> System -> Network**, enable *Use X-Forwarded-For* and add the
trusted proxies:

| Proxy | Source address seen by HA |
|---|---|
| `traefik-lan` (host network) | `127.0.0.1/32`, `::1/128` |
| `traefik-tailnet` (Docker default bridge, via `host.docker.internal`) | `172.17.0.1/32` |
| compose project network (fallback) | `172.18.0.0/24` |

Verify the bridge addresses before trusting them:

```bash
docker network inspect bridge | grep -E 'Subnet|Gateway'
docker network inspect cn-ha-sidecar_default | grep Subnet
```

HA stores the result in `.storage/http`. A legacy `http:` block in
`configuration.yaml` is imported once on upgrade and then raises the repair
*"The HTTP YAML configuration is deprecated"* (removed in 2027.2); clear it by
deleting the block and restarting core (`ha core check && ha core restart`).
The live host was converted this way on 2026-10-04 and `configuration.yaml`
no longer carries an `http:` block.

### 4. Start the sidecar stack (on HA host)

```bash
docker compose up -d
```

### 5. Verify

```bash
# Check Tailscale joined the tailnet
docker compose logs ts-ha

# Check Consul registration
docker compose logs consul-register

# On VPS — verify the node
docker exec cloudnet-headscale-1 headscale nodes list

# On VPS — verify Consul service
curl -s http://<VPS_TAILNET_IP>:8500/v1/catalog/service/homeassistant | jq .
```

Then open `https://ha.<LAB_DOMAIN>` from any tailnet device. You should see
the HA login page with a valid Let's Encrypt certificate. Verify the dashboard
loads fully and updates in real-time (WebSocket).

For LAN access, open `https://homeassistant.lan` (traefik-lan requests a cert
from step-ca via ACME automatically; requires DNS resolution for `homeassistant.lan`
on your router and `PKI_IP` set in `.env`).

## Optional: HA Metrics in Grafana

HA can export Prometheus metrics for scraping by the VPS Prometheus instance.

1. Add `prometheus:` to HA's `configuration.yaml` and restart HA
2. Create a long-lived access token in HA (Profile -> Long-Lived Access Tokens)
3. Add a scrape job to `cn-root-docker/tailnet/prometheus/prometheus.yml`:

```yaml
  - job_name: homeassistant
    metrics_path: /api/prometheus
    bearer_token: "<HA_LONG_LIVED_ACCESS_TOKEN>"
    scrape_interval: 30s
    static_configs:
      - targets: ["ha.<TAILNET_DOMAIN>:8080"]
```

4. Restart Prometheus: `docker compose restart prometheus` (on VPS)
5. Query `homeassistant_entity_*` in Grafana Explore

## Disk maintenance

The 14 GB root filesystem fills up over time — mainly `/var/cache/apt`
(apt's daily pre-download of upgradable packages that unattended-upgrades
never installs) and the journal. `scripts/disk-maintenance.sh` cleans both
plus dangling docker images; run once with `--install` to disable the apt
pre-download and add a weekly cron (`/etc/cron.d/cn-ha-sidecar-disk-maintenance`,
Sundays 04:15):

```sh
sudo ./scripts/disk-maintenance.sh --install
```

Each pass logs `maintenance pass done: / N% -> M%` to syslog (tag
`disk-maintenance`), which promtail ships to Loki. The corresponding alerts
are `HomeIoTDiskSpaceLow` (>80%) / `HomeIoTDiskSpaceCritical` (>95%) in
`cn-root-docker/tailnet/prometheus/alerts.yml`.

## Troubleshooting

- **`host.docker.internal` not resolving**: Replace with the literal Docker
  bridge gateway IP (e.g., `172.17.0.1`) in `traefik-tailnet/dynamic.yml`
- **HA shows "Disconnected" after login via tailnet**: WebSocket issue — check
  that traefik-tailnet is running: `docker compose logs traefik-tailnet`
- **Consul registration failing**: Check that the VPS tailnet IP is correct
  and ACLs allow `tag:svc -> tag:infra:8500`
- **LAN cert not working**: Ensure cn-pki step-ca is reachable at `https://${PKI_IP}:9000`
  and `certs/root_ca.crt` exists. Check: `docker compose logs traefik-lan`
