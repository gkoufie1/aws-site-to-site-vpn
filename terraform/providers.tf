terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Two regions, two providers: Company A's network lives in one, Company B's
# (the simulated customer site, running the actual Libreswan VPN gateway) in
# the other. This is the trick that avoids needing a real router or ISP
# cooperation at all — both "sites" are AWS, so both get real, natively
# inbound-reachable public IPs with no NAT in the way.
provider "aws" {
  alias  = "company_a"
  region = var.company_a_region
}

provider "aws" {
  alias  = "company_b"
  region = var.company_b_region
}
