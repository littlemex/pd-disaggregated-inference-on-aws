#!/bin/bash
# Phase 1: PD 分離推論の統計的ベンチマーク
#
# 構成:
#   系列 A: vLLM 単体 (LMCache OFF, kv-transfer-config なし)
#   系列 B: vLLM + LMCache local_cpu のみ (remote_url なし)
#   系列 C: vLLM + LMCache + ElastiCache remote (rediss://)
#
# Workload: sharegpt / prefix_repetition / random
# Seed: 3 種 (1, 2, 3)
# Concurrency: 4 固定 (初回は sweep 省略、饱和点だけ確認)
#
# 合計 run 数: 3 系列 × 3 workload × 3 seed = 27 run
# 想定時間: ~90 分 (モデルロード 3 回含む)

#SBATCH --job-name=phase1-bench
#SBATCH --partition=compute-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=03:00:00
#SBATCH --output=/fsx/logs/phase1-bench-%j.out
#SBATCH --error=/fsx/logs/phase1-bench-%j.err
#SBATCH --exclusive

set -uo pipefail

MODEL_PATH="${MODEL_PATH:-/fsx/models/Llama-3.1-8B-Instruct}"
CONFIG_DIR="${CONFIG_DIR:-/fsx/configs}"
LOG_DIR="${LOG_DIR:-/fsx/logs/phase1}"
RESULT_DIR="${RESULT_DIR:-${LOG_DIR}/results}"
BASE_IMAGE="${BASE_IMAGE:-vllm/vllm-openai:latest}"
PORT=8100
NUM_PROMPTS="${NUM_PROMPTS:-100}"
NUM_WARMUPS="${NUM_WARMUPS:-20}"
CONCURRENCY="${CONCURRENCY:-4}"
SEEDS=(1 2 3)
WORKLOADS=(sharegpt prefix_repetition random)
SERIES=(A B C)

mkdir -p "${LOG_DIR}" "${RESULT_DIR}" "${CONFIG_DIR}"

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "========================================"
log "Phase 1 Benchmark Sweep"
log "  Series: ${SERIES[*]}"
log "  Workloads: ${WORKLOADS[*]}"
log "  Seeds: ${SEEDS[*]}"
log "  NUM_PROMPTS=${NUM_PROMPTS}, WARMUPS=${NUM_WARMUPS}, CONCURRENCY=${CONCURRENCY}"
log "========================================"

# ElastiCache 設定読み込み (系列 C でのみ使用)
if [[ -z "${ELASTICACHE_ENDPOINT:-}" ]]; then
    if [[ -f "${ELASTICACHE_ENV_FILE:-/fsx/elasticache_env_vars}" ]]; then
        source "${ELASTICACHE_ENV_FILE:-/fsx/elasticache_env_vars}"
    else
        log "[ERROR] ELASTICACHE_ENDPOINT が未設定で、env ファイルも見つかりません"
        log "        export ELASTICACHE_ENDPOINT=<endpoint> を設定してください"
        exit 1
    fi
fi
log "[INFO] ElastiCache endpoint: ${ELASTICACHE_ENDPOINT}"

# ShareGPT データセット配置先
DATASET_DIR="${DATASET_DIR:-/fsx/datasets}"
SHAREGPT_PATH="${DATASET_DIR}/ShareGPT_V3_unfiltered_cleaned_split.json"
if [[ ! -f "${SHAREGPT_PATH}" ]]; then
    log "[INFO] Downloading ShareGPT dataset..."
    mkdir -p "${DATASET_DIR}"
    wget -q -O "${SHAREGPT_PATH}" \
        https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json \
        || log "[WARN] ShareGPT download failed, sharegpt workload will be skipped"
fi
SHAREGPT_BASENAME="$(basename ${SHAREGPT_PATH})"

