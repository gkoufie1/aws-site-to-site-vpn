# The actual Site-to-Site VPN: a Virtual Private Gateway attached to Company
# A's VPC, a Customer Gateway pointed at Company B's VPN server (its stable
# Elastic IP), and a statically-routed VPN connection between them — matching
# AWS's own "Site-to-Site VPN (Static)" pattern, not the BGP/dynamic variant.

resource "aws_vpn_gateway" "company_a" {
  provider = aws.company_a
  vpc_id   = aws_vpc.company_a.id
  tags     = merge(var.tags, { Name = "company-a-vgw" })
}

resource "aws_vpn_gateway_route_propagation" "company_a_private" {
  provider       = aws.company_a
  vpn_gateway_id = aws_vpn_gateway.company_a.id
  route_table_id = aws_route_table.company_a_private.id
}

resource "aws_customer_gateway" "company_b" {
  provider   = aws.company_a # customer gateways are a company-A-side (AWS VGW side) concept
  bgp_asn    = 65000
  ip_address = aws_eip.vpn_server.public_ip
  type       = "ipsec.1"
  tags       = merge(var.tags, { Name = "company-b-cgw" })
}

resource "aws_vpn_connection" "this" {
  provider            = aws.company_a
  vpn_gateway_id      = aws_vpn_gateway.company_a.id
  customer_gateway_id = aws_customer_gateway.company_b.id
  type                = "ipsec.1"
  static_routes_only  = true
  tags                = merge(var.tags, { Name = "company-a-to-company-b" })
}

resource "aws_vpn_connection_route" "company_b" {
  provider                = aws.company_a
  vpn_connection_id       = aws_vpn_connection.this.id
  destination_cidr_block  = var.company_b_cidr
}
