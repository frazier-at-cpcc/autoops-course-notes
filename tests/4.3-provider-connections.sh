#!/usr/bin/env bash
# Verifies the 4.3 Securing Connections to Providers notes: AWS CLI profiles
# and precedence, the boto3 credential chain, a least-privilege policy
# (parliament), the GitHub Actions OIDC workflow (actionlint), the trust
# policy shape (jq), and the gcloud configuration commands in the table.
# Everything runs offline against a throwaway HOME with dummy keys; nothing
# calls a cloud API.
# Needs: aws (AWS CLI v2), python3 with boto3, parliament (pip install
#   parliament), actionlint, jq, gcloud
set -euo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

# Isolate from any real cloud config and from instance metadata
for v in $(env | grep -oE '^(AWS|AZURE|GOOGLE|CLOUDSDK)_[A-Z_]+' || true); do unset "$v"; done
export HOME="$WORK/home" AWS_EC2_METADATA_DISABLED=true
export CLOUDSDK_CONFIG="$WORK/gcloud"
mkdir -p "$HOME/.aws"
run() { echo "\$ $*"; eval "$*"; }

say "AWS CLI profiles"
cat > "$HOME/.aws/config" <<'EOF'
[default]
region = us-east-1

[profile lab]
region = us-west-2

[profile deployer]
role_arn = arn:aws:iam::111122223333:role/deploy
source_profile = lab
EOF
cat > "$HOME/.aws/credentials" <<'EOF'
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = dummy-secret-1

[lab]
aws_access_key_id = AKIAI44QH8DHBEXAMPLE
aws_secret_access_key = dummy-secret-2
EOF
chmod 600 "$HOME/.aws/credentials"
run aws configure list-profiles | tee profiles.txt
[ "$(sed 1d profiles.txt | tr "\n" " ")" = "default lab deployer " ] || fail "profiles"
run aws configure get region --profile lab
[ "$(aws configure get region --profile lab)" = us-west-2 ] || fail "lab region"
out=$(run 'AWS_REGION=eu-west-1 aws configure list --profile lab'); echo "$out"
grep -Eq '^profile +: lab +: manual +: --profile' <<<"$out" || fail "profile from --profile"
grep -Eq '^access_key +: \*+MPLE +: shared-credentials-file' <<<"$out" || fail "key from file"
grep -Eq "^region +: eu-west-1 +: env +: \['AWS_REGION'" <<<"$out" || fail "env region wins"
# AWS_PROFILE is the environment-variable way to pick a profile
AWS_PROFILE=lab aws configure list | grep -Eq '^profile +: lab +: env' || fail "AWS_PROFILE"

# Commands named in the notes exist in this CLI version (offline checks)
for c in "configure sso" "sso login"; do
  o=$(aws $c --no-such-flag 2>&1 || true)
  grep -q 'Unknown options' <<<"$o" || fail "aws $c missing"
done
python3 - <<'PY' || fail "IAM access-key operations"
import botocore.session
ops = botocore.session.get_session().get_service_model("iam").operation_names
for op in ("CreateAccessKey", "UpdateAccessKey", "DeleteAccessKey", "GetAccessKeyLastUsed"):
    assert op in ops, op
PY

say "SDK credential provider chain (boto3)"
cat > chain.py <<'EOF'
# chain.py: which provider supplied credentials?
import boto3

for profile in (None, "lab", "deployer"):
    s = boto3.Session(profile_name=profile)
    c = s.get_credentials()
    print(f"{profile or '(none)':9} {c.method}")
EOF
out1=$(run python3 chain.py); echo "$out1"
grep -qx '(none)    shared-credentials-file' <<<"$out1" || fail "default from file"
grep -qx 'deployer  assume-role' <<<"$out1" || fail "deployer assume-role"
out2=$(
  run export AWS_ACCESS_KEY_ID=AKIAI44QH8DHBEXAMPLE
  run export AWS_SECRET_ACCESS_KEY=dummy-secret-3
  run python3 chain.py
); echo "$out2"
grep -qx '(none)    env' <<<"$out2" || fail "env wins with no profile"
grep -qx 'lab       shared-credentials-file' <<<"$out2" || fail "explicit profile beats env keys"
# AWS_PROFILE (unlike an explicit profile_name) does not beat env keys
AWS_PROFILE=lab AWS_ACCESS_KEY_ID=AKIAI44QH8DHBEXAMPLE AWS_SECRET_ACCESS_KEY=x \
  python3 -c 'import boto3; print(boto3.Session().get_credentials().method)' | grep -qx env \
  || fail "AWS_PROFILE vs env keys"

