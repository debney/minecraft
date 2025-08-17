resource "aws_s3_bucket" "minecraft_backups" {
  bucket = "minecraft-debney-backups"
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.minecraft_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}