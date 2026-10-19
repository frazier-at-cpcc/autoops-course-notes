#!/usr/bin/env bash
# Verifies the 2.1 "Virtual Network Infrastructure as Code" notes.
# The AWS configuration cannot be applied here (no AWS account), so it is
# checked statically: terraform fmt -check, init, and validate. The test
# also shows that validate catches a reference error, that plan stops
# without credentials, and the cidrsubnet()/cidrhost() results in the notes.
#
# Needs: terraform (any 1.x), network access to the Terraform registry
#        (the hashicorp/aws provider download is large; the plugin cache
#        in ${AO_CACHE:-~/.cache/autoops-notes} makes reruns fast).
# No ports or containers. Never reads real AWS credentials.
set -euo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

CACHE="${AO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/autoops-notes}"
mkdir -p "$CACHE/tf-plugins"
export TF_PLUGIN_CACHE_DIR="$CACHE/tf-plugins"
export TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=1   # reuse the cache in fresh dirs
export TF_CLI_CONFIG_FILE="$WORK/terraformrc"; : > "$TF_CLI_CONFIG_FILE"
export CHECKPOINT_DISABLE=1
# No credentials from anywhere: env, files, or instance metadata
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_ENDPOINT_URL
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_EC2_METADATA_DISABLED=true

mkdir "$WORK/vpc" && cd "$WORK/vpc"

cat > versions.tf <<'EOF'
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
EOF

cat > network.tf <<'EOF'
locals {
  azs     = ["us-east-1a", "us-east-1b"]
  public  = ["10.20.0.0/24", "10.20.1.0/24"]
  private = ["10.20.10.0/24", "10.20.11.0/24"]
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.lab.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.public[count.index]

  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.lab.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.private[count.index]
}
EOF

cat > routing.tf <<'EOF'
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
EOF

cat > firewall.tf <<'EOF'
resource "aws_security_group" "lb" {
  name   = "lab-lb"
  vpc_id = aws_vpc.lab.id
  ingress {
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [aws_vpc.lab.cidr_block]
  }
}

resource "aws_security_group" "web" {
  name   = "lab-web"
  vpc_id = aws_vpc.lab.id
  ingress {
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.lb.id]
  }
}
EOF

cat > lb.tf <<'EOF'
variable "cert_arn" {
  description = "ACM certificate for the listener"
  type        = string
}

resource "aws_lb" "web" {
  name               = "lab-web"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.lb.id]
}

resource "aws_lb_target_group" "web" {
  name     = "lab-web"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.lab.id
  health_check {
    path = "/healthz"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.cert_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}
EOF

cat > dns.tf <<'EOF'
resource "aws_route53_zone" "public" {
  name = "lab.example.com"
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.public.zone_id
  name    = "www.lab.example.com"
  type    = "A"
  alias {
    name                   = aws_lb.web.dns_name
    zone_id                = aws_lb.web.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_zone" "internal" {
  name = "lab.internal"
  vpc {
    vpc_id = aws_vpc.lab.id
  }
}

resource "aws_route53_record" "db" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "db.lab.internal"
  type    = "A"
  ttl     = 300
  records = ["10.20.10.25"]
}
EOF

say "1. subnet math with terraform console (in an empty directory)"
mkdir "$WORK/console"
c() { (cd "$WORK/console" && echo "$1" | terraform console); }
for e in 'cidrsubnet("10.20.0.0/16", 8, 1)' 'cidrsubnet("10.20.0.0/16", 8, 10)' \
         'cidrhost("10.20.10.0/24", 25)'; do
  printf '> %s\n%s\n' "$e" "$(c "$e")"
done
[ "$(c 'cidrsubnet("10.20.0.0/16", 8, 1)')" = '"10.20.1.0/24"' ] || fail cidrsubnet1
[ "$(c 'cidrsubnet("10.20.0.0/16", 8, 10)')" = '"10.20.10.0/24"' ] || fail cidrsubnet10
[ "$(c 'cidrhost("10.20.10.0/24", 25)')" = '"10.20.10.25"' ] || fail cidrhost
# The locals in network.tf agree with the function results
[ "$(c 'jsonencode([for i in [0, 1, 10, 11] : cidrsubnet("10.20.0.0/16", 8, i)])')" \
  = "\"[\\\"10.20.0.0/24\\\",\\\"10.20.1.0/24\\\",\\\"10.20.10.0/24\\\",\\\"10.20.11.0/24\\\"]\"" ] \
  || fail "subnet list"

say "2. static checks: fmt, init, validate"
terraform fmt -check -recursive || fail "terraform fmt"
terraform init -input=false -no-color >"$WORK/init.txt"
grep -E 'Installing hashicorp/aws|Installed hashicorp/aws|Using hashicorp/aws|Reusing' "$WORK/init.txt" || true
terraform validate -no-color | tee "$WORK/validate.txt"
grep -q 'Success! The configuration is valid.' "$WORK/validate.txt" || fail validate
[ "$(terraform validate -json | jq -r .error_count)" = 0 ] || fail "validate json"
# Count what is defined
grep -hoE '^resource "aws_[a-z0-9_]+"' ./*.tf | sort | uniq -c | sort -rn

say "3. validate catches a broken reference"
cp routing.tf "$WORK/routing.good"
sed -i 's/subnet_id     = aws_subnet.public\[0\].id/subnet_id     = aws_subnet.public.id/' routing.tf
set +e; terraform validate -no-color >"$WORK/bad.txt" 2>&1; rc=$?; set -e
grep -E 'Error:|^ *11:' "$WORK/bad.txt"
[ "$rc" = 1 ] || fail "broken reference should fail validate"
grep -q 'Error: Missing resource instance key' "$WORK/bad.txt" || fail "error text changed"
cp "$WORK/routing.good" routing.tf
terraform validate -no-color >/dev/null

say "4. plan needs credentials, so it stops here"
set +e
cat > lab.tfvars <<'EOF'
cert_arn = "arn:aws:acm:us-east-1:111122223333:certificate/lab"
EOF
terraform plan -no-color -input=false -var-file=lab.tfvars >"$WORK/plan.txt" 2>&1
rc=$?
set -e
grep -E '^Error:' "$WORK/plan.txt"
[ "$rc" = 1 ] || fail "plan without credentials should fail"
grep -q 'No valid credential sources found' "$WORK/plan.txt" || fail "plan error text changed"

echo; echo "ALL 2.1 VIRTUAL-NETWORK CHECKS PASSED (static validation only; nothing was created in AWS)"
