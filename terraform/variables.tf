variable "company_a_region" {
  description = "Company A's network"
  type        = string
  default     = "us-east-2"
}

variable "company_b_region" {
  description = "Company B's network — hosts the simulated on-prem VPN gateway"
  type        = string
  default     = "us-west-2"
}

variable "company_a_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "company_b_cidr" {
  type    = string
  default = "192.168.0.0/16"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ssh_public_key_path" {
  description = "Public half only. The private key never leaves the local machine."
  type        = string
  default     = "~/.ssh/s2s_vpn_ed25519.pub"
}

variable "my_ip" {
  description = "Your own public IP, for SSH access to the instances. Set in terraform.tfvars (gitignored)."
  type        = string
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "aws-site-to-site-vpn"
    ManagedBy = "terraform"
  }
}