# ------------------------------------------------------------------
# 系列ごとに LMCache config を生成し、Prefill コンテナを起動
# ------------------------------------------------------------------
generate_config_and_start() {
    local series="$1"
    local config_file="${CONFIG_DIR}/lmcache-phase1-${series}.yaml"
    local kv_config=""
    local env_args=""

    log "----------------------------------------"
    log "Series ${series}: starting vLLM container"
    log "----------------------------------------"

    # 既存コンテナを停止
    docker stop vllm-phase1 2>/dev/null || true
    docker rm vllm-phase1 2>/dev/null || true

    case "${series}" in
        A)
            # LMCache OFF: kv-transfer-config なし
            kv_config=""
            env_args=""
            ;;
        B)
            # LMCache local_cpu のみ
            cat > "${config_file}" <<EOF
local_cpu: True
max_local_cpu_size: 5
chunk_size: 256
save_unfull_chunk: True
EOF
            kv_config='--kv-transfer-config {"kv_connector":"LMCacheConnectorV1","engine_id":"phase1-b","kv_role":"kv_producer","kv_connector_extra_config":{"discard_partial_chunks":false}}'
            env_args="-e LMCACHE_CONFIG_FILE=/configs/lmcache-phase1-${series}.yaml"
            ;;
        C)
            # LMCache + ElastiCache remote
            cat > "${config_file}" <<EOF
local_cpu: True
max_local_cpu_size: 5
remote_url: "rediss://${ELASTICACHE_ENDPOINT}:6379"
remote_serde: "naive"
chunk_size: 256
save_unfull_chunk: True
EOF
            kv_config='--kv-transfer-config {"kv_connector":"LMCacheConnectorV1","engine_id":"phase1-c","kv_role":"kv_producer","kv_connector_extra_config":{"discard_partial_chunks":false}}'
            env_args="-e LMCACHE_CONFIG_FILE=/configs/lmcache-phase1-${series}.yaml"
            ;;
    esac

    # docker run 用の配列で引数を組み立てる (JSON 内のスペースを保護)
    local docker_args=(
        run -d
        --name vllm-phase1
        --runtime=nvidia
        -e NVIDIA_VISIBLE_DEVICES=0
        -e PYTHONHASHSEED=123
        -e VLLM_USE_V1=1
        -e VLLM_LOGGING_LEVEL=INFO
        --network host
        -v "${MODEL_PATH}:/model"
        -v "${CONFIG_DIR}:/configs"
        -v "${RESULT_DIR}:/results"
        -v "${DATASET_DIR}:/datasets"
    )

    if [[ -n "${env_args}" ]]; then
        for arg in ${env_args}; do
            docker_args+=("${arg}")
        done
    fi

    docker_args+=(
        "${BASE_IMAGE}"
        --model /model
        --tensor-parallel-size 1
        --port "${PORT}"
        --gpu-memory-utilization 0.85
        --max-model-len 8192
    )

    if [[ "${series}" != "A" ]]; then
        # JSON をシングルアイテムとして渡す
        docker_args+=(--kv-transfer-config)
        case "${series}" in
            B) docker_args+=('{"kv_connector":"LMCacheConnectorV1","engine_id":"phase1-b","kv_role":"kv_producer","kv_connector_extra_config":{"discard_partial_chunks":false}}') ;;
            C) docker_args+=('{"kv_connector":"LMCacheConnectorV1","engine_id":"phase1-c","kv_role":"kv_producer","kv_connector_extra_config":{"discard_partial_chunks":false}}') ;;
        esac
    fi

    docker "${docker_args[@]}"

    # ヘルスチェック
    log "[INFO] Waiting for server to become ready..."
    local ok=false
    for i in $(seq 1 60); do
        if curl -sf -m 3 "http://localhost:${PORT}/health" >/dev/null 2>&1; then
            ok=true
            log "[OK] Server ready (attempt ${i})"
            break
        fi
        sleep 5
    done

    if [[ "${ok}" != "true" ]]; then
        log "[ERROR] Server did not become ready in 300s"
        docker logs vllm-phase1 2>&1 | tail -50
        return 1
    fi
}

