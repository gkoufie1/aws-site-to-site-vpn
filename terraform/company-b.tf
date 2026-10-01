# Company B's network — the "simulated customer site." Its public subnet
# holds the VPN gateway (Libreswan), playing the role a real on-prem router
# would play. Because it's an EC2 public IP, not a home connection, it's
# natively inbound-reachable with zero NAT/ISP/router dependency at all.

data "aws_availability_zones" "company_b" {
  provider = aws.company_b
  state    = "available"
}

data "aws_ami" "al2023_company_b" {
  provider    = aws.company_b
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

resource "aws_vpc" "company_b" {
  provider             = aws.company_b
  cidr_block           = var.company_b_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "company-b-vpc" })
}

resource "aws_internet_gateway" "company_b" {
  provider = aws.company_b
  vpc_id   = aws_vpc.company_b.id
  tags     = merge(var.tags, { Name = "company-b-igw" })
}

resource "aws_subnet" "company_b_public" {
  provider                = aws.company_b
  vpc_id                  = aws_vpc.company_b.id
  cidr_block              = cidrsubnet(var.company_b_cidr, 8, 0)
  availability_zone       = data.aws_availability_zones.company_b.names[0]
  map_public_ip_on_launch = false # the VPN server gets an Elastic IP instead — stable, won't change on stop/start
  tags                    = merge(var.tags, { Name = "company-b-public" })
}

resource "aws_subnet" "company_b_private" {
  provider          = aws.company_b
  vpc_id            = aws_vpc.company_b.id
  cidr_block        = cidrsubnet(var.company_b_cidr, 8, 100)
  availability_zone = data.aws_availability_zones.company_b.names[0]
  tags              = merge(var.tags, { Name = "company-b-private" })
}

resource "aws_route_table" "company_b_public" {
  provider = aws.company_b
  vpc_id   = aws_vpc.company_b.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.company_b.id
  }

  tags = merge(var.tags, { Name = "company-b-public-rt" })
}

resource "aws_route_table_association" "company_b_public" {
  provider       = aws.company_b
  subnet_id      = aws_subnet.company_b_public.id
  route_table_id = aws_route_table.company_b_public.id
}

# The private subnet's route back to Company A goes through the VPN server
# acting as a router — not through the VPN connection directly, since this
# VPC isn't the one attached to the Virtual Private Gateway.
resource "aws_route_table" "company_b_private" {
  provider = aws.company_b
  vpc_id   = aws_vpc.company_b.id

  route {
    cidr_block           = var.company_a_cidr
    network_interface_id = aws_instance.vpn_server.primary_network_interface_id
  }

  tags = merge(var.tags, { Name = "company-b-private-rt" })
}

resource "aws_route_table_association" "company_b_private" {
  provider       = aws.company_b
  subnet_id      = aws_subnet.company_b_private.id
  route_table_id = aws_route_table.company_b_private.id
}

resource "aws_key_pair" "company_b" {
  provider   = aws.company_b
  key_name   = "s2s-vpn-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "vpn_server" {
  provider    = aws.company_b
  name        = "vpn-server-sg"
  description = "The simulated on-prem VPN gateway (Libreswan)"
  vpc_id      = aws_vpc.company_b.id

  ingress {
    description = "SSH for management, from me only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.my_ip}/32"]
  }

  # IKE/IPsec from AWS's VGW tunnel endpoints. Their exact IPs aren't known
  # until the VPN connection itself is created (a real chicken-and-egg with
  # a security group that has to exist before the instance that needs it),
  # so this is open broadly — standard practice for an internet-facing VPN
  # gateway, since the far end's source IP isn't always knowable in advance.
  ingress {
    description = "IKE"
    from_port   = 500
    to_port     = 500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "IPsec NAT-T"
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "ESP"
    from_port   = 0
    to_port     = 0
    protocol    = "50"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ICMP from Company A, through the tunnel"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.company_a_cidr]
  }

  # The gap that broke forwarding at first: security groups apply to routed
  # traffic passing through an instance, not just traffic addressed to it.
  # Company B's own private server (company-b-server) sits behind this
  # gateway for anything destined to Company A, and that forward-direction
  # traffic needs to be allowed in here too, not just the reply direction.
  ingress {
    description = "All traffic from Company Bs own network, being routed through this gateway"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
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

resource "aws_instance" "vpn_server" {
  provider                    = aws.company_b
  ami                         = data.aws_ami.al2023_company_b.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.company_b_public.id
  key_name                    = aws_key_pair.company_b.key_name
  vpc_security_group_ids      = [aws_security_group.vpn_server.id]
  associate_public_ip_address = true
  source_dest_check           = false # it has to route traffic that isn't addressed to itself
  tags                        = merge(var.tags, { Name = "company-b-vpn-server" })
}

resource "aws_eip" "vpn_server" {
  provider = aws.company_b
  instance = aws_instance.vpn_server.id
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "company-b-vpn-server-eip" })
}

resource "aws_security_group" "company_b_server" {
  provider    = aws.company_b
  name        = "company-b-server-sg"
  description = "EC2-B: SSH only from the VPN server, ICMP from Company A through the tunnel"
  vpc_id      = aws_vpc.company_b.id

  ingress {
    description = "SSH from the VPN server (same VPC)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.company_b_cidr]
  }

  ingress {
    description = "ICMP from Company A, through the tunnel"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.company_a_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_instance" "company_b_server" {
  provider                    = aws.company_b
  ami                         = data.aws_ami.al2023_company_b.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.company_b_private.id
  key_name                    = aws_key_pair.company_b.key_name
  vpc_security_group_ids      = [aws_security_group.company_b_server.id]
  associate_public_ip_address = false
  tags                        = merge(var.tags, { Name = "company-b-server" })
}
