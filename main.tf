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
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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
    principals { type = "Service", identifiers = ["ec2.amazonaws.com"] }
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
    dnf install -y docker
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
  BASH
}

# Choose a subnet from the default VPC
locals { subnet_id = data.aws_subnets.default_public.ids[0] }

# AL2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"] # Amazon
  filter { name = "name", values = ["al2023-ami-*-x86_64"] }
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