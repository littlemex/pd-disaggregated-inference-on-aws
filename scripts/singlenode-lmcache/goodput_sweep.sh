#!/bin/bash
# Goodput sweep benchmark
#
# 前提 (MODE 別):
#   MODE=pd  : Prefill/Decode 2 サーバー (Decode 側にリクエストを送る)
#   MODE=std : Standard サーバー 1 本 (TP=N 単体でも 2xTP 構成の proxy 前段でも可)
#
# 使い方:
#   sbatch --partition=<q> --export=ALL,MODE=std goodput_sweep.sh
#   sbatch --partition=<q> --export=ALL,MODE=pd  goodput_sweep.sh
#
# SLO: TTFT<TTFT_SLO_MS (既定 1000ms), TPOT<TPOT_SLO_MS (既定 50ms)

#SBATCH --job-name=goodput-sweep
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=02:00:00
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err

set -uo pipefail

MODE="${MODE:-std}"                   # std or pd
MODEL_PATH="${MODEL_PATH:-/fsx/models/Llama-3.1-8B-Instruct}"
RESULT_DIR="${RESULT_DIR:-/fsx/logs/goodput}"
NUM_PROMPTS="${NUM_PROMPTS:-200}"
TTFT_SLO_MS="${TTFT_SLO_MS:-1000}"
TPOT_SLO_MS="${TPOT_SLO_MS:-50}"
DATASET_DIR="${DATASET_DIR:-/fsx/datasets}"

# BENCH_EXEC:
#   docker (既定): 指定コンテナの中で `vllm bench serve` を呼ぶ。
#                  コンテナに `/datasets`, `/results` がマウントされている前提。
#   host         : ホストの python -m vllm.entrypoints... を直接呼ぶ
#                  (別途 vllm がインストールされていること)。
BENCH_EXEC="${BENCH_EXEC:-docker}"
# BENCH_HOST / BENCH_PORT: サーバーのエンドポイント。MODE で既定値が決まるが上書き可。
BENCH_HOST="${BENCH_HOST:-127.0.0.1}"
BENCH_PORT_OVERRIDE="${BENCH_PORT:-}"
BENCH_CONTAINER_OVERRIDE="${BENCH_CONTAINER:-}"

# リクエストレート一覧 (req/s)
# 環境変数 RATES でスペース区切り指定可能 (例: RATES="0.5 1 2 4 8")
RATES_STR="${RATES:-0.5 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0}"
read -ra REQUEST_RATES <<< "${RATES_STR}"

# MODE に応じてコンテナ名とポートの既定を決定 (上書き可能)
case "${MODE}" in
    std)
        BENCH_CONTAINER="${BENCH_CONTAINER_OVERRIDE:-vllm-standard}"
        BENCH_PORT="${BENCH_PORT_OVERRIDE:-8100}"
        ;;
    std2)
        # Standard 2xTP2 round-robin proxy 構成 (フロントは :8100 proxy、コンテナは vllm-standard-1 で bench 実行)
        BENCH_CONTAINER="${BENCH_CONTAINER_OVERRIDE:-vllm-standard-1}"
        BENCH_PORT="${BENCH_PORT_OVERRIDE:-8100}"
        ;;
    pd)
        # PD モードでは Decode 側にリクエストを投げる
        # (Prefill 側で KV cache 書き込み、Decode 側で消費する想定)
        BENCH_CONTAINER="${BENCH_CONTAINER_OVERRIDE:-vllm-decode}"
        BENCH_PORT="${BENCH_PORT_OVERRIDE:-8200}"
        ;;
    *)
        echo "[ERROR] Invalid MODE: ${MODE} (use 'std', 'std2', or 'pd')"
        exit 1
        ;;
esac

mkdir -p "${RESULT_DIR}"

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

# ShareGPT データセット
SHAREGPT_PATH="${DATASET_DIR}/ShareGPT_V3_unfiltered_cleaned_split.json"
if [[ ! -f "${SHAREGPT_PATH}" ]]; then
    log "[INFO] Downloading ShareGPT dataset..."
    mkdir -p "${DATASET_DIR}"
    wget -q -O "${SHAREGPT_PATH}" \
        https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json
fi
SHAREGPT_BASENAME="$(basename ${SHAREGPT_PATH})"

log "========================================"
log "Goodput Sweep"
log "  MODE=${MODE}  BENCH_EXEC=${BENCH_EXEC}"
if [[ "${BENCH_EXEC}" == "docker" ]]; then
    log "  CONTAINER=${BENCH_CONTAINER} HOST=${BENCH_HOST} PORT=${BENCH_PORT}"
else
    log "  HOST=${BENCH_HOST} PORT=${BENCH_PORT}"
