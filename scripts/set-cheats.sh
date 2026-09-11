#!/usr/bin/env bash
# Enable or disable cheats (server.properties allow-cheats) on the CURRENT world
# without wiping it. Because allow-cheats is set via the container's ALLOW_CHEATS
# env var, this recreates the container (preserving its other settings); the
# world data on the mounted volume is left untouched.
#
#   sudo /opt/bedrock/set-cheats.sh off
#   sudo /opt/bedrock/set-cheats.sh on
#
# Note: with cheats off, on-screen coordinates (the showcoordinates rule) will
# not display, and players cannot run commands. Existing game rules already set
# in the world (e.g. keepInventory) are preserved but can no longer be changed.
#
set -euo pipefail

CONTAINER="bedrock"
IMAGE="itzg/minecraft-bedrock-server:latest"

case "${1:-}" in
  on|ON|true)    CHEATS=true ;;
  off|OFF|false) CHEATS=false ;;
  *) echo "Usage: $0 on|off" >&2; exit 2 ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo." >&2
  exit 1
fi

echo "==> Setting allow-cheats=$CHEATS (recreating container; world preserved)"
# Preserve the container's existing env (drop PATH, which the image sets itself,
# and any prior ALLOW_CHEATS so ours wins).
mapfile -t EXISTING_ENV < <(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" | grep '=' | grep -vE '^(PATH=|ALLOW_CHEATS=)')

docker stop "$CONTAINER"
docker rm "$CONTAINER"

ENV_ARGS=()
for e in "${EXISTING_ENV[@]}"; do ENV_ARGS+=(-e "$e"); done

docker run -d -it --cap-add=SYS_PTRACE --name="$CONTAINER" \
  -p 19132:19132/udp \
  -v /opt/bedrock:/data \
  --restart=always \
  "${ENV_ARGS[@]}" \
  -e ALLOW_CHEATS="$CHEATS" \
  "$IMAGE"

echo "==> Done. allow-cheats=$CHEATS. Waiting for server, then recent log:"
sleep 12
docker logs --tail 10 "$CONTAINER" || true
