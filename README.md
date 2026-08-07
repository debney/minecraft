# Minecraft Bedrock on AWS (Terraform)

## Quick Restore (One-Liner)

If you ever rebuild or lose the server, run this inside the EC2 instance to restore your world:

```bash
aws s3 sync s3://minecraft-debney-backups/worlds /opt/bedrock/worlds && docker restart bedrock
```

---

## Overview

This project deploys a **Minecraft Bedrock server** on AWS using Terraform.  

It sets up:
- An EC2 instance running `itzg/minecraft-bedrock-server` in Docker  
- An Elastic IP for a stable address  
- A security group allowing UDP 19132 (Bedrock)  
- Automatic **hourly backups** of world data to S3  
- DNS mapping so players can connect via `minecraft.debney.net`  
- Gameplay tuned through Terraform variables (game rules like keepInventory
  and one-player sleep)  

---

## Prerequisites

- Terraform >= 1.6  
- AWS account with CLI credentials configured  
- Domain `minecraft.debney.net` (DNS managed in Squarespace, pointing to Elastic IP)  

---

## Deploy the server

```bash
terraform init
terraform apply
```

Terraform will:
- Launch an EC2 instance  
- Attach an Elastic IP  
- Install Docker and run the Bedrock server  
- Set up hourly S3 backups  

When complete, outputs will include:

```
server_ip     = "X.X.X.X"
connect_hint  = "Add Server -> Address: minecraft.debney.net  Port: 19132 (UDP)"
```

---

## Connect to the server

1. Open **Minecraft Bedrock Edition** (Windows, Xbox, iOS, Android, etc.).  
2. Go to **Play → Servers → Add Server**.  
3. Enter:  
   - Address: `minecraft.debney.net`  
   - Port: `19132`  
4. Join and play 🎮  

---

## Gameplay settings

Gameplay is configured through variables in `variables.tf`.

Standard options (gamemode, difficulty, view distance, max players, etc.) are
passed to the container as environment variables. **World game rules** are
different — they live inside the world save, not `server.properties`, so
`user_data` applies them via the server console each time a **fresh** world is
created.

| Setting | Variable | Default | Effect |
|---|---|---|---|
| Keep inventory | `keep_inventory` | `false` | `false` = players **drop** their items on death |
| Show coordinates | `show_coordinates` | `true` | Displays coordinates on-screen (needs `allow_cheats = true`) |
| Sleeping percentage | `players_sleeping_percentage` | `0` | `0` = a **single** player sleeping skips the night ("one player sleep"); `100` = everyone must sleep |

> **Note on "social spy":** this is a *Java-server plugin* feature (admins
> reading players' private messages). Vanilla Bedrock has no such feature, so
> there is nothing to enable or disable here.

### Changing a game rule

The EC2 instance uses `lifecycle { ignore_changes = [user_data] }`, so editing
these variables only affects a **freshly rebuilt** server — it does **not**
change the currently running world. There are two levels:

- **Live world (takes effect now):** run the console command on the server (via
  SSM Session Manager → the `bedrock-server` instance):
  ```bash
  sudo docker exec bedrock send-command gamerule keepInventory false
  sudo docker exec bedrock send-command gamerule playerssleepingpercentage 0
  ```
  Confirm a rule's current value by sending it without a value, then reading the log:
  ```bash
  sudo docker exec bedrock send-command gamerule playerssleepingpercentage
  sudo docker logs --tail 5 bedrock
  ```
- **Future rebuilds (durable):** update the variable in `variables.tf` and
  commit. The boot-time console loop re-applies it whenever a new world is
  generated.

For a setting to be both live *and* durable, do both.

---

## Resetting the world

This wipes the current world and generates a fresh one. **Back up first** — the
hourly S3 sync mirrors into `.../worlds`, so take a separate dated snapshot the
mirror won't overwrite. Run everything on the server (SSM Session Manager →
`bedrock-server`):

