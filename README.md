# cn-ha-sidecar

Tailscale sidecar stack for Home Assistant (supervised mode). Connects HA
to the CloudNet tailnet via Headscale and provides:

- **Tailnet access**: `https://ha.<LAB_DOMAIN>` with Let's Encrypt TLS (via traefik-lab on VPS)
- **LAN access**: `https://homeassistant.lan` with certwarden TLS
- **Service discovery**: Consul registration for automatic traefik-lab routing
- **Logging**: Promtail ships HA container logs to Loki on VPS
- **Monitoring**: Watchtower monitors container image updates

## Prerequisites

- Home Assistant running in supervised mode on Debian
- Docker 20.10+ on the HA host
- CloudNet VPS stack running (cn-root-docker)
- cn-pki running (for LAN TLS certificates)

## Setup

### 1. Create a Headscale pre-auth key (on VPS)

```bash
docker exec cloudnet-headscale-1 headscale preauthkeys create \
  --user 1 --tags tag:svc --reusable --expiration 1h
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

### 3. Configure Home Assistant trusted proxies (on HA host)

Edit the HA configuration file (usually `/usr/share/hassio/homeassistant/configuration.yaml`):

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.17.0.0/16    # Docker default bridge (traefik-tailnet -> HA)
    - 172.18.0.0/16    # Docker compose network (fallback)
    - 127.0.0.1/32     # traefik-lan (host network, localhost)
```

Verify your Docker bridge subnet:

```bash
docker network inspect bridge | grep Subnet
```

Restart HA (Settings -> System -> Restart, or `ha core restart`).

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

For LAN access, open `https://homeassistant.lan` (requires certwarden cert
to be issued by cn-pki and DNS resolution for `homeassistant.lan` on your router).

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

## Troubleshooting

- **`host.docker.internal` not resolving**: Replace with the literal Docker
  bridge gateway IP (e.g., `172.17.0.1`) in `traefik-tailnet/dynamic.yml`
- **HA shows "Disconnected" after login via tailnet**: WebSocket issue — check
  that traefik-tailnet is running: `docker compose logs traefik-tailnet`
- **Consul registration failing**: Check that the VPS tailnet IP is correct
  and ACLs allow `tag:svc -> tag:infra:8500`
- **LAN cert not working**: Ensure cn-pki is running and has issued a cert
  for `homeassistant.lan`. Check: `docker compose logs certwarden-client`
