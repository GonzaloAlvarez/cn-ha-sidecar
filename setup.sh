#!/bin/bash
set -e

MODE="${1:-production}"

set_env_var() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

if [ ! -f .env ]; then
  > .env
  while IFS= read -r line; do
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# || ! "$line" =~ = ]]; then
      echo "$line" >> .env
      continue
    fi
    varname="${line%%=*}"
    default="${line#*=}"
    if [[ "$varname" == *PASSWORD* || "$varname" == *TOKEN* || "$varname" == *SECRET* || "$varname" == *AUTHKEY* || "$varname" == *API_KEY* ]]; then
      read -rsp "${varname}: " value
      echo
      echo "${varname}=${value}" >> .env
    elif [[ -n "$default" ]]; then
      read -r -p "${varname} [${default}]: " value
      echo "${varname}=${value:-$default}" >> .env
    else
      read -r -p "${varname}: " value
      echo "${varname}=${value}" >> .env
    fi
  done < .env.example
  echo ""
fi

set -o allexport
source .env
set +o allexport

mkdir -p certs traefik-lan tailnet/promtail

if [ "$MODE" = "staging" ]; then
  echo "Configuring staging ACME..."
  curl -sf -o certs/letsencrypt-stg-root-x1.pem \
    https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem
  curl -sf -o certs/letsencrypt-stg-root-x2.pem \
    https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x2.pem
  set_env_var SSL_CERT_DIR "/etc/ssl/certs:/staging-certs"
  echo "Done. To apply:"
  echo "  docker compose down && docker compose up -d"
else
  echo "Configuring production ACME..."
  rm -f certs/letsencrypt-stg-root-*.pem
  set_env_var SSL_CERT_DIR "/etc/ssl/certs"
  echo "Done. To apply:"
  echo "  docker compose down && docker compose up -d"
fi

if [ ! -f certs/lan.crt ]; then
  echo "NOTE: certs/lan.crt not found."
  echo "Certificates are managed by Cert Warden (cn-pki)."
  echo "Once cn-pki is running and a cert is issued, certwarden-client will write certs/lan.crt automatically."
fi

envsubst '${LAN_DOMAIN}' \
  < traefik-lan/dynamic.yml.tmpl > traefik-lan/dynamic.yml

envsubst '${CERTWARDEN_API_KEY}' \
  < certwarden-client.yaml.tmpl > certwarden-client.yaml

envsubst '${INFRA_VPS_TAILNET_IP}' \
  < tailnet/promtail/promtail.yml.tmpl > tailnet/promtail/promtail.yml
