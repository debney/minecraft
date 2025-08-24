############################################
# Networking: minimal public VPC
############################################

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "mc-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "mc-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  tags = { Name = "mc-public-1a" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "mc-public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

############################################
# Security Group: Bedrock UDP 19132
############################################

resource "aws_security_group" "bedrock_sg" {
  name        = "bedrock-sg"
  description = "Allow Bedrock UDP 19132"
  vpc_id      = aws_vpc.main.id

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

############################################
# IAM for EC2: SSM core + S3 backup access
############################################

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

# S3 backup permissions (bucket defined further below)
data "aws_iam_policy_document" "s3_access" {
  statement {
    actions = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
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

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "bedrock-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

############################################
# User data: install Docker + Bedrock + hourly S3 sync
############################################

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

    # Hourly backup of /opt/bedrock to S3
    grep -q 'minecraft-debney-backups' /etc/crontab || echo "0 * * * * root aws s3 sync /opt/bedrock s3://${aws_s3_bucket.minecraft_backups.bucket}/world" >> /etc/crontab
  BASH
}

############################################
# AMI + EC2 instance + Elastic IP
############################################

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
  subnet_id                   = aws_subnet.public.id
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

resource "aws_eip" "bedrock_eip" {
  instance = aws_instance.bedrock.id
  domain   = "vpc"
}

############################################
# CloudWatch alarms + SNS email
############################################

resource "aws_sns_topic" "alerts" {
  name = "minecraft-bedrock-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "ec2_status_failed" {
  alarm_name          = "bedrock-ec2-statuscheckfailed"
  alarm_description   = "EC2 status checks failing (instance likely down)"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"

  dimensions = { InstanceId = aws_instance.bedrock.id }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# Optional: high CPU alarm to spot overload
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

  dimensions = { InstanceId = aws_instance.bedrock.id }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

############################################
# Daily restart at 13:00 UTC via EventBridge → SSM
############################################

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "eventbridge_ec2_role" {
  name = "eventbridge-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "events.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eventbridge_ssm" {
  role       = aws_iam_role.eventbridge_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMFullAccess"
}

resource "aws_cloudwatch_event_rule" "daily_restart" {
  name                = "bedrock-daily-restart"
  description         = "Restart Bedrock EC2 daily at 13:00 UTC"
  schedule_expression = "cron(0 13 * * ? *)"
}

resource "aws_cloudwatch_event_target" "daily_restart_target" {
  rule      = aws_cloudwatch_event_rule.daily_restart.name
  target_id = "RestartEC2"

  # SSM document to run shell commands
  arn      = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/AWS-RunShellScript"
  role_arn = aws_iam_role.eventbridge_ec2_role.arn

  # WHICH instances to run on
  run_command_targets {
    key    = "InstanceIds"
    values = [aws_instance.bedrock.id]
  }

  # WHAT to run
  input = jsonencode({
    commands = ["sudo reboot"]
  })
}