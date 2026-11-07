#!/usr/bin/env bash
# Pin the Bedrock server to a specific version (or LATEST) WITHOUT wiping the
# world. Because the version is set via the container's VERSION env var, this
# recreates the container (preserving its other settings); the world data on the
# mounted volume is left untouched.
#
#   sudo /opt/bedrock/set-version.sh 1.26.60.6
#   sudo /opt/bedrock/set-version.sh LATEST
#
# Bedrock requires the server and client to be on matching versions. If players
# get "InitialConnection-149", the server is AHEAD of their app: pin it to the
# version their Minecraft title screen shows. Client "26.60" -> use 1.26.60.6
# (the matching server build; the newer 1.26.61.1 breaks 26.60 clients).
#
set -euo pipefail

CONTAINER="bedrock"
IMAGE="itzg/minecraft-bedrock-server:latest"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version|LATEST>   e.g. $0 1.26.60.6" >&2
  exit 2
fi
if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo." >&2
  exit 1
fi

echo "==> Pinning Bedrock server to VERSION=$VERSION (recreating container; world preserved)"
# Preserve the container's existing env (drop PATH, which the image sets itself,
# and any prior VERSION so ours wins).
mapfile -t EXISTING_ENV < <(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" | grep '=' | grep -vE '^(PATH=|VERSION=)')

docker stop "$CONTAINER"
docker rm "$CONTAINER"

ENV_ARGS=()
for e in "${EXISTING_ENV[@]}"; do ENV_ARGS+=(-e "$e"); done

docker run -d -it --cap-add=SYS_PTRACE --name="$CONTAINER" \
  -p 19132:19132/udp \
  -v /opt/bedrock:/data \
  --restart=always \
  "${ENV_ARGS[@]}" \
  -e VERSION="$VERSION" \
  "$IMAGE"

echo "==> Done. Waiting for download + start, then recent log:"
sleep 20
docker logs --tail 20 "$CONTAINER" 2>&1 | grep -iE "version|opening level|server started" | tail -10 || true