fi
log "  SLO: TTFT<${TTFT_SLO_MS}ms, TPOT<${TPOT_SLO_MS}ms"
log "  NUM_PROMPTS=${NUM_PROMPTS}"
log "  RATES: ${REQUEST_RATES[*]}"
log "========================================"

# BENCH_EXEC=docker の場合はコンテナ存在確認
if [[ "${BENCH_EXEC}" == "docker" ]]; then
    if ! docker ps --format '{{.Names}}' | grep -q "^${BENCH_CONTAINER}$"; then
        log "[ERROR] Container ${BENCH_CONTAINER} is not running"
        log "        事前にサーバーを起動してください (run_standard.sh / run_standard_2xtp.sh / run_disagg_*.sh)"
        exit 1
    fi
fi

# ベンチマーク実行
run_bench() {
    local rate="$1"
    local out_basename="${MODE}_rate${rate}.json"
    local out_file="${RESULT_DIR}/${out_basename}"

    if [[ -f "${out_file}" ]]; then
        log "[SKIP] rate=${rate} already done (${out_file})"
        return 0
    fi

    log "[RUN] MODE=${MODE} rate=${rate} req/s → ${BENCH_HOST}:${BENCH_PORT}"

    local bench_args=(
        --backend vllm
        --model /model
        --served-model-name /model
        --host "${BENCH_HOST}"
        --port "${BENCH_PORT}"
        --dataset-name sharegpt
        --sharegpt-output-len 512
        --num-prompts "${NUM_PROMPTS}"
        --request-rate "${rate}"
        --goodput "ttft:${TTFT_SLO_MS}" "tpot:${TPOT_SLO_MS}"
        --percentile-metrics ttft,tpot,itl
        --save-result
        --result-filename "${out_basename}"
    )

    if [[ "${BENCH_EXEC}" == "docker" ]]; then
        docker exec "${BENCH_CONTAINER}" vllm bench serve \
            "${bench_args[@]}" \
            --dataset-path "/datasets/${SHAREGPT_BASENAME}" \
            --result-dir /results \
            2>&1 | tail -20
    else
        # host 実行: データセット/結果のパスはホスト側を直接指定
        vllm bench serve \
            "${bench_args[@]}" \
            --dataset-path "${SHAREGPT_PATH}" \
            --result-dir "${RESULT_DIR}" \
            2>&1 | tail -20
    fi
}

log "--- Starting sweep ---"

for rate in "${REQUEST_RATES[@]}"; do
    run_bench "${rate}" || log "[WARN] rate=${rate} failed, continuing"
done

log "--- Sweep complete. Generating table... ---"

# 結果テーブル生成
python3 - << PYEOF
import json
import os

result_dir = "${RESULT_DIR}"
mode = "${MODE}"
rates = [$(IFS=,; echo "${REQUEST_RATES[*]}")]

print("")
print("=" * 70)
print(f"Goodput Results (MODE={mode})")
print(f"SLO: TTFT<${TTFT_SLO_MS}ms, TPOT<${TPOT_SLO_MS}ms")
print("=" * 70)
header = f"{'Rate':>8} {'Goodput':>10} {'Throughput':>12} {'P99 TTFT':>10} {'P99 TPOT':>10} {'SLO Hit':>8}"
print(header)
print(f"{'(req/s)':>8} {'(req/s)':>10} {'(tok/s)':>12} {'(ms)':>10} {'(ms)':>10} {'(%)':>8}")
print("-" * 70)

for rate in rates:
    fname = os.path.join(result_dir, f"{mode}_rate{rate}.json")
    if not os.path.exists(fname):
        print(f"{rate:>8.1f} {'N/A':>10} {'N/A':>12} {'N/A':>10} {'N/A':>10} {'N/A':>8}")
        continue
    with open(fname) as f:
        data = json.load(f)
    goodput = data.get("request_goodput")
    throughput = data.get("output_throughput")
    p99_ttft = data.get("p99_ttft_ms")
    p99_tpot = data.get("p99_tpot_ms")
    total = data.get("num_prompts") or ${NUM_PROMPTS}
    # goodput は good_completed / dur_s なので、SLO Hit 率は goodput / request_throughput から逆算
    req_tp = data.get("request_throughput", 0)
    slo_pct = (goodput / req_tp * 100) if (goodput is not None and req_tp > 0) else None

    def fmt(x, digits=2):
        return f"{x:.{digits}f}" if x is not None else "N/A"

    print(f"{rate:>8.1f} {fmt(goodput):>10} {fmt(throughput,1):>12} {fmt(p99_ttft,1):>10} {fmt(p99_tpot,1):>10} {fmt(slo_pct,1):>8}")

print("=" * 70)
PYEOF
