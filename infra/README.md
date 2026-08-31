# Rent-a-Ride — infra

Terraform for the bastion + private-app network this project runs on.

## Topology

```
                         Internet
                             │
                    ┌────────▼────────┐
                    │ Internet Gateway│
                    └────────┬────────┘
                             │
        VPC 10.0.0.0/16      │
   ┌─────────────────────────┴─────────────────────────┐
   │  Public subnet (AZ-a) 10.0.1.0/24                  │
   │  ┌────────────┐        ┌─────────────────┐         │
   │  │  Bastion   │        │   NAT Gateway   │         │
   │  │ t3.micro   │        │   (+ EIP)       │         │
   │  └─────┬──────┘        └────────┬────────┘         │
   │        │ SSH (22)               │ outbound only    │
   ├────────┼────────────────────────┼──────────────────┤
   │        │  Private subnet (AZ-b) 10.0.2.0/24         │
   │        ▼                        ▼                   │
   │  ┌──────────────────────────────────────┐          │
   │  │  App instance — t3a.medium            │          │
   │  │  no public IP, reached via bastion    │          │
   │  └──────────────────────────────────────┘          │
   └──────────────────────────────────────────────────────┘
```

- Public subnet routes `0.0.0.0/0` → Internet Gateway.
- Private subnet routes `0.0.0.0/0` → NAT Gateway (outbound only — nothing
  from the internet can initiate a connection into it).
- Public and private subnets sit in two different AZs.
- Bastion security group: SSH (22) from `allowed_ssh_cidr` only.
- Private security group: SSH (22) from the bastion's security group only,
  plus `private_ingress_ports` (default: 3000, 30080, 30300) from inside
  the VPC CIDR only.

## Prerequisites

- Terraform >= 1.5
- AWS credentials available to the provider (env vars, `~/.aws/credentials`,
  or an assumed role) with permission to create VPC/EC2/IAM-free resources
- An AWS account/region with at least 2 availability zones (true for every
  standard region)

## Usage

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — at minimum, set allowed_ssh_cidr to your own IP

terraform init
terraform plan
terraform apply
```

Terraform generates an SSH key pair and writes the private key to
`infra/keys/<key_pair_name>.pem` (0400 permissions, git-ignored). Use the
`ssh_bastion_command` / `ssh_app_command` outputs directly:

```bash
terraform output -raw ssh_bastion_command
terraform output -raw ssh_app_command
```

The app command uses `ProxyCommand` (rather than the bare `-o
ProxyJump=user@host` flag) so it hops through the bastion in one command
with the same key used for both hops. Note that `-o ProxyJump=...` alone
only applies `-i` to the *final* destination — the hidden jump connection
falls back to your default identity and fails with "Permission denied" on
the bastion. For repeat use, an SSH config entry with `IdentityFile` set
per-`Host` (see below) is cleaner than typing the full command each time:

```
# ~/.ssh/config
Host rar-bastion
    HostName <bastion_public_ip>
    User ubuntu
    IdentityFile /path/to/infra/keys/<key_pair_name>.pem

Host rar-app
    HostName <app_private_ip>
    User ubuntu
    IdentityFile /path/to/infra/keys/<key_pair_name>.pem
    ProxyJump rar-bastion
```

Then just `ssh rar-app`.

## Notes / things to tighten before real production use

- `allowed_ssh_cidr` defaults to `0.0.0.0/0` so `apply` works with zero
  config — narrow it to your IP (or a VPN/office CIDR) before this touches
  anything real.
- A single NAT Gateway and a single instance per tier is not HA. For true
  multi-AZ resilience you'd want a public+private subnet pair per AZ, a NAT
  Gateway per AZ, and instances/ASGs spread across both.
- The generated key pair's private key lives on whatever machine runs
  `terraform apply`. For team use, prefer importing an existing public key
  (`aws_key_pair` with `public_key = file(...)`) instead of generating one.
- No IAM instance profiles, CloudWatch logging, or backups are configured
  here — this covers networking + compute only, per the task scope.

## Destroying

```bash
terraform destroy
```

This removes the NAT Gateway and EIP too, so make sure nothing else in the
account depends on them first.
