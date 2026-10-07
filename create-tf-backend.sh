#!/usr/bin/env bash
# Terraform の S3 backend 用バケットを作成する。
# 既にバケットがある場合は、設定だけを適用し直す（何度実行しても同じ状態になる）。
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: create-tf-backend.sh -b <bucket> [options]

Terraform の S3 backend 用バケットを作成し、backend.hcl の例を出力します。
state のロックには S3 のロックファイル（use_lockfile）を使うため、DynamoDB は作成しません。

Options:
  -b, --bucket <name>          バケット名（必須）
  -r, --region <region>        リージョン（既定: AWS_REGION、なければ ap-northeast-1）
  -p, --profile <profile>      AWS CLI のプロファイル（既定: AWS_PROFILE）
  -k, --key <key>              出力する backend.hcl の key（既定: terraform.tfstate）
      --kms-key-id <id>        KMS キーで暗号化する（既定: SSE-S3）
      --noncurrent-days <n>    古いバージョンの state を残す日数（既定: 90）
      --tag <key=value>        バケットに付けるタグ（複数指定可。既定で ManagedBy=manual を付ける）
  -y, --yes                    確認をせずに実行する
      --dry-run                AWS に変更を加えず、実行する内容だけを表示する
  -h, --help                   このヘルプを表示する
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*" >&2
}

bucket=""
region="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"
profile="${AWS_PROFILE:-}"
key="terraform.tfstate"
kms_key_id=""
noncurrent_days=90
tags=("ManagedBy=manual")
yes=false
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b | --bucket) bucket="${2:?}"; shift 2 ;;
    -r | --region) region="${2:?}"; shift 2 ;;
    -p | --profile) profile="${2:?}"; shift 2 ;;
    -k | --key) key="${2:?}"; shift 2 ;;
    --kms-key-id) kms_key_id="${2:?}"; shift 2 ;;
    --noncurrent-days) noncurrent_days="${2:?}"; shift 2 ;;
    --tag) tags+=("${2:?}"); shift 2 ;;
    -y | --yes) yes=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[[ -n "$bucket" ]] || { usage >&2; die "--bucket is required"; }
[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "invalid bucket name: $bucket"
[[ "$noncurrent_days" =~ ^[1-9][0-9]*$ ]] || die "--noncurrent-days must be a positive integer"
for tag in "${tags[@]}"; do
  [[ "$tag" == *=* ]] || die "--tag must be key=value: $tag"
done
command -v aws >/dev/null || die "aws CLI is not installed"

aws_args=(--region "$region")
[[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# AWS に変更を加えるコマンド。--dry-run のときは表示だけする
run() {
  if $dry_run; then
    printf '[dry-run] aws'
    printf ' %q' "$@" "${aws_args[@]}"
    printf '\n'
  else
    aws "$@" "${aws_args[@]}" >/dev/null
  fi
}

# ------------------------------------------------------------
# 実行先の確認
# ------------------------------------------------------------

if $dry_run; then
  account_id="<account-id>"
else
  account_id="$(aws sts get-caller-identity --query Account --output text "${aws_args[@]}")"
fi

log "account: $account_id"
log "region : $region"
log "bucket : $bucket"

if ! $yes && ! $dry_run; then
  read -r -p "このアカウントに backend 用バケットを作成します。続行しますか？ [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "aborted"
fi

# ------------------------------------------------------------
# バケットの作成
# ------------------------------------------------------------

if ! $dry_run && aws s3api head-bucket --bucket "$bucket" --expected-bucket-owner "$account_id" "${aws_args[@]}" >/dev/null 2>&1; then
  log "bucket already exists. applying settings only"
else
  log "creating bucket"
  if [[ "$region" == "us-east-1" ]]; then
    run s3api create-bucket --bucket "$bucket"
  else
    run s3api create-bucket --bucket "$bucket" \
      --create-bucket-configuration "LocationConstraint=$region"
  fi
  $dry_run || aws s3api wait bucket-exists --bucket "$bucket" "${aws_args[@]}"
fi

# ------------------------------------------------------------
# バケットの設定
# ------------------------------------------------------------

log "blocking public access"
run s3api put-public-access-block --bucket "$bucket" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

log "disabling ACLs"
run s3api put-bucket-ownership-controls --bucket "$bucket" \
  --ownership-controls '{"Rules":[{"ObjectOwnership":"BucketOwnerEnforced"}]}'

log "enabling versioning"
run s3api put-bucket-versioning --bucket "$bucket" \
  --versioning-configuration Status=Enabled

log "enabling default encryption"
if [[ -n "$kms_key_id" ]]; then
  encryption="{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$kms_key_id\"},\"BucketKeyEnabled\":true}]}"
else
  encryption='{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
fi
run s3api put-bucket-encryption --bucket "$bucket" \
  --server-side-encryption-configuration "$encryption"

log "denying non-TLS access"
policy="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"DenyInsecureTransport\",\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3:*\",\"Resource\":[\"arn:aws:s3:::$bucket\",\"arn:aws:s3:::$bucket/*\"],\"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}}]}"
run s3api put-bucket-policy --bucket "$bucket" --policy "$policy"

log "expiring noncurrent versions after $noncurrent_days days"
lifecycle="{\"Rules\":[{\"ID\":\"expire-noncurrent-versions\",\"Status\":\"Enabled\",\"Filter\":{},\"NoncurrentVersionExpiration\":{\"NoncurrentDays\":$noncurrent_days},\"AbortIncompleteMultipartUpload\":{\"DaysAfterInitiation\":7}}]}"
run s3api put-bucket-lifecycle-configuration --bucket "$bucket" \
  --lifecycle-configuration "$lifecycle"

log "tagging bucket"
tag_set=""
for tag in "${tags[@]}"; do
  tag_set+="{\"Key\":\"${tag%%=*}\",\"Value\":\"${tag#*=}\"},"
done
run s3api put-bucket-tagging --bucket "$bucket" \
  --tagging "{\"TagSet\":[${tag_set%,}]}"

# ------------------------------------------------------------
# backend.hcl の例
# ------------------------------------------------------------

log "done. backend.hcl:"
cat <<EOF
bucket       = "$bucket"
key          = "$key"
region       = "$region"
encrypt      = true
use_lockfile = true
EOF
