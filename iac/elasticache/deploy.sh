#!/bin/bash
# ElastiCache Serverless Valkey デプロイスクリプト
# ParallelCluster の VPC と同じ Subnet/Security Group を使用
#
# Prerequisites:
#   - parallelcluster-prerequisites CloudFormation スタックが存在すること
#
# ElastiCache Serverless は異なる AZ の Private Subnet が 2-3 つ必要。
# Prerequisites スタックは Private Subnet を1つしか作成しないため、
# このスクリプトが不足分を VPC 内に作成する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ネットワーク情報を読み込む（上書きしない）
ENV_FILE="${PROJECT_ROOT}/env_vars"
source "${ENV_FILE}"

# デフォルト値
REGION="${AWS_REGION:-us-west-2}"
CACHE_NAME="${CACHE_NAME:-pd-di-kvcache}"
ENGINE_VERSION="${ENGINE_VERSION:-8}"

# ElastiCache の出力は別ファイルに保存（env_vars を上書きしない）
ELASTICACHE_ENV_FILE="${SCRIPT_DIR}/env_vars"

STACK_NAME="parallelcluster-prerequisites"

echo "[INFO] Fetching prerequisites stack outputs..."

VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`VPC`].OutputValue' \
  --output text)

PRIMARY_SUBNET=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`PrimaryPrivateSubnet`].OutputValue' \
  --output text)

SECURITY_GROUP=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`SecurityGroup`].OutputValue' \
  --output text)

if [[ -z "${VPC_ID}" || -z "${PRIMARY_SUBNET}" || -z "${SECURITY_GROUP}" ]]; then
  echo "[ERROR] Failed to retrieve prerequisites stack outputs"
  exit 1
fi

echo "[INFO] VPC: ${VPC_ID}"
echo "[INFO] Primary Private Subnet: ${PRIMARY_SUBNET}"
echo "[INFO] Security Group: ${SECURITY_GROUP}"

# Primary Subnet の AZ を取得
PRIMARY_AZ=$(aws ec2 describe-subnets \
  --subnet-ids "${PRIMARY_SUBNET}" \
  --region "${REGION}" \
  --query 'Subnets[0].AvailabilityZone' \
  --output text)

echo "[INFO] Primary Subnet AZ: ${PRIMARY_AZ}"

# VPC の CIDR を取得（2つ目の Subnet 用 CIDR 計算に使用）
VPC_CIDR=$(aws ec2 describe-vpcs \
  --vpc-ids "${VPC_ID}" \
  --region "${REGION}" \
  --query 'Vpcs[0].CidrBlock' \
  --output text)

echo "[INFO] VPC CIDR: ${VPC_CIDR}"

# Primary と異なる AZ を1つ選択
AVAILABLE_AZS=$(aws ec2 describe-availability-zones \
  --region "${REGION}" \
  --query 'AvailabilityZones[?State==`available`].ZoneName' \
  --output text)

SECONDARY_AZ=""
for AZ in ${AVAILABLE_AZS}; do
  if [[ "${AZ}" != "${PRIMARY_AZ}" ]]; then
    SECONDARY_AZ="${AZ}"
    break
  fi
done

if [[ -z "${SECONDARY_AZ}" ]]; then
  echo "[ERROR] Could not find a secondary AZ different from ${PRIMARY_AZ}"
  exit 1
fi

echo "[INFO] Secondary AZ for ElastiCache: ${SECONDARY_AZ}"

