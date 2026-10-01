# aws-site-to-site-vpn

A real AWS Site-to-Site VPN — IPsec, a Virtual Private Gateway, a Customer Gateway, static
routing — connecting two simulated company networks in two different AWS regions. Built and
verified the same way as the other projects in this portfolio: a real architecture, every claim
backed by a command that actually ran, every failure documented as it happened.

**What this is:** two VPCs in two regions (`us-east-2` and `us-west-2`), linked by a real AWS
Site-to-Site VPN connection. One side ("Company B") hosts the IPsec gateway itself — a plain
EC2 instance running Libreswan — and a private server behind it. The other side ("Company A")
hosts a single private server reachable only through the tunnel.

**Why two AWS regions, not a real on-prem network:** connecting an actual home network to AWS's
Site-to-Site VPN needs the home side to be *inbound*-reachable on a public IP — port-forwarded
IPsec through a home router, with no carrier-grade NAT in the way. Using a second AWS region
instead sidesteps all of that: an EC2 instance in a public subnet gets a real, natively
inbound-reachable public IP with zero router or ISP dependency. Both "sites" are AWS; one just
plays the role a physical on-prem gateway would.

## Architecture

```
Company A — us-east-2                      Company B — us-west-2
┌─────────────────────────┐                ┌──────────────────────────────────┐
│ VPC 10.0.0.0/16          │                │ VPC 192.168.0.0/16                │
│  private subnet           │                │  public subnet                    │
│   company-a-server        │                │   vpn-server (Libreswan, EIP)     │
│   (private IP only)       │   IPsec VPN    │  private subnet                   │
│                           │◄──────────────►│   company-b-server                │
│ VGW ── Customer Gateway ──┼────────────────┤   (private IP only, routes        │
│       (static routes)     │                │    10.0.0.0/16 via vpn-server)    │
└─────────────────────────┘                └──────────────────────────────────┘
```

## Build steps

1. **Checked AWS account state before building anything:** budget ($0.019 spent, well under the
   $15/$20 caps), and VPC quota per region. `us-east-1` was still at its 5-VPC default limit
   from an earlier project — used `us-east-2` and `us-west-2` instead, both with headroom.