1. **Snapshot the current world** (dated path, kept forever):
   ```bash
   TS=$(date +%Y%m%d-%H%M)
   sudo aws s3 sync /opt/bedrock/worlds "s3://minecraft-debney-backups/snapshots/$TS" --region ap-southeast-2
   echo "Snapshot: s3://minecraft-debney-backups/snapshots/$TS"
   ```
2. **Reset** (moves the old world aside as a second safety copy, regenerates a
   fresh one with the same name so players connect unchanged):
   ```bash
   sudo docker stop bedrock
   sudo mv /opt/bedrock/worlds/SurvivalWorld /opt/bedrock/worlds/SurvivalWorld.old
   sudo docker start bedrock
   ```
3. **Re-apply live game rules** to the fresh world (a new world resets rules to
   Bedrock defaults):
   ```bash
   sudo docker exec bedrock send-command gamerule keepInventory false
   sudo docker exec bedrock send-command gamerule playerssleepingpercentage 0
   ```
4. Once you've confirmed the new world in-game, remove the local copy to free
   disk (the S3 snapshot remains your backup):
   ```bash
   sudo rm -rf /opt/bedrock/worlds/SurvivalWorld.old
   ```

To restore a snapshot later:
```bash
sudo docker stop bedrock
sudo aws s3 sync s3://minecraft-debney-backups/snapshots/<TIMESTAMP> /opt/bedrock/worlds --region ap-southeast-2
sudo docker start bedrock
```

---

## Backups

### Automatic backups
- Terraform creates an S3 bucket: **`minecraft-debney-backups`**  
- The EC2 instance syncs the world save data `/opt/bedrock/worlds` → S3 hourly:
  ```bash
  aws s3 sync /opt/bedrock/worlds s3://minecraft-debney-backups/worlds
  ```
- Only the `worlds/` save data is backed up. The server binary and packs are
  reinstalled automatically on every rebuild, so there's no need to store them.
- S3 versioning is enabled, so even overwritten/deleted files are recoverable.  

### Manual backup
Trigger a backup anytime:
```bash
aws s3 sync /opt/bedrock/worlds s3://minecraft-debney-backups/worlds
```

### Restore from backup
If you rebuild the server:
```bash
aws s3 sync s3://minecraft-debney-backups/worlds /opt/bedrock/worlds
docker restart bedrock
```

Your world will be restored.  

---

## Disaster Recovery Runbook

Use this if the server is destroyed or rebuilt.

1. **Rebuild the server**
   ```bash
   terraform apply
   ```
2. **Restore world data**
   ```bash
   aws s3 sync s3://minecraft-debney-backups/worlds /opt/bedrock/worlds
   docker restart bedrock
   ```
3. **Verify server**
   ```bash
   docker logs -f bedrock
   ```
   Ensure it loads the correct world.  
4. **Check DNS**
   ```bash
   nslookup minecraft.debney.net
   ```
   Should resolve to your Elastic IP.  
5. **Test as a player**
   Connect in Minecraft client → `minecraft.debney.net:19132`.  

---

## Testing Backups

### Dry run
Check what would restore without copying:
```bash
aws s3 sync s3://minecraft-debney-backups/worlds /tmp/test-world --dryrun
```

### Spin up a test server
1. Duplicate repo or rename resources (e.g. `bedrock-test`).  
2. Deploy:
   ```bash
   terraform apply
   ```
3. Restore from S3:
   ```bash
   aws s3 sync s3://minecraft-debney-backups/worlds /opt/bedrock/worlds
   docker restart bedrock
   ```
4. Join via the test server IP.  
5. Destroy when done:
   ```bash
   terraform destroy
   ```

### Spot-check files
```bash
aws s3 ls s3://minecraft-debney-backups/worlds/ --recursive
aws s3 cp s3://minecraft-debney-backups/worlds/BedrockWorld/level.dat .
```

---

## Cleanup

To delete everything:
```bash
terraform destroy
```

⚠️ World data will be lost unless backed up to S3 first.  

---

✅ With this setup you now have:
- Stable DNS (`minecraft.debney.net`)  
- Elastic IP for fixed address  
- Automated + manual S3 backups  
- A clear recovery runbook  
- Procedures to test backups  
- One-liner restore for emergencies 🚀