# 同一 VPC 内で Secondary AZ に既存の Private Subnet があるか確認
EXISTING_SECONDARY=$(aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=availabilityZone,Values=${SECONDARY_AZ}" \
    "Name=map-public-ip-on-launch,Values=false" \
  --region "${REGION}" \
  --query 'Subnets[0].SubnetId' \
  --output text)

if [[ "${EXISTING_SECONDARY}" != "None" && -n "${EXISTING_SECONDARY}" ]]; then
  SECONDARY_SUBNET="${EXISTING_SECONDARY}"
  echo "[INFO] Using existing secondary subnet: ${SECONDARY_SUBNET}"
else
  # ElastiCache 用の Secondary Subnet を新規作成
  # Primary が使っていない /18 ブロックを使用
  SECONDARY_CIDR="10.0.64.0/18"
  echo "[INFO] Creating secondary private subnet (${SECONDARY_CIDR}) in ${SECONDARY_AZ}..."

  SECONDARY_SUBNET=$(aws ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block "${SECONDARY_CIDR}" \
    --availability-zone "${SECONDARY_AZ}" \
    --region "${REGION}" \
    --query 'Subnet.SubnetId' \
    --output text)

  # タグ付け
  aws ec2 create-tags \
    --resources "${SECONDARY_SUBNET}" \
    --tags \
      "Key=Name,Value=pd-di-elasticache-subnet-2" \
      "Key=Project,Value=pd-disaggregated-inference" \
    --region "${REGION}"

  echo "[OK] Created secondary subnet: ${SECONDARY_SUBNET}"
fi

echo "[INFO] Subnet 1: ${PRIMARY_SUBNET} (${PRIMARY_AZ})"
echo "[INFO] Subnet 2: ${SECONDARY_SUBNET} (${SECONDARY_AZ})"

# ElastiCache Serverless の作成（冪等: 既存の場合はスキップ）
EXISTING_CACHE_STATUS=$(aws elasticache describe-serverless-caches \
  --serverless-cache-name "${CACHE_NAME}" \
  --region "${REGION}" \
  --query 'ServerlessCaches[0].Status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "${EXISTING_CACHE_STATUS}" == "available" ]]; then
  echo "[INFO] ElastiCache Serverless '${CACHE_NAME}' already exists and is available. Skipping creation."
elif [[ "${EXISTING_CACHE_STATUS}" == "creating" ]]; then
  echo "[INFO] ElastiCache Serverless '${CACHE_NAME}' is already being created. Waiting..."
  aws elasticache wait serverless-cache-available \
    --serverless-cache-name "${CACHE_NAME}" \
    --region "${REGION}"
else
  echo "[INFO] Creating ElastiCache Serverless Valkey cache: ${CACHE_NAME}"

  aws elasticache create-serverless-cache \
    --serverless-cache-name "${CACHE_NAME}" \
    --engine valkey \
    --major-engine-version "${ENGINE_VERSION}" \
    --subnet-ids "${PRIMARY_SUBNET}" "${SECONDARY_SUBNET}" \
    --security-group-ids "${SECURITY_GROUP}" \
    --region "${REGION}" \
    --output json

  echo "[INFO] Waiting for availability..."
  aws elasticache wait serverless-cache-available \
    --serverless-cache-name "${CACHE_NAME}" \
    --region "${REGION}"
fi

echo "[OK] ElastiCache Serverless is available!"
echo ""

aws elasticache describe-serverless-caches \
  --serverless-cache-name "${CACHE_NAME}" \
  --region "${REGION}" \
  --query 'ServerlessCaches[0].Endpoint' \
  --output table

# エンドポイント情報を取得して保存
ENDPOINT_ADDRESS=$(aws elasticache describe-serverless-caches \
  --serverless-cache-name "${CACHE_NAME}" \
  --region "${REGION}" \
  --query 'ServerlessCaches[0].Endpoint.Address' \
  --output text)

ENDPOINT_PORT=$(aws elasticache describe-serverless-caches \
  --serverless-cache-name "${CACHE_NAME}" \
  --region "${REGION}" \
  --query 'ServerlessCaches[0].Endpoint.Port' \
  --output text)

cat > "${ELASTICACHE_ENV_FILE}" << EOF
# ElastiCache Serverless Valkey Endpoint
# Generated: $(date)
export ELASTICACHE_ENDPOINT="${ENDPOINT_ADDRESS}"
export ELASTICACHE_PORT="${ENDPOINT_PORT}"
export ELASTICACHE_URL="rediss://${ENDPOINT_ADDRESS}:${ENDPOINT_PORT}"
EOF

echo "[OK] Endpoint saved to: ${ELASTICACHE_ENV_FILE}"
echo ""
echo "Next steps:"
echo "  1. source ${ELASTICACHE_ENV_FILE}"
echo "  2. FSx にエンドポイントを配置する:"
echo "     echo \"ELASTICACHE_ENDPOINT=\${ELASTICACHE_ENDPOINT}\" > /fsx/elasticache_env_vars"
