# Look up a default VPC + public subnet (works in new accounts).
# If your account has no default VPC, see README for a VPC module alternative.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security group: UDP 19132 (Bedrock), optional SSH blocked (we'll use SSM).
resource "aws_security_group" "bedrock_sg" {
  name        = "bedrock-sg"
  description = "Allow Bedrock UDP 19132 and instance egress"
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
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = var.enable_ipv6 ? ["::/0"] : []
  }

  tags = { Name = "bedrock-sg" }
}

# IAM role + instance profile for SSM Session Manager
data "aws_iam_policy" "ssm_core" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role" "ec2_role" {
  name               = "bedrock-ec2-ssm"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
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

resource "aws_iam_role_policy_attachment" "attach_ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = data.aws_iam_policy.ssm_core.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "bedrock-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# User data: install Docker and run the Bedrock container
locals {
  user_data = <<-BASH
    #!/bin/bash
    set -euxo pipefail

    dnf update -y
    dnf install -y docker
    systemctl enable --now docker
    usermod -aG docker ec2-user

    mkdir -p /opt/bedrock
    chown ec2-user:ec2-user /opt/bedrock

    # pull & run the server (multi-arch image)
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
  BASH
}

# Pick the first public subnet in the default VPC for simplicity
locals {
  subnet_id = data.aws_subnets.default_public.ids[0]
}

# Latest Amazon Linux 2023 AMI (x86_64)
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

  # Root volume: expand if you want more space for worlds/backups
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "bedrock-server"
  }
}

# Elastic IP so your server IP doesn't change on reboot
resource "aws_eip" "bedrock_eip" {
  instance = aws_instance.bedrock.id
  domain   = "vpc"
}

output "server_ip" {
  description = "Public IP of your Bedrock server"
  value       = aws_eip.bedrock_eip.public_ip
}

output "connect_hint" {
  description = "How to connect from Bedrock clients"
  value       = "Add Server -> Address: ${aws_eip.bedrock_eip.public_ip}  Port: 19132 (UDP)"
}
