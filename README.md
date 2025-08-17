# Minecraft Bedrock on AWS (Terraform)

## Quick Restore (One-Liner)

If you ever rebuild or lose the server, run this inside the EC2 instance to restore your world:

```bash
aws s3 sync s3://minecraft-debney-backups/world /opt/bedrock && docker restart bedrock
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

## Backups

### Automatic backups
- Terraform creates an S3 bucket: **`minecraft-debney-backups`**  
- The EC2 instance syncs `/opt/bedrock` → S3 hourly:
  ```bash
  aws s3 sync /opt/bedrock s3://minecraft-debney-backups/world
  ```
- S3 versioning is enabled, so even overwritten/deleted files are recoverable.  

### Manual backup
Trigger a backup anytime:
```bash
aws s3 sync /opt/bedrock s3://minecraft-debney-backups/world
```

### Restore from backup
If you rebuild the server:
```bash
aws s3 sync s3://minecraft-debney-backups/world /opt/bedrock
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
   aws s3 sync s3://minecraft-debney-backups/world /opt/bedrock
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
aws s3 sync s3://minecraft-debney-backups/world /tmp/test-world --dryrun
```

### Spin up a test server
1. Duplicate repo or rename resources (e.g. `bedrock-test`).  
2. Deploy:
   ```bash
   terraform apply
   ```
3. Restore from S3:
   ```bash
   aws s3 sync s3://minecraft-debney-backups/world /opt/bedrock
   docker restart bedrock
   ```
4. Join via the test server IP.  
5. Destroy when done:
   ```bash
   terraform destroy
   ```

### Spot-check files
```bash
aws s3 ls s3://minecraft-debney-backups/world/ --recursive
aws s3 cp s3://minecraft-debney-backups/world/level.dat .
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
