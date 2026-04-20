#!/bin/bash
# 全インフラのデプロイスクリプト
# Prerequisites → ElastiCache → ParallelCluster の順にデプロイ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGION="${AWS_REGION:-us-west-2}"
PROFILE="${AWS_PROFILE:-a7760}"
PRIMARY_AZ="${PRIMARY_AZ:-us-west-2d}"

echo "=============================================="
echo "  Prefill-Decode Disaggregated Inference"
echo "  Infrastructure Deployment"
echo "=============================================="
echo ""
echo "[INFO] Region: ${REGION}"
echo "[INFO] Profile: ${PROFILE}"
echo "[INFO] Primary AZ: ${PRIMARY_AZ}"
echo ""

# Step 1: Prerequisites stack
echo "[Step 1/3] Deploying ParallelCluster Prerequisites"
echo "-----------------------------------"

cd "${PROJECT_ROOT}/iac/parallelcluster"
bash deploy-prerequisites.sh

echo ""
echo "[OK] Prerequisites deployed!"
echo ""

# 環境変数を取得
bash create_config.sh

# Step 2: ElastiCache Serverless
echo "[Step 2/3] Deploying ElastiCache Serverless Valkey"
echo "-----------------------------------"

cd "${PROJECT_ROOT}/iac/elasticache"
bash deploy.sh

echo ""
echo "[OK] ElastiCache deployed!"
echo ""

# Step 3: ParallelCluster
echo "[Step 3/3] Deploying ParallelCluster"
echo "-----------------------------------"

cd "${PROJECT_ROOT}/iac/parallelcluster"

# config.yaml の生成（ElastiCache 不要なので元のまま）
source env_vars

envsubst < config.yaml > config-generated.yaml

# クラスター作成
pcluster create-cluster \
  --cluster-name pd-di-cluster \
  --cluster-configuration config-generated.yaml \
  --region "${REGION}" \
  --rollback-on-failure false

echo ""
echo "[OK] ParallelCluster deployment initiated!"
echo ""
echo "=============================================="
echo "  Deployment Summary"
echo "=============================================="
echo ""
echo "1. ParallelCluster:"
echo "   - VPC: ${VPC_ID}"
echo "   - FSx Lustre: ${FSX_ID}"
echo "   - FSx OpenZFS: ${FSXO_ID}"
echo ""
echo "2. ElastiCache Serverless Valkey:"
source "${PROJECT_ROOT}/iac/elasticache/env_vars"
echo "   - Endpoint: ${ELASTICACHE_ENDPOINT}:${ELASTICACHE_PORT}"
echo "   - URL: ${ELASTICACHE_URL}"
echo ""
echo "3. ParallelCluster Status:"
echo "   Check with: pcluster describe-cluster --cluster-name pd-di-cluster --region ${REGION}"
echo ""
echo "Next steps:"
echo "  1. Wait for cluster to become CREATE_COMPLETE"
echo "  2. SSH to head node"
echo "  3. Copy configs and scripts to /fsx"
echo "  4. Submit Slurm jobs"
