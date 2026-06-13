# =============================================================================
# VPC — кастомная изолированная сеть для WordPress
#
# Архитектура:
#   VPC 10.0.0.0/16
#   ├── Public Subnet A (10.0.1.0/24) — AZ a, EC2 здесь
#   ├── Public Subnet B (10.0.2.0/24) — AZ b, резерв
#   ├── Internet Gateway               — выход в интернет
#   └── Route Table                    — 0.0.0.0/0 → IGW
#
# Почему только public subnets:
#   Private subnet + NAT Gateway = $32/месяц (не Free Tier).
#   EC2 защищён через Security Group — прямой доступ закрыт,
#   трафик идёт только через CloudFront.
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

# ─────────────────────────────────────────────
# VPC
# ─────────────────────────────────────────────

resource "aws_vpc" "wordpress" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true   # Required for SSM endpoint resolution
  enable_dns_hostnames = true   # Required: EC2 public DNS used as CloudFront origin

  tags = {
    Name    = "wordpress-vpc"
    Project = "wordpress-aws"
  }
}

# ─────────────────────────────────────────────
# PUBLIC SUBNETS (two AZs — best practice)
# ─────────────────────────────────────────────

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.wordpress.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true   # EC2 gets a public IP automatically

  tags = {
    Name    = "wordpress-public-a"
    Project = "wordpress-aws"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.wordpress.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name    = "wordpress-public-b"
    Project = "wordpress-aws"
  }
}

# ─────────────────────────────────────────────
# INTERNET GATEWAY
# Connects the VPC to the public internet.
# Without IGW — EC2 can't reach internet (no dnf update, no WP-CLI download).
# ─────────────────────────────────────────────

resource "aws_internet_gateway" "wordpress" {
  vpc_id = aws_vpc.wordpress.id

  tags = {
    Name    = "wordpress-igw"
    Project = "wordpress-aws"
  }
}

# ─────────────────────────────────────────────
# ROUTE TABLE
# Routes all outbound traffic (0.0.0.0/0) through the IGW.
# ─────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.wordpress.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.wordpress.id
  }

  tags = {
    Name    = "wordpress-public-rt"
    Project = "wordpress-aws"
  }
}

# Associate both subnets with the public route table
resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}
