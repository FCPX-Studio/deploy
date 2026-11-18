#!/usr/bin/env bash
# Create an MQTT account or change its password (prompted twice), or delete one, then reload Mosquitto.
#
#   mosquitto/passwd.sh esp32
#   mosquitto/passwd.sh paddlesync        # services: dataapi, eventapi, authapi, paddlesync
#   mosquitto/passwd.sh -D olduser        # delete an account
#
# Writes mosquitto/secrets/passwd: hashed passwords only, the clear one is never stored (keep it in a
# password manager). Run on the VPS, from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  "" | -h | --help) sed -n '2,9p' "$0"; exit 1 ;;
  -D) [[ -n "${2:-}" ]] || { echo "usage: $0 -D <user>"; exit 1; }; action=delete; user=$2 ;;
  *) action=set; user=$1 ;;
esac
mkdir -p mosquitto/secrets

# mosquitto_passwd from the Mosquitto image, as root; the file is then owned by its mosquitto user (uid 1883)
docker compose run --rm --no-deps -v "$PWD/mosquitto/secrets:/secrets" --entrypoint sh mosquitto -c '
  set -e
  [ -f /secrets/passwd ] || touch /secrets/passwd
  chmod 600 /secrets/passwd
  if [ "$1" = delete ]; then mosquitto_passwd -D /secrets/passwd "$2"; else mosquitto_passwd /secrets/passwd "$2"; fi
  chown 1883:1883 /secrets/passwd
' sh "$action" "$user"

# Reload the accounts without dropping connected clients (no-op if Mosquitto isn't running yet)
docker compose kill -s SIGHUP mosquitto >/dev/null 2>&1 || true

if [[ $action == set && $user != esp32 ]]; then
  echo "Done. Put MQTT_USERNAME=$user and its password in env/<service>.env, then: docker compose up -d <service>"
else
  echo "Done."
fi
