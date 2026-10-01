# Company A's network: a private-only server, reachable only through the
# VPN tunnel — no internet gateway here at all, since nothing in this VPC
# ever needs to reach the public internet directly.

data "aws_availability_zones" "company_a" {
  provider = aws.company_a
  state    = "available"
}

data "aws_ami" "al2023_company_a" {
  provider    = aws.company_a
  owners      = ["amazon"]
  most_recent = true
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_vpc" "company_a" {
  provider             = aws.company_a
  cidr_block           = var.company_a_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "company-a-vpc" })
}

resource "aws_subnet" "company_a_private" {
  provider          = aws.company_a
  vpc_id            = aws_vpc.company_a.id
  cidr_block        = cidrsubnet(var.company_a_cidr, 8, 0)
  availability_zone = data.aws_availability_zones.company_a.names[0]
  tags              = merge(var.tags, { Name = "company-a-private" })
}

resource "aws_route_table" "company_a_private" {
  provider = aws.company_a
  vpc_id   = aws_vpc.company_a.id
  tags     = merge(var.tags, { Name = "company-a-private-rt" })
}

resource "aws_route_table_association" "company_a_private" {
  provider       = aws.company_a
  subnet_id      = aws_subnet.company_a_private.id
  route_table_id = aws_route_table.company_a_private.id
}

resource "aws_key_pair" "company_a" {
  provider   = aws.company_a
  key_name   = "s2s-vpn-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "company_a_server" {
  provider    = aws.company_a
  name        = "company-a-server-sg"
  description = "SSH and ICMP from Company Bs network only, reached via the VPN tunnel"
  vpc_id      = aws_vpc.company_a.id

  ingress {
    description = "SSH from Company B"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.company_b_cidr]
  }

  ingress {
    description = "ICMP from Company B"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.company_b_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_instance" "company_a_server" {
  provider                   = aws.company_a
  ami                        = data.aws_ami.al2023_company_a.id
  instance_type              = var.instance_type
  subnet_id                  = aws_subnet.company_a_private.id
  key_name                   = aws_key_pair.company_a.key_name
  vpc_security_group_ids     = [aws_security_group.company_a_server.id]
  associate_public_ip_address = false
  tags                       = merge(var.tags, { Name = "company-a-server" })
}
