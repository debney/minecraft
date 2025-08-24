# Use default VPC and one of its subnets.
data "aws_vpc" "default" { default = true }

data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security group allowing UDP/19132 (Bedrock)
resource "aws_security_group" "bedrock_sg" {
  name        = "bedrock-sg"
  description = "Allow Bedrock UDP 19132"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = var.allowed_ingress_cidr
    content {
      description = "Bedrock UDP"
      from_port   = 19132
      to_port     = 19132
      protocol    = "udp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = var.enable_ipv6 ? ["::/0"] : []
  }

  tags = { Name = "bedrock-sg" }
}

# SSM access (no SSH keys needed)
data "aws_iam_policy" "ssm_core" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "bedrock-ec2-ssm"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "attach_ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = data.aws_iam_policy.ssm_core.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "bedrock-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# User data: install Docker and run itzg/minecraft-bedrock-server
locals {
  user_data = <<-BASH
    #!/bin/bash
    set -euxo pipefail

    dnf update -y
    dnf install -y docker awscli
    systemctl enable --now docker
    usermod -aG docker ec2-user

    mkdir -p /opt/bedrock
    chown ec2-user:ec2-user /opt/bedrock

    docker pull itzg/minecraft-bedrock-server:latest

    docker run -d --name=bedrock \
      -p 19132:19132/udp \
      -v /opt/bedrock:/data \
      --restart=always \
      -e EULA=${var.eula ? "TRUE" : "FALSE"} \
      -e SERVER_NAME="${var.server_name}" \
      -e GAMEMODE="${var.gamemode}" \
      -e DIFFICULTY="${var.difficulty}" \
      -e LEVEL_NAME="${var.level_name}" \
      -e VIEW_DISTANCE=${var.view_distance} \
      -e MAX_PLAYERS=${var.max_players} \
      itzg/minecraft-bedrock-server:latest

    # --- Backup section ---
    # Add hourly sync to S3 (replace bucket name if different)
    echo "0 * * * * root aws s3 sync /opt/bedrock s3://${aws_s3_bucket.minecraft_backups.bucket}/world" >> /etc/crontab
  BASH
}

# Choose a subnet from the default VPC
locals { subnet_id = data.aws_subnets.default_public.ids[0] }

# AL2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"] # Amazon
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "bedrock" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.bedrock_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  user_data                   = local.user_data

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "bedrock-server" }
}

# Elastic IP so your IP is stable
resource "aws_eip" "bedrock_eip" {
  instance = aws_instance.bedrock.id
  domain   = "vpc"
}

data "aws_iam_policy_document" "s3_access" {
  statement {
    actions   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.minecraft_backups.arn,
      "${aws_s3_bucket.minecraft_backups.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "s3_backup_policy" {
  name   = "bedrock-s3-backup"
  policy = data.aws_iam_policy_document.s3_access.json
}

resource "aws_iam_role_policy_attachment" "attach_s3" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_backup_policy.arn
}
# --- SNS topic for alerts ---
resource "aws_sns_topic" "alerts" {
  name = "minecraft-bedrock-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- EC2 'down' alarm (AWS status checks fail) ---
resource "aws_cloudwatch_metric_alarm" "ec2_status_failed" {
  alarm_name          = "bedrock-ec2-statuscheckfailed"
  alarm_description   = "EC2 status checks failing (instance likely down)"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"   # combined instance+system
  statistic           = "Maximum"
  period              = 60                    # check every 1 minute
  evaluation_periods  = 2                     # for 2 minutes
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.bedrock.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# --- OPTIONAL: High CPU alarm (helps spot overload) ---
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "bedrock-ec2-cpu-high"
  alarm_description   = "CPU > 80% for 5 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.bedrock.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
# IAM role for EventBridge to use SSM
resource "aws_iam_role" "eventbridge_ec2_role" {
  name = "eventbridge-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eventbridge_ssm" {
  role       = aws_iam_role.eventbridge_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMFullAccess"
}

# EventBridge rule: restart EC2 daily at 13:00 UTC
resource "aws_cloudwatch_event_rule" "daily_restart" {
  name                = "bedrock-daily-restart"
  description         = "Restart Bedrock EC2 daily at 13:00 UTC"
  schedule_expression = "cron(0 13 * * ? *)" # 13:00 UTC daily
}

# Target: send to SSM to restart instance
resource "aws_cloudwatch_event_target" "daily_restart_target" {
  rule      = aws_cloudwatch_event_rule.daily_restart.name
  target_id = "RestartEC2"
  arn       = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/AWS-RunShellScript"
  role_arn  = aws_iam_role.eventbridge_ec2_role.arn

  input = jsonencode({
    DocumentName = "AWS-RunShellScript"
    Targets = [{
      Key    = "InstanceIds"
      Values = [aws_instance.bedrock.id]
    }]
    Parameters = {
      commands = ["sudo reboot"]
    }
  })
}

data "aws_caller_identity" "current" {}