# ------------------------------------------------------------------
# ベンチマーク実行 (vllm bench serve を docker exec 経由で)
# ------------------------------------------------------------------
run_bench() {
    local series="$1"
    local workload="$2"
    local seed="$3"
    local out_json="/results/${series}_${workload}_s${seed}.json"
    local host_json="${RESULT_DIR}/${series}_${workload}_s${seed}.json"

    if [[ -f "${host_json}" ]]; then
        log "[SKIP] ${series}/${workload}/seed=${seed} already done"
        return 0
    fi

    log "[RUN] series=${series} workload=${workload} seed=${seed}"

    local base_args=(
        vllm bench serve
        --backend vllm
        --model /model
        --served-model-name /model
        --host 127.0.0.1
        --port "${PORT}"
        --num-prompts "${NUM_PROMPTS}"
        --max-concurrency "${CONCURRENCY}"
        --seed "${seed}"
        --ignore-eos
        --save-result
        --result-dir /results
        --result-filename "${series}_${workload}_s${seed}.json"
    )

    local wl_args=()
    case "${workload}" in
        sharegpt)
            if [[ ! -f "${SHAREGPT_PATH}" ]]; then
                log "[SKIP] sharegpt dataset missing"
                return 0
            fi
            wl_args=(
                --dataset-name sharegpt
                --dataset-path "/datasets/${SHAREGPT_BASENAME}"
                --sharegpt-output-len 64
            )
            ;;
        prefix_repetition)
            wl_args=(
                --dataset-name prefix_repetition
                --prefix-repetition-prefix-len 512
                --prefix-repetition-suffix-len 128
                --prefix-repetition-num-prefixes 8
                --prefix-repetition-output-len 64
            )
            ;;
        random)
            wl_args=(
                --dataset-name random
                --random-input-len 256
                --random-output-len 64
            )
            ;;
    esac

    # warmup 分だけ先に実行 (NUM_WARMUPS)
    docker exec vllm-phase1 "${base_args[@]}" "${wl_args[@]}" \
        --num-prompts "${NUM_WARMUPS}" \
        --result-filename "WARMUP_${series}_${workload}_s${seed}.json" \
        2>&1 | tail -5

    # 本測定
    docker exec vllm-phase1 "${base_args[@]}" "${wl_args[@]}" 2>&1 | tail -30

    if [[ -f "${host_json}" ]]; then
        log "[OK] saved ${host_json}"
    else
        log "[WARN] result file not found for ${series}/${workload}/seed=${seed}"
    fi
}

# ------------------------------------------------------------------
# メインループ: 系列を外側、workload/seed を内側
# ------------------------------------------------------------------
for series in "${SERIES[@]}"; do
    if ! generate_config_and_start "${series}"; then
        log "[FATAL] Failed to start series ${series}, skipping"
        continue
    fi

    for workload in "${WORKLOADS[@]}"; do
        for seed in "${SEEDS[@]}"; do
            run_bench "${series}" "${workload}" "${seed}" || log "[WARN] run failed, continuing"
        done
    done

    # ElastiCache のキー数を記録 (series C のみ)
    if [[ "${series}" == "C" ]]; then
        docker exec vllm-phase1 python3 -c \
            "import redis, os; r=redis.Redis.from_url('rediss://${ELASTICACHE_ENDPOINT}:6379', ssl_cert_reqs=None); print('[SERIES-C-KEYS]', r.dbsize())" \
            2>&1 | tee -a "${LOG_DIR}/series-c-keys.txt"
    fi
done

# クリーンアップ
docker stop vllm-phase1 2>/dev/null || true
docker rm vllm-phase1 2>/dev/null || true

log "========================================"
log "Phase 1 Benchmark Sweep Complete"
log "Results: ${RESULT_DIR}"
log "========================================"
ls -la "${RESULT_DIR}"
