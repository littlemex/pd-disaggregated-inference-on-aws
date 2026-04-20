#!/bin/bash
# 全インフラの削除スクリプト
# ParallelCluster → ElastiCache → Prerequisites の順に削除

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGION="${AWS_REGION:-us-west-2}"
PROFILE="${AWS_PROFILE:-a7760}"
CLUSTER_NAME="${CLUSTER_NAME:-pd-di-cluster}"
STACK_NAME="${STACK_NAME:-parallelcluster-prerequisites}"
CACHE_NAME="${CACHE_NAME:-pd-di-kvcache}"

echo "=============================================="
echo "  Infrastructure Cleanup"
echo "=============================================="
echo ""
echo "[WARNING] This will delete:"
echo "  - ParallelCluster: ${CLUSTER_NAME}"
echo "  - ElastiCache: ${CACHE_NAME}"
echo "  - Prerequisites Stack: ${STACK_NAME}"
echo ""
read -p "Continue? (yes/no): " CONFIRM

if [[ "${CONFIRM}" != "yes" ]]; then
  echo "[INFO] Cleanup cancelled"
  exit 0
fi

# Step 1: ParallelCluster
echo "[Step 1/3] Deleting ParallelCluster"
echo "-----------------------------------"

pcluster delete-cluster \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${REGION}" || true

echo "[INFO] Waiting for cluster deletion..."
pcluster wait for-cluster-deletion \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${REGION}" || true

echo "[OK] ParallelCluster deleted"

# Step 2: ElastiCache
echo "[Step 2/3] Deleting ElastiCache Serverless"
echo "-----------------------------------"

cd "${PROJECT_ROOT}/iac/elasticache"
bash cleanup.sh || true

echo "[OK] ElastiCache deletion initiated"

# Step 3: Prerequisites stack
echo "[Step 3/3] Deleting Prerequisites Stack"
echo "-----------------------------------"

aws cloudformation delete-stack \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --profile "${PROFILE}" || true

echo "[INFO] Waiting for stack deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --profile "${PROFILE}" || true

echo "[OK] Prerequisites stack deleted"

echo ""
echo "=============================================="
echo "  Cleanup Complete!"
echo "=============================================="
