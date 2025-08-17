variable "aws_region" {
  type        = string
  default     = "ap-southeast-2" # Sydney
  description = "AWS region to deploy into"
}

variable "instance_type" {
  type        = string
  default     = "t3a.small"
  description = "EC2 size for Bedrock server"
}

variable "server_name" {
  type    = string
  default = "Bedrock-on-AWS"
}
variable "allowed_ingress_cidr" {
  type    = list(string)
  default = ["0.0.0.0/0"] # replace with your home CIDR to lock down
}
variable "enable_ipv6" {
  type    = bool
  default = false
}

# Gameplay
variable "eula" {
  type    = bool
  default = true
}
variable "gamemode" {
  type    = string
  default = "creative"
} # survival|creative|adventure
variable "difficulty" {
  type    = string
  default = "normal"
} # peaceful|easy|normal|hard
variable "level_name" {
  type    = string
  default = "BedrockWorld"
}
variable "view_distance" {
  type    = number
  default = 32
}
variable "max_players" {
  type    = number
  default = 10
}