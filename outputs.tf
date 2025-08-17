output "server_ip" {
  description = "Public IP of your Bedrock server"
  value       = aws_eip.bedrock_eip.public_ip
}

output "connect_hint" {
  description = "How to connect from Bedrock clients"
  value       = "Add Server -> Address: ${aws_eip.bedrock_eip.public_ip}  Port: 19132 (UDP)"
}