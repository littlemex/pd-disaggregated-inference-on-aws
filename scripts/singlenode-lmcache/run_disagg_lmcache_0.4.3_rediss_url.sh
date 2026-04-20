#!/bin/bash
# Prefill-Decode Disaggregated Inference 実行スクリプト (LMCache 0.4.3 + rediss:// URL)
#
# 対応構成:
#   - Single GPU (g5.xlarge, GPUS_PER_ROLE=1): Prefill のみ起動し KV cache 書き込みを検証
#   - Multi GPU (g5.12xlarge, GPUS_PER_ROLE=2): Prefill + Decode を別 GPU で同居

#SBATCH --job-name=disagg-rediss
#SBATCH --partition=compute-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=04:00:00
#SBATCH --output=/fsx/logs/disagg-rediss-%j.out
#SBATCH --error=/fsx/logs/disagg-rediss-%j.err
#SBATCH --exclusive

set -euo pipefail

# 環境変数 (overridable)
MODEL_PATH="${MODEL_PATH:-/fsx/models/Llama-3.1-8B-Instruct}"
CONFIG_DIR="${CONFIG_DIR:-/fsx/configs}"
LOG_DIR="${LOG_DIR:-/fsx/logs}"
BASE_IMAGE="${BASE_IMAGE:-vllm/vllm-openai:latest}"
# 1 つの役割 (Prefill or Decode) が使う GPU 数。Decode も起動したい場合は
# GPU 数 >= 2*GPUS_PER_ROLE が必要。g5.xlarge なら 1, g5.12xlarge なら 2 を指定。
GPUS_PER_ROLE="${GPUS_PER_ROLE:-1}"
RUN_DECODE="${RUN_DECODE:-auto}"  # auto / true / false

echo "========================================"
echo "Prefill-Decode Disaggregated Inference"
echo "LMCache 0.4.3 + rediss:// URL"
echo "  GPUS_PER_ROLE=${GPUS_PER_ROLE}"
echo "  RUN_DECODE=${RUN_DECODE}"
echo "========================================"

# GPU 数検出
NUM_GPUS=$(nvidia-smi -L 2>/dev/null | wc -l)
echo "[INFO] Detected ${NUM_GPUS} GPU(s)"

if [[ "${RUN_DECODE}" == "auto" ]]; then
  if (( NUM_GPUS >= 2 * GPUS_PER_ROLE )); then
    RUN_DECODE=true
  else
    RUN_DECODE=false
  fi
fi
echo "[INFO] RUN_DECODE resolved to: ${RUN_DECODE}"

# ElastiCache エンドポイント確認
if [[ -z "${ELASTICACHE_ENDPOINT:-}" ]]; then
  if [[ -f "${ELASTICACHE_ENV_FILE:-/fsx/elasticache_env_vars}" ]]; then
    source "${ELASTICACHE_ENV_FILE:-/fsx/elasticache_env_vars}"
  else
    echo "[ERROR] ELASTICACHE_ENDPOINT が未設定で、env ファイルも見つかりません"
    echo "        export ELASTICACHE_ENDPOINT=<endpoint> を設定してください"
    exit 1
  fi
fi
echo "[INFO] ElastiCache endpoint: ${ELASTICACHE_ENDPOINT}"

# LMCache 設定ファイル生成（rediss:// URL + remote_serde: naive）
mkdir -p "${CONFIG_DIR}"

cat > "${CONFIG_DIR}/lmcache-prefiller-rediss.yaml" << EOF
local_cpu: True
max_local_cpu_size: 5
remote_url: "rediss://${ELASTICACHE_ENDPOINT}:6379"
remote_serde: "naive"
chunk_size: 256
save_unfull_chunk: True
EOF

cat > "${CONFIG_DIR}/lmcache-decoder-rediss.yaml" << EOF
local_cpu: True
max_local_cpu_size: 10
remote_url: "rediss://${ELASTICACHE_ENDPOINT}:6379"
remote_serde: "naive"
chunk_size: 256
save_unfull_chunk: True
EOF

echo "[OK] LMCache config files created with rediss:// URL"

# Docker image がなければ pull
echo "[INFO] Checking docker image: ${BASE_IMAGE}..."
if ! docker image inspect "${BASE_IMAGE}" > /dev/null 2>&1; then
  echo "[INFO] Image not found locally. Pulling ${BASE_IMAGE}..."
  docker pull "${BASE_IMAGE}"
  echo "[OK] Pull complete"
else
  echo "[OK] Image already present"
fi

# 古いコンテナを停止・削除
echo "[INFO] Stopping old containers..."
docker stop vllm-prefill vllm-decode 2>/dev/null || true
docker rm vllm-prefill vllm-decode 2>/dev/null || true

# GPU 割当 (カンマ区切り ID) を生成
prefill_gpu_ids=$(seq -s, 0 $(( GPUS_PER_ROLE - 1 )))
decode_gpu_ids=$(seq -s, ${GPUS_PER_ROLE} $(( 2 * GPUS_PER_ROLE - 1 )))

