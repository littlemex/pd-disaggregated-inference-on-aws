#!/bin/bash
# Standard (non-PD) vLLM を 2 インスタンス並べて round-robin proxy を前段に置く。
#
# vLLM blog (moriio-kv-connector) の "Standard (2x TP4)" 構成と同じ思想で、
# PD disagg (Prefill TP=N + Decode TP=N, 総 2N GPU) とフェアに比較するための
# ベースライン。例: 4 GPU 機 (g7e.12xlarge, L4 x4) では TP_SIZE=2, INSTANCES=2
# にすれば Prefill TP=2 + Decode TP=2 と総 GPU 数 (4) が一致する。
#
# Usage:
#   sbatch --partition=<q> run_standard_2xtp.sh
#   sbatch --partition=<q> --export=ALL,TP_SIZE=2,INSTANCES=2 run_standard_2xtp.sh
#
# 変数:
#   MODEL_PATH       モデルディレクトリ (既定: /fsx/models/Llama-3.1-8B-Instruct)
#   BASE_IMAGE       vLLM docker イメージ (既定: vllm/vllm-openai:latest)
#   TP_SIZE          1 インスタンスあたりの TP (既定: 2)
#   INSTANCES        Standard インスタンス数 (既定: 2)
#   BASE_PORT        内部ポート起点 (既定: 18000)。instance i は BASE_PORT+i
#   FRONT_PORT       前段 proxy の listen ポート (既定: 8100)
#   DATASETS_DIR     /datasets にマウントしたいホストディレクトリ (任意)
#   RESULT_DIR       /results にマウントしたいホストディレクトリ (任意)
#   MODEL_LOAD_SLEEP モデルロード待ちの秒数 (既定: 250)
#
# 注意: SLURM ディレクティブは環境に強く依存するので最小限に留め、
#       パーティションは sbatch 引数 (--partition=...) で指定することを推奨。

#SBATCH --job-name=vllm-standard-2xtp
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
TP_SIZE="${TP_SIZE:-2}"
INSTANCES="${INSTANCES:-2}"
BASE_PORT="${BASE_PORT:-18000}"
FRONT_PORT="${FRONT_PORT:-8100}"
DATASETS_DIR="${DATASETS_DIR:-}"
RESULT_DIR="${RESULT_DIR:-}"
MODEL_LOAD_SLEEP="${MODEL_LOAD_SLEEP:-250}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXTRA_MOUNTS=()
if [[ -n "${DATASETS_DIR}" ]]; then
  EXTRA_MOUNTS+=(-v "${DATASETS_DIR}:/datasets")
fi
if [[ -n "${RESULT_DIR}" ]]; then
  mkdir -p "${RESULT_DIR}"
  EXTRA_MOUNTS+=(-v "${RESULT_DIR}:/results")
fi

echo "========================================"
echo "vLLM Standard (${INSTANCES}x TP${TP_SIZE}) with round-robin proxy"
echo "  MODEL_PATH=${MODEL_PATH}"
echo "  TP_SIZE=${TP_SIZE}"
echo "  INSTANCES=${INSTANCES}"
echo "  FRONT_PORT=${FRONT_PORT} (backends: ${BASE_PORT}..+)"
echo "========================================"

NUM_GPUS=$(nvidia-smi -L 2>/dev/null | wc -l)
echo "[INFO] Detected ${NUM_GPUS} GPU(s)"
REQUIRED=$(( TP_SIZE * INSTANCES ))
if (( NUM_GPUS < REQUIRED )); then
  echo "[ERROR] need ${REQUIRED} GPUs (TP_SIZE=${TP_SIZE} x INSTANCES=${INSTANCES}), only ${NUM_GPUS} available"
  exit 1
fi

# Docker image pull (無ければ)
if ! docker image inspect "${BASE_IMAGE}" > /dev/null 2>&1; then
  echo "[INFO] Pulling ${BASE_IMAGE}..."
  docker pull "${BASE_IMAGE}"
fi

# 既存コンテナ掃除 (Standard 名 + PD 名、混同防止)
echo "[INFO] Stopping old containers..."
docker stop vllm-standard vllm-prefill vllm-decode 2>/dev/null || true
docker rm   vllm-standard vllm-prefill vllm-decode 2>/dev/null || true
for i in $(seq 0 $(( INSTANCES - 1 ))); do
  name="vllm-standard-$((i+1))"
  docker stop "${name}" 2>/dev/null || true
  docker rm   "${name}" 2>/dev/null || true
done

# 各インスタンス起動 (GPU 割当は instance i -> [i*TP_SIZE .. (i+1)*TP_SIZE-1])
BACKEND_URLS=()
for i in $(seq 0 $(( INSTANCES - 1 ))); do
  port=$(( BASE_PORT + i ))
  gpu_start=$(( i * TP_SIZE ))
  gpu_end=$(( gpu_start + TP_SIZE - 1 ))
  gpu_ids=$(seq -s, "${gpu_start}" "${gpu_end}")
  name="vllm-standard-$((i+1))"

  echo "[INFO] Starting ${name} (GPUs=${gpu_ids}, TP=${TP_SIZE}, port=${port})..."
  docker run -d \
    --name "${name}" \
    --runtime=nvidia \
    -e NVIDIA_VISIBLE_DEVICES="${gpu_ids}" \
    -e PYTHONHASHSEED=123 \
    -e VLLM_USE_V1=1 \
    -e VLLM_LOGGING_LEVEL=INFO \
    --network host \
    -v "${MODEL_PATH}:/model" \
    ${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"} \
    "${BASE_IMAGE}" \
    --model /model \
    --tensor-parallel-size "${TP_SIZE}" \
    --port "${port}" \
    --gpu-memory-utilization 0.85 \
    --max-model-len 8192

  BACKEND_URLS+=("http://127.0.0.1:${port}")
done

echo "[INFO] Waiting for models to load (${MODEL_LOAD_SLEEP}s)..."
sleep "${MODEL_LOAD_SLEEP}"

# ヘルスチェック
for url in "${BACKEND_URLS[@]}"; do
  port="${url##*:}"
  for attempt in {1..10}; do
    if curl -s -m 5 "http://localhost:${port}/health" > /dev/null 2>&1; then
      echo "[OK] ${url} responding"
      break
    elif [[ ${attempt} -eq 10 ]]; then
      echo "[WARNING] ${url} not responding after 10 attempts"
    else
      sleep 10
    fi
  done
done

# Round-robin proxy を起動 (フォアグラウンドで監視)
PROXY_ARGS=(--listen "0.0.0.0:${FRONT_PORT}")
for url in "${BACKEND_URLS[@]}"; do
  PROXY_ARGS+=(--backend "${url}")
done

echo ""
echo "========================================"
echo "[OK] Standard ${INSTANCES}x TP${TP_SIZE} ready"
echo "  Front  : http://localhost:${FRONT_PORT}"
echo "  Backend: ${BACKEND_URLS[*]}"
echo "========================================"
docker ps --filter name=vllm-standard

RR_PROXY="${RR_PROXY:-${SCRIPT_DIR}/rr_proxy.py}"
if [[ ! -f "${RR_PROXY}" ]]; then
  RR_PROXY="/home/ubuntu/rr_proxy.py"
fi
echo "[INFO] Launching round-robin proxy (${RR_PROXY})..."
exec python3 "${RR_PROXY}" "${PROXY_ARGS[@]}"
