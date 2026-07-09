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
  default = "survival"
} # survival|creative|adventure
variable "difficulty" {
  type    = string
  default = "normal"
} # peaceful|easy|normal|hard
variable "level_name" {
  type    = string
  default = "SurvivalWorld"
}

# Enables cheats/commands for the world (server.properties allow-cheats). Must
# be true for the showcoordinates game rule to actually display coordinates.
variable "allow_cheats" {
  type    = bool
  default = true
}

# World game rules (not server.properties settings), so they are applied via the
# server console after the world loads. user_data sets them on every boot so
# freshly generated worlds get them too.
variable "keep_inventory" {
  type    = bool
  default = true
}
variable "show_coordinates" {
  type    = bool
  default = true
}
variable "view_distance" {
  type    = number
  default = 32
}
variable "max_players" {
  type    = number
  default = 10
}
# Email address to receive alerts (you'll confirm via email)
variable "alert_email" {
  type        = string
  description = "Email address for CloudWatch alarms"
  default     = "debney@gmail.com"
}