# Prefill サーバー起動
echo "[INFO] Starting Prefill server (GPUs=${prefill_gpu_ids}, TP=${GPUS_PER_ROLE})..."
docker run -d \
  --name vllm-prefill \
  --runtime=nvidia \
  -e NVIDIA_VISIBLE_DEVICES=${prefill_gpu_ids} \
  -e PYTHONHASHSEED=123 \
  -e VLLM_USE_V1=1 \
  --network host \
  -v ${MODEL_PATH}:/model \
  -v ${CONFIG_DIR}:/configs \
  -e LMCACHE_CONFIG_FILE=/configs/lmcache-prefiller-rediss.yaml \
  -e VLLM_LOGGING_LEVEL=INFO \
  ${BASE_IMAGE} \
  --model /model \
  --tensor-parallel-size ${GPUS_PER_ROLE} \
  --port 8100 \
  --gpu-memory-utilization 0.85 \
  --max-model-len 8192 \
  --kv-transfer-config '{"kv_connector":"LMCacheConnectorV1","engine_id":"shared-prefill-decode-engine","kv_role":"kv_producer","kv_connector_extra_config":{"discard_partial_chunks":false}}'

echo "[OK] Prefill container started"
echo "[INFO] Waiting for Prefill server to load model (250s)..."
sleep 250

# Decode サーバー起動 (GPU 数が足りる場合のみ)
if [[ "${RUN_DECODE}" == "true" ]]; then
  echo "[INFO] Starting Decode server (GPUs=${decode_gpu_ids}, TP=${GPUS_PER_ROLE})..."
  docker run -d \
    --name vllm-decode \
    --runtime=nvidia \
    -e NVIDIA_VISIBLE_DEVICES=${decode_gpu_ids} \
    -e PYTHONHASHSEED=123 \
    -e VLLM_USE_V1=1 \
    --network host \
    -v ${MODEL_PATH}:/model \
    -v ${CONFIG_DIR}:/configs \
    -e LMCACHE_CONFIG_FILE=/configs/lmcache-decoder-rediss.yaml \
    -e VLLM_LOGGING_LEVEL=INFO \
    ${BASE_IMAGE} \
    --model /model \
    --tensor-parallel-size ${GPUS_PER_ROLE} \
    --port 8200 \
    --gpu-memory-utilization 0.85 \
    --max-model-len 8192 \
    --kv-transfer-config '{"kv_connector":"LMCacheConnectorV1","engine_id":"shared-prefill-decode-engine","kv_role":"kv_consumer","kv_connector_extra_config":{"discard_partial_chunks":false}}'

  echo "[OK] Decode container started"
  echo "[INFO] Waiting for Decode server to load model (250s)..."
  sleep 250
  PORTS=(8100 8200)
else
  echo "[INFO] Skipping Decode (GPUs insufficient). Only Prefill will run."
  PORTS=(8100)
fi

# ヘルスチェック
echo "[INFO] Checking server health..."
for port in "${PORTS[@]}"; do
  for i in {1..10}; do
    if curl -s -m 5 "http://localhost:${port}/health" > /dev/null 2>&1; then
      echo "[OK] Port ${port} responding"
      break
    elif [[ $i -eq 10 ]]; then
      echo "[WARNING] Port ${port} not responding after 10 attempts"
    else
      echo "[INFO] Port ${port} not ready, retrying... ($i/10)"
      sleep 10
    fi
  done
done

echo ""
echo "========================================"
echo "[OK] Servers started (rediss:// URL)"
echo "========================================"
echo "Prefill: http://localhost:8100"
if [[ "${RUN_DECODE}" == "true" ]]; then
  echo "Decode:  http://localhost:8200"
fi
echo ""
echo "Test inference on Prefill:"
echo "  curl -X POST http://localhost:8100/v1/completions -H 'Content-Type: application/json' -d '{\"model\": \"/model\", \"prompt\": \"Hello, how are you?\", \"max_tokens\": 50}'"
echo ""
echo "Verify ElastiCache keys (should be > 0 after inference):"
echo "  docker exec vllm-prefill python3 -c 'import redis; r=redis.Redis.from_url(\"rediss://${ELASTICACHE_ENDPOINT}:6379\", ssl_cert_reqs=None); print(\"Keys:\", r.dbsize())'"
echo ""
echo "Container status:"
docker ps --filter name=vllm
echo ""
echo "Job will run until manually canceled (scancel ${SLURM_JOB_ID:-JOBID})"

# サーバーを実行し続ける
echo "[INFO] Monitoring containers..."
while docker ps | grep -q vllm-prefill; do
  if [[ "${RUN_DECODE}" == "true" ]] && ! docker ps | grep -q vllm-decode; then
    echo "[WARNING] Decode container stopped"
    break
  fi
  sleep 30
done

echo "[WARNING] Container(s) stopped"
docker ps -a --filter name=vllm
