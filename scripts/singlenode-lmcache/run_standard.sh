#!/bin/bash
# Standard (non-PD) vLLM サーバー起動スクリプト
#
# 全 GPU を単一の vLLM サーバーに割り当て、LMCache なしで推論する。
# PD disaggregated モードとの goodput 比較 baseline として使用。
#
# 使い方:
#   sbatch --partition=g7e-queue run_standard.sh
#   sbatch --partition=g7e-queue --export=ALL,TP_SIZE=2 run_standard.sh  # TP 数を変更

#SBATCH --job-name=vllm-standard
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=04:00:00
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err
#SBATCH --exclusive

set -euo pipefail

MODEL_PATH="${MODEL_PATH:-/fsx/models/Llama-3.1-8B-Instruct}"
BASE_IMAGE="${BASE_IMAGE:-vllm/vllm-openai:latest}"
TP_SIZE="${TP_SIZE:-4}"           # g6.12xlarge は 4 GPU
PORT="${PORT:-8100}"
CONTAINER_NAME="${CONTAINER_NAME:-vllm-standard}"
# 既定では GPU 0..TP_SIZE-1 を使う。2xTP2 構成等で第 2 インスタンスを立てる時に上書き。
GPU_IDS="${GPU_IDS:-}"

# Optional bind mounts: 未設定ならマウントを追加しない (旧動作を維持)
DATASETS_DIR="${DATASETS_DIR:-}"
RESULT_DIR="${RESULT_DIR:-}"

EXTRA_MOUNTS=()
if [[ -n "${DATASETS_DIR}" ]]; then
  EXTRA_MOUNTS+=(-v "${DATASETS_DIR}:/datasets")
fi
if [[ -n "${RESULT_DIR}" ]]; then
  mkdir -p "${RESULT_DIR}"
  EXTRA_MOUNTS+=(-v "${RESULT_DIR}:/results")
fi

echo "========================================"
echo "vLLM Standard (non-PD) Server"
echo "  TP_SIZE=${TP_SIZE}"
echo "  PORT=${PORT}"
echo "========================================"

NUM_GPUS=$(nvidia-smi -L 2>/dev/null | wc -l)
echo "[INFO] Detected ${NUM_GPUS} GPU(s)"
if (( NUM_GPUS < TP_SIZE )); then
  echo "[ERROR] TP_SIZE=${TP_SIZE} requires at least ${TP_SIZE} GPUs, only ${NUM_GPUS} available"
  exit 1
fi

# Docker image pull (なければ)
echo "[INFO] Checking docker image: ${BASE_IMAGE}..."
if ! docker image inspect "${BASE_IMAGE}" > /dev/null 2>&1; then
  echo "[INFO] Pulling ${BASE_IMAGE}..."
  docker pull "${BASE_IMAGE}"
  echo "[OK] Pull complete"
else
  echo "[OK] Image already present"
fi

# 古いコンテナを停止・削除。
#   STOP_OTHERS=true (default): PD モード等と共存しないよう既知名を全て削除
#   STOP_OTHERS=false        : このスクリプトの ${CONTAINER_NAME} のみ再起動
STOP_OTHERS="${STOP_OTHERS:-true}"
echo "[INFO] Stopping old containers..."
if [[ "${STOP_OTHERS}" == "true" ]]; then
  docker stop vllm-standard vllm-prefill vllm-decode 2>/dev/null || true
  docker rm   vllm-standard vllm-prefill vllm-decode 2>/dev/null || true
else
  docker stop "${CONTAINER_NAME}" 2>/dev/null || true
  docker rm   "${CONTAINER_NAME}" 2>/dev/null || true
fi

if [[ -z "${GPU_IDS}" ]]; then
  GPU_IDS=$(seq -s, 0 $(( TP_SIZE - 1 )))
fi

echo "[INFO] Starting ${CONTAINER_NAME} (GPUs=${GPU_IDS}, TP=${TP_SIZE})..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  --runtime=nvidia \
  -e NVIDIA_VISIBLE_DEVICES=${GPU_IDS} \
  -e PYTHONHASHSEED=123 \
  -e VLLM_USE_V1=1 \
  -e VLLM_LOGGING_LEVEL=INFO \
  --network host \
  -v ${MODEL_PATH}:/model \
  ${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"} \
  ${BASE_IMAGE} \
  --model /model \
  --tensor-parallel-size ${TP_SIZE} \
  --port ${PORT} \
  --gpu-memory-utilization 0.85 \
  --max-model-len 8192

echo "[OK] Container started"
echo "[INFO] Waiting for server to load model (250s)..."
sleep 250

# ヘルスチェック
for i in {1..10}; do
  if curl -s -m 5 "http://localhost:${PORT}/health" > /dev/null 2>&1; then
    echo "[OK] Port ${PORT} responding"
    break
  elif [[ $i -eq 10 ]]; then
    echo "[WARNING] Port ${PORT} not responding"
  else
    echo "[INFO] Port ${PORT} not ready, retrying... ($i/10)"
    sleep 15
  fi
done

echo ""
echo "========================================"
echo "[OK] vLLM Standard server ready"
echo "========================================"
echo "Endpoint: http://localhost:${PORT}"
echo "Container: ${CONTAINER_NAME}"
echo ""
docker ps --filter name=vllm
echo ""
echo "Job will run until manually canceled (scancel ${SLURM_JOB_ID:-JOBID})"

# サーバーを実行し続ける
echo "[INFO] Monitoring container..."
while docker ps | grep -q "${CONTAINER_NAME}"; do
  sleep 30
done

echo "[WARNING] Container stopped"
docker ps -a --filter name=vllm