say "least-privilege policy"
cat > s3-read.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "ReadBackups", "Effect": "Allow",
     "Action": "s3:GetObject",
     "Resource": "arn:aws:s3:::net-backups/cfg/*"},
    {"Sid": "ListThatPrefix", "Effect": "Allow",
     "Action": "s3:ListBucket",
     "Resource": "arn:aws:s3:::net-backups",
     "Condition": {"StringLike":
       {"s3:prefix": "cfg/*"}}}
  ]
}
EOF
cat > too-broad.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "s3:*", "Resource": "*"}
  ]
}
EOF
cat > wrong-arn.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "s3:GetObject",
     "Resource": "arn:aws:s3:::net-backups"}
  ]
}
EOF
echo '$ parliament --minimal < too-broad.json'
o=$(parliament --minimal < too-broad.json || true); echo "$o"
[ "$o" = RESOURCE_STAR ] || fail "too-broad finding"
echo '$ parliament --minimal < wrong-arn.json'
o=$(parliament --minimal < wrong-arn.json || true); echo "$o"
[ "$o" = RESOURCE_MISMATCH ] || fail "wrong-arn finding"
echo '$ parliament --minimal < s3-read.json; echo $?'
o=$(parliament --minimal < s3-read.json); rc=$?; echo "$o$rc"
[ -z "$o" ] && [ $rc -eq 0 ] || fail "least-privilege policy should be clean"

say "OIDC trust policy shape (jq only; not sent to AWS)"
cat > trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:cpcc-netops/site:environment:production"
    }}
  }]
}
EOF
jq -e '.Statement[0].Action == "sts:AssumeRoleWithWebIdentity"
  and (.Statement[0].Principal.Federated | endswith("oidc-provider/token.actions.githubusercontent.com"))
  and .Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
  and .Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:cpcc-netops/site:environment:production"
  and (.Statement[0].Condition.StringEquals | has("token.actions.githubusercontent.com:aud"))
  and (.Statement[0].Condition.StringEquals | has("token.actions.githubusercontent.com:sub"))' \
  trust.json >/dev/null || fail "trust policy shape"
echo "trust.json OK"

say "GitHub Actions OIDC workflow (actionlint; not run against AWS)"
mkdir -p .github/workflows
cat > .github/workflows/deploy.yml <<'EOF'
name: deploy
on:
  push:
    branches: [main]
permissions:
  id-token: write  # lets the job request a JWT
  contents: read
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
    - uses: aws-actions/configure-aws-credentials@v6
      with:
        role-to-assume: ${{ vars.DEPLOY_ROLE_ARN }}
        aws-region: us-east-1
    - run: aws sts get-caller-identity
EOF
actionlint .github/workflows/deploy.yml || fail "actionlint"
grep -q 'aws-access-key-id' .github/workflows/deploy.yml && fail "no long-lived keys allowed"
echo "actionlint: deploy.yml OK"

say "gcloud configurations (isolated CLOUDSDK_CONFIG)"
gcloud config configurations create lab --no-activate >/dev/null 2>&1
gcloud config set project netops-lab --configuration lab >/dev/null 2>&1
[ "$(CLOUDSDK_ACTIVE_CONFIG_NAME=lab gcloud config get project 2>/dev/null)" = netops-lab ] || fail "gcloud config"
gcloud config configurations activate lab >/dev/null 2>&1
gcloud config configurations list --format='value(name,is_active)' | grep -Eq '^lab\s+True' || fail "activate"
gcloud auth activate-service-account --help >/dev/null 2>&1 || fail "activate-service-account"
gcloud auth application-default --help >/dev/null 2>&1 || fail "application-default"
echo "gcloud configuration commands OK"

echo "ALL 4.3 PROVIDER-CONNECTIONS CHECKS PASSED"
