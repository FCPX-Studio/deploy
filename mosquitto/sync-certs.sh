#!/usr/bin/env bash
# Copy Caddy's certificate of mqtt.<SITE_ADDRESS> to Mosquitto, and restart Mosquitto when it changed.
# Caddy renews it about every 60 days: run this daily from cron (see the README), and once by hand
# after the first deploy. A no-op when the certificate didn't change.
set -euo pipefail
cd "$(dirname "$0")/.."

site=$(sed -n 's/^SITE_ADDRESS=//p' .env | tr -d '"'"'" | tail -1)
[[ -n "$site" ]] || { echo "SITE_ADDRESS is not set in .env"; exit 1; }
domain="mqtt.$site"
dest=mosquitto/secrets
mkdir -p "$dest"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Let's Encrypt first, ZeroSSL is Caddy's fallback issuer
for issuer in acme-v02.api.letsencrypt.org-directory acme.zerossl.com-v2-dv90; do
  src="/data/caddy/certificates/$issuer/$domain"
  if docker compose exec -T caddy test -f "$src/$domain.crt"; then
    docker compose cp "caddy:$src/$domain.crt" "$tmp/cert.pem" >/dev/null
    docker compose cp "caddy:$src/$domain.key" "$tmp/key.pem" >/dev/null
    break
  fi
done
[[ -f "$tmp/cert.pem" ]] || { echo "Caddy has no certificate for $domain yet (DNS record? see docker compose logs caddy)"; exit 1; }

# The key is only readable by Mosquitto's user, so compare a checksum kept next to it
sum=$(sha256sum "$tmp/cert.pem" "$tmp/key.pem" | cut -d' ' -f1 | tr -d '\n')
if [[ -f "$dest/cert.sha256" && "$(cat "$dest/cert.sha256")" == "$sum" ]]; then
  exit 0
fi

# Installed as root in the Mosquitto image, owned by its mosquitto user (uid 1883)
docker compose run --rm --no-deps -T -v "$PWD/$dest:/secrets" -v "$tmp:/new:ro" --entrypoint sh mosquitto -c '
  set -e
  install -o 1883 -g 1883 -m 644 /new/cert.pem /secrets/cert.pem
  install -o 1883 -g 1883 -m 600 /new/key.pem /secrets/key.pem
'
echo "$sum" > "$dest/cert.sha256"

# A full restart loads the new certificate; the ESP32 and the services reconnect on their own
docker compose up -d mosquitto >/dev/null
docker compose restart mosquitto >/dev/null
echo "Installed the certificate of $domain, Mosquitto restarted"
