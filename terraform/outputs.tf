output "company_a_server_private_ip" {
  value = aws_instance.company_a_server.private_ip
}

output "vpn_server_public_ip" {
  value = aws_eip.vpn_server.public_ip
}

output "company_b_server_private_ip" {
  value = aws_instance.company_b_server.private_ip
}

output "tunnel1_address" {
  value = aws_vpn_connection.this.tunnel1_address
}

output "tunnel2_address" {
  value = aws_vpn_connection.this.tunnel2_address
}

output "tunnel1_preshared_key" {
  value     = aws_vpn_connection.this.tunnel1_preshared_key
  sensitive = true
}

output "tunnel2_preshared_key" {
  value     = aws_vpn_connection.this.tunnel2_preshared_key
  sensitive = true
}
