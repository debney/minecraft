#!/usr/bin/env bash
# Reset the Minecraft world: (optional) snapshot -> wipe -> regenerate a fresh
# world -> re-apply game rules. Run on the server as root:
#
#   sudo /opt/bedrock/reset-world.sh              # takes an S3 snapshot first
#   sudo /opt/bedrock/reset-world.sh --no-backup  # skip the snapshot
#
set -euo pipefail

# --- Config (matches the Terraform setup in variables.tf) ---
CONTAINER="bedrock"
WORLD_DIR="/opt/bedrock/worlds"
WORLD_NAME="SurvivalWorld"
REGION="ap-southeast-2"
BUCKET="minecraft-debney-backups"
# Game rules re-applied to the fresh world (keep in sync with variables.tf).
KEEP_INVENTORY="false"
SLEEP_PERCENTAGE="0"

BACKUP=1
for arg in "$@"; do
  case "$arg" in
    --no-backup|--skip-backup) BACKUP=0 ;;
    -h|--help) grep '^#' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo." >&2
  exit 1
fi

echo "==> Minecraft world reset starting"

if [[ $BACKUP -eq 1 ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  DEST="s3://$BUCKET/snapshots/$TS"
  echo "==> Backing up current world to $DEST"
  aws s3 sync "$WORLD_DIR" "$DEST" --region "$REGION"
  echo "==> Snapshot saved: $DEST"
else
  echo "==> Skipping backup (--no-backup)"
fi

echo "==> Stopping server"
docker stop "$CONTAINER"

echo "==> Deleting world '$WORLD_NAME'"
# The :? guards make the rm abort rather than ever expand to a bare '/'.
rm -rf "${WORLD_DIR:?}/${WORLD_NAME:?}"

echo "==> Starting server (a fresh world is generated on boot)"
docker start "$CONTAINER"

echo "==> Waiting for the world to load, then applying game rules"
sleep 15
applied=0
for _ in $(seq 1 30); do
  if docker exec "$CONTAINER" send-command gamerule keepInventory "$KEEP_INVENTORY" \
     && docker exec "$CONTAINER" send-command gamerule playerssleepingpercentage "$SLEEP_PERCENTAGE"; then
    applied=1
    break
  fi
  sleep 10
done

if [[ $applied -eq 1 ]]; then
  echo "==> Game rules applied: keepInventory=$KEEP_INVENTORY, playerssleepingpercentage=$SLEEP_PERCENTAGE"
else
  echo "!! Could not apply game rules automatically. Once the server is up, run:" >&2
  echo "   sudo docker exec $CONTAINER send-command gamerule keepInventory $KEEP_INVENTORY" >&2
  echo "   sudo docker exec $CONTAINER send-command gamerule playerssleepingpercentage $SLEEP_PERCENTAGE" >&2
fi

echo "==> Done. Fresh world '$WORLD_NAME' is live. Recent log:"
docker logs --tail 8 "$CONTAINER" || true
