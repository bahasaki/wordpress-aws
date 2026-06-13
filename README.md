# wordpress-aws

Production-grade WordPress deployment on AWS Free Tier using Terraform.

![Terraform](https://img.shields.io/badge/Terraform-1.5+-7B42BC?logo=terraform)
![AWS](https://img.shields.io/badge/AWS-Free%20Tier-FF9900?logo=amazonaws)
![CI/CD](https://img.shields.io/github/actions/workflow/status/bahasaki/wordpress-aws/terraform.yml?label=CI%2FCD)

---

## Architecture

```
Internet
   │ HTTPS
   ▼
CloudFront (CDN + SSL termination)
   │ HTTP
   ▼
EC2 t3.micro (Amazon Linux 2023)
   │  LAMP + WordPress + wp-cli
   │  fail2ban + firewalld
   │  CloudWatch Agent
   │
   └── Custom VPC (10.0.0.0/16)
         └── Public Subnet (10.0.1.0/24)

Secrets  → AWS SSM Parameter Store (SecureString)
State    → S3 + DynamoDB locking
DNS      → Namecheap (manual CNAME, no Route 53)
SSL      → ACM (DNS validation)
```

## Design decisions

| Decision | Why |
|---|---|
| No Elastic IP | Free Tier — CloudFront origin updated via `terraform apply` after restart |
| No RDS | Free Tier — MySQL runs on EC2, avoids $15/mo after 12-month RDS free period |
| No Route 53 | Free Tier — manual CNAME on Namecheap, saves $0.50/month per hosted zone |
| SSM Parameter Store | Secrets never in tfvars, never in Git, never in Terraform state |
| S3 remote state | Team-standard — DynamoDB locking prevents concurrent applies |
| Custom VPC | Production-grade network isolation vs default VPC |

---

## Infrastructure

| Resource | Details |
|---|---|
| VPC | 10.0.0.0/16, 2 public subnets (AZ a/b), IGW, route table |
| EC2 t3.micro | Amazon Linux 2023, Apache, PHP 8.2, MariaDB, WordPress, wp-cli |
| Security Group | Port 80 (HTTP) + 22 (SSH) |
| IAM Role | Least-privilege: SSM `/wordpress/*` read + CloudWatch Agent |
| ACM Certificate | `javari.cc` + `www.javari.cc`, DNS validation |
| CloudFront | HTTPS termination, static asset caching, HTTP→HTTPS redirect |
| SSM Parameters | `/wordpress/db_password`, `/wordpress/wp_admin_password` (SecureString) |
| S3 + DynamoDB | Remote state backend + locking (provisioned via `bootstrap/`) |
| CloudWatch Logs | Apache access/error, user-data, fail2ban — 7-day retention |
| CloudWatch Metrics | CPU, memory, disk, swap — namespace `WordPress/EC2` |

---

## Repository structure

```
wordpress-aws/
├── .github/
│   └── workflows/
│       └── terraform.yml       # CI/CD: fmt → validate → plan → apply
├── bootstrap/
│   ├── main.tf                 # S3 bucket + DynamoDB table for remote state
│   └── outputs.tf              # Outputs backend config block
├── scripts/
│   └── put-ssm-params.sh       # One-time: load secrets into SSM
├── main.tf                     # EC2, Security Group, IAM, CloudFront, ACM, CloudWatch
├── vpc.tf                      # VPC, subnets, IGW, route table
├── ssm_parameters.tf           # SSM data sources + IAM policy
├── variables.tf                # Input variables (no secrets)
├── outputs.tf                  # CloudFront domain, EC2 IP, DNS instructions
├── user_data.sh                # Bootstrap: LAMP + WordPress + hardening + CW Agent
├── terraform.tfvars.example    # Example config (no secrets)
└── .gitignore
```

---

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform ≥ 1.5
- EC2 Key Pair `wp-server` created in AWS Console (us-east-1)
- Namecheap account managing `javari.cc`

---

## Deploy

### Step 1 — Bootstrap remote state (once per project lifetime)

```bash
cd bootstrap/
terraform init
terraform apply
# Copy the backend_config output value
cd ..
```

Paste the backend block into `main.tf` (replace `REPLACE_WITH_YOUR_ACCOUNT_ID`).

### Step 2 — Load secrets into SSM (once)

```bash
bash scripts/put-ssm-params.sh
# Prompts for db_password and wp_admin_password
# Stored as SecureString — never written to disk
```

### Step 3 — Configure

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: domain_name, key_pair_name, wp_admin_email
# No passwords — they live in SSM
```

### Step 4 — Init with remote backend

```bash
terraform init
# Terraform will detect the S3 backend and migrate state
```

### Step 5 — Deploy via CI/CD (recommended)

```bash
git checkout -b feature/initial-deploy
git add .
git commit -m "feat: initial WordPress infrastructure"
git push origin feature/initial-deploy
# Open PR → GitHub Actions runs fmt + validate + plan
# Plan output appears as PR comment
# Merge → GitHub Actions runs apply automatically
```

Or deploy locally:

```bash
terraform plan
terraform apply
```

### Step 6 — Add ACM CNAME to Namecheap

Terraform pauses waiting for ACM validation. Get the values:

```bash
terraform output acm_dns_validation_records
```

In Namecheap → Advanced DNS, add the CNAME record.
**Note:** Namecheap strips the root domain — enter only the prefix as Host.

### Step 7 — Add DNS records to Namecheap

After apply completes:

```bash
terraform output namecheap_dns_records
```

| Type | Host | Value | TTL |
|---|---|---|---|
| CNAME | www | `xxxxx.cloudfront.net` | 300 |
| URL Redirect | @ | `https://www.javari.cc` | Auto |

---

## CI/CD pipeline

```
Pull Request                     Merge to main
────────────                     ─────────────
terraform fmt    (no AWS)        terraform fmt    (no AWS)
terraform validate               terraform validate
terraform plan ──────────────→  terraform apply
      │
      ▼
PR comment with plan output
(reviewer sees changes before merge)
```

GitHub Secrets required:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

GitHub Environment required:
- `production` (Settings → Environments → New environment)
- Optional: add Required reviewers for manual approval gate

---

## Operations

**SSH into EC2:**
```bash
ssh -i ~/.ssh/wp-server.pem ec2-user@$(terraform output -raw ec2_public_ip)
```

**Watch bootstrap progress:**
```bash
sudo tail -f /var/log/user-data.log
```

**After EC2 stop/start (IP changes — no Elastic IP):**
```bash
terraform apply  # detects new public_dns, updates CloudFront origin
```

**Destroy:**
```bash
terraform destroy
# Note: CloudFront takes ~15 min to disable before deletion
```

**Delete SSM secrets after destroy:**
```bash
aws ssm delete-parameter --name /wordpress/db_password --region us-east-1
aws ssm delete-parameter --name /wordpress/wp_admin_password --region us-east-1
```

---

## Cost

| Service | Free Tier | After Free Tier |
|---|---|---|
| EC2 t3.micro | 750 hrs/month (12 mo) | ~$8.50/mo |
| EBS gp3 8 GiB | 30 GiB/month (12 mo) | ~$0.64/mo |
| Public IPv4 address | 750 hrs/month (12 mo) | ~$3.60/mo ($0.005/hr) |
| CloudFront | 1 TB + 10M requests/month (always) | pay-per-use |
| ACM | Always free | free |
| SSM Standard Parameters | Always free | free |
| CloudWatch Logs | 5 GB ingestion/month (always) | $0.50/GB |
| S3 remote state | Minimal — cents/month | cents/month |
| DynamoDB locking | 25 WCU/RCU free (always) | free |

> ⚠️ **Public IPv4 pricing (since Jan 2024):** AWS charges $0.005/hr for every public IPv4
> address — even when the instance is stopped. Within Free Tier: 750 hrs/month free for
> 12 months. After that: ~$3.60/month. To avoid charges after Free Tier — stop the instance
> when not in use, or consider deallocating the IP.

**For a low-traffic portfolio site during Free Tier: $0/month.**