2. **Found a CIDR conflict before it caused a problem.** Both regions already had manually-created
   VPCs, but both used the identical `10.0.0.0/16` block — a Site-to-Site VPN can't route between
   two networks claiming the same address space. A VPC's primary CIDR can't be changed after the
   fact, so the fix was deleting both (empty, no instances) and building fresh with
   non-overlapping ranges (`10.0.0.0/16` and `192.168.0.0/16`), matching Chetan Agrawal's
   [AWS VPC and Networking](https://www.udemy.com/course/networking-in-aws/) course exercise this
   project is adapted from.
3. **Terraform built both VPCs, both subnets, the VGW, Customer Gateway, and a statically-routed
   VPN connection** — 26 resources, one `terraform apply`.
4. **Libreswan installed and configured on the VPN server**, using the real tunnel address and
   pre-shared key Terraform's own `aws_vpn_connection` resource returns as outputs — the PSK
   never touched the terminal or this repo; it was piped directly from `terraform output -raw`
   into the remote secrets file.
5. **The tunnel came up on the first real attempt**, confirmed from both sides: AWS reported
   Tunnel1 status `UP`, and Libreswan reported `STATE_V2_ESTABLISHED_IKE_SA` /
   `STATE_V2_ESTABLISHED_CHILD_SA` with the eroute actively owning traffic.
6. **The first connectivity test worked immediately** — pinging Company A's server directly from
   the VPN server: 4/4 packets, 0% loss, ~47ms RTT.
7. **The deeper test — routing *through* the gateway — failed at first**, and two real bugs were
   found and fixed before it worked. See Findings.

## Results — the real test

Ping and SSH from `company-b-server` (a private server with no direct route of its own to
Company A, routed entirely through the VPN gateway), to `company-a-server`, across the tunnel:

```
PING 10.0.0.82 (10.0.0.82) 56(84) bytes of data.
64 bytes from 10.0.0.82: icmp_seq=1 ttl=126 time=47.8 ms
64 bytes from 10.0.0.82: icmp_seq=2 ttl=126 time=47.5 ms
64 bytes from 10.0.0.82: icmp_seq=3 ttl=126 time=47.2 ms
64 bytes from 10.0.0.82: icmp_seq=4 ttl=126 time=47.2 ms
--- 10.0.0.82 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3005ms

$ ssh ec2-user@10.0.0.82 hostname
ip-10-0-0-82.us-east-2.compute.internal
```

That hostname came back from the real instance in `us-east-2` — not a loopback, not the gateway
itself answering. A genuinely different private server, in a different region, reached entirely
through the tunnel.

## Findings

| # | What happened | Cause | Fix |
|---|---|---|---|
| 1 | Two manually-created VPCs both used `10.0.0.0/16` | A Site-to-Site VPN can't route between two networks with identical CIDRs | Deleted both (empty) and rebuilt with non-overlapping ranges |
| 2 | `terraform apply` failed creating the Company A security group: `Invalid security group description` | AWS security group descriptions don't allow apostrophes — the text said "Company B's network" | Removed the apostrophe. Hit the *same* error again later in a second description for the same reason |
| 3 | Direct ping from the VPN server to Company A worked; ping from Company B's *other* private server, routed through the gateway, got 100% packet loss | `net.ipv4.ip_forward` was `0` on the VPN server — AWS's "disable source/dest check" grants VPC-level permission to route traffic, but the Linux kernel still needs forwarding turned on to actually do it | `sysctl -w net.ipv4.ip_forward=1`, persisted via `/etc/sysctl.d/` |
| 4 | Still 100% packet loss after fixing #3 | `tcpdump` on the VPN server's interface showed **zero packets arriving at all** — the VPN server's security group allowed traffic from Company A's CIDR (for replies) and the IPsec/management ports, but never from Company B's *own* CIDR. Security groups apply to forwarded traffic passing through an instance, not just traffic addressed to it | Added an ingress rule allowing traffic from Company B's own CIDR into the VPN server's security group |

Findings #3 and #4 together are the real lesson here: a missing kernel setting and a missing
security group rule produced the *identical symptom* (100% packet loss on the indirect path,
0% loss on the direct path), and `tcpdump` was what actually distinguished "packets aren't being
forwarded" from "packets never arrive at all."

## What this does not show

- **A lab-scale test, not production traffic.** Two tiny `t3.micro` instances, one short ping/SSH
  test, not a sustained load or failover drill.
- **Static routing only**, not BGP/dynamic routing — matches the "Site-to-Site VPN (Static)"
  variant specifically, not the dynamic alternative AWS also offers.
- **One tunnel verified up** (Tunnel1); the second (Tunnel2) was not separately tested, since AWS
  only needs one of the two to be active for the connection overall to work.
- **No real on-prem network was involved anywhere.** Both "sites" are AWS regions — see the
  architecture note above for exactly why, and what this project does and doesn't prove about
  connecting a *real* home or office network.

## Cost

Roughly **$0.08/hour** while running: the Site-to-Site VPN connection itself (~$0.05/hour,
regardless of traffic) plus three `t3.micro` instances (~$0.03/hour combined). Checked against a
healthy budget (under $0.02 spent of a $15–20 cap) before building. Torn down the same session —
see below.

## Reproduce it

```bash
git clone https://github.com/gkoufie1/aws-site-to-site-vpn
cd aws-site-to-site-vpn/terraform
cp terraform.tfvars.example terraform.tfvars   # put your own public IP in; gitignored
terraform init
terraform plan -out=tfplan                      # review it: 26 resources
terraform apply tfplan
```

Then, using the `tunnel1_address` and `tunnel1_preshared_key` (sensitive — read it with
`terraform output -raw tunnel1_preshared_key`, don't print it) Terraform outputs, install
Libreswan on the VPN server and configure `/etc/ipsec.d/tunnel1.conf` and `/etc/ipsec.secrets`
following [Chetan Agrawal's](https://www.udemy.com/course/networking-in-aws/) corrected config
template (`phase2alg=aes128-sha256`, `ike=aes128-sha256;modp2048`, no `auth=esp` line). **Enable
IP forwarding on the VPN server** (`sysctl -w net.ipv4.ip_forward=1`, persisted) and **make sure
its security group allows traffic from Company B's own CIDR**, not just the reply direction —
both are required and neither is optional, per Findings #3 and #4 above.

**Tearing down:** `terraform destroy` removes all 26 resources — the VPN connection, both VPCs,
all three instances, the gateways. Verify with a direct `aws ec2 describe-vpcs` check in both
regions afterward, not just Terraform's exit code.

## Repo layout

```
aws-site-to-site-vpn/
├── README.md              you are here
└── terraform/
    ├── providers.tf        two aws provider aliases, one per region
    ├── variables.tf
    ├── company-a.tf        Company A's VPC, private subnet, server
    ├── company-b.tf        Company B's VPC, public+private subnets, VPN server, server
    ├── vpn.tf              VGW, Customer Gateway, the VPN connection and its static route
    ├── outputs.tf           tunnel addresses and PSKs (marked sensitive)
    └── terraform.tfvars.example
```
