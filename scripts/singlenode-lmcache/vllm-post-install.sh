#!/bin/bash
# vLLM 環境のコンピュートノード向け post-install スクリプト
#
# 役割:
#   - GPU ノード判定（g5/g6/g7e/p* 系）
#   - docker daemon の起動待ち
#   - vLLM 公式 Docker イメージの pre-pull
#   - Hugging Face CLI のインストール（venv 内）
#   - /fsx 配下の必須ディレクトリを作成（models/configs/logs/jobs）
#
# 設計原則:
#   - 冪等性: 複数回実行しても副作用が増えない
#   - ElastiCache 非依存: /fsx/elasticache_env_vars の不在はノード起動失敗としない
#     ElastiCache はアプリケーションレイヤ（Slurm Job）の責務。
#   - Best-effort (docker pull / pip install): 失敗はログに残すがノード起動は成功させる
#   - Fail-fast (/fsx マウント): 致命欠陥はエラーで返す（120 秒待機後）
#   - IMDSv2 対応: ImdsSupport=v2.0 環境でもノード種別取得が成功する
#
# ParallelCluster での配置:
#   ComputeNode の CustomActions.OnNodeConfigured.Sequence に配置する。
#   docker/nccl の post-install が終わった後に実行されることを前提とする。

set -uo pipefail

LOG_FILE="${LOG_FILE:-/var/log/vllm-post-install.log}"
log() {
    local msg="[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [vllm-post-install] $*"
    echo "${msg}"
    if [[ -w "$(dirname "${LOG_FILE}")" ]]; then
        echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

fatal() {
    log "[FATAL] $*"
    exit 1
}

log "Starting vLLM post-install"

# ------------------------------------------------------------------
# ノードタイプ判定（IMDSv2 対応）
# ------------------------------------------------------------------
get_instance_type_via_imds() {
    local token
    token=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
        --max-time 5 2>/dev/null || echo "")
    if [[ -n "${token}" ]]; then
        curl -sS -H "X-aws-ec2-metadata-token: ${token}" \
            --max-time 5 \
            http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo ""
    else
        # IMDSv1 fallback (Imds.Secured=false の場合のみ成功)
        curl -sS --max-time 5 \
            http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo ""
    fi
}

NODE_TYPE="unknown"
if command -v ec2-metadata >/dev/null 2>&1; then
    NODE_TYPE=$(ec2-metadata --instance-type 2>/dev/null | awk '{print $2}')
fi
if [[ -z "${NODE_TYPE}" || "${NODE_TYPE}" == "unknown" ]]; then
    t=$(get_instance_type_via_imds)
    NODE_TYPE="${t:-unknown}"
fi
log "Node type: ${NODE_TYPE}"

# GPU ノード判定
IS_GPU_NODE=false
case "${NODE_TYPE}" in
    g5.*|g5d.*|g5dn.*) IS_GPU_NODE=true ;;
    g6.*|g6e.*|g6f.*) IS_GPU_NODE=true ;;
    g7e.*) IS_GPU_NODE=true ;;
    p3.*|p3dn.*) IS_GPU_NODE=true ;;
    p4d.*|p4de.*) IS_GPU_NODE=true ;;
    p5.*|p5e.*|p5en.*) IS_GPU_NODE=true ;;
    p6.*|p6e.*) IS_GPU_NODE=true ;;
    *)
        log "[INFO] Unrecognized instance type '${NODE_TYPE}', treating as non-GPU"
        ;;
esac

if [[ "${IS_GPU_NODE}" != "true" ]]; then
    log "Non-GPU node, skipping vLLM post-install"
    exit 0
fi

log "GPU node detected, proceeding with vLLM environment setup"

# ------------------------------------------------------------------
# docker daemon 起動待ち（最大 60 秒）
# docker/postinstall.sh 直後は daemon が立ち上がりきっていないことがある
# ------------------------------------------------------------------
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.11.0}"
if command -v docker >/dev/null 2>&1; then
    DOCKER_READY=false
    for i in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            DOCKER_READY=true
            break
        fi
        log "Waiting for docker daemon... (${i}/30)"
        sleep 2
    done

    if [[ "${DOCKER_READY}" == "true" ]]; then
        log "Pulling vLLM image: ${VLLM_IMAGE}"
        if docker pull "${VLLM_IMAGE}"; then
            log "[OK] Docker image pulled: ${VLLM_IMAGE}"
        else
            log "[WARN] Failed to pull ${VLLM_IMAGE} - can be retried at job time"
        fi
    else
        log "[WARN] docker daemon not ready within 60s - skipping pre-pull"
    fi
else
    log "[WARN] docker command not found - expected docker postinstall to run first"
fi

# ------------------------------------------------------------------
# Hugging Face CLI のインストール（専用 venv、system Python を汚染しない）
# ------------------------------------------------------------------
HF_VENV="${HF_VENV:-/opt/pd-di/venv}"
if command -v python3 >/dev/null 2>&1; then
    if [[ ! -d "${HF_VENV}" ]]; then
        log "Creating venv for huggingface tools at ${HF_VENV}"
        mkdir -p "$(dirname "${HF_VENV}")" 2>/dev/null || true
        python3 -m venv "${HF_VENV}" || log "[WARN] venv creation failed"
    fi
    if [[ -x "${HF_VENV}/bin/pip" ]]; then
        log "Installing huggingface_hub + hf-transfer in ${HF_VENV}"
        if "${HF_VENV}/bin/pip" install --upgrade --quiet \
            "huggingface_hub>=0.24,<2.0" \
            "hf-transfer>=0.1.9,<0.2"; then
            log "[OK] huggingface_hub installed"
        else
            log "[WARN] Failed to install huggingface_hub - can be retried at job time"
        fi
    fi
else
    log "[WARN] python3 not found - skipping huggingface_hub install"
fi

# ------------------------------------------------------------------
# /fsx マウント待機 + 必須ディレクトリ作成
# post-install 実行時点でのマウント race を吸収するために最大 120 秒待つ
# ------------------------------------------------------------------
FSX_ROOT="${FSX_ROOT:-/fsx}"
FSX_DIRS="${FSX_DIRS:-models configs logs jobs}"

wait_for_fsx() {
    local max_wait="${FSX_MOUNT_TIMEOUT:-300}"
    local waited=0
    while ! mountpoint -q "${FSX_ROOT}" 2>/dev/null; do
        if [[ ${waited} -ge ${max_wait} ]]; then
            return 1
        fi
        log "[INFO] Waiting for ${FSX_ROOT} to be mounted (${waited}s/${max_wait}s)"
        sleep 5
        waited=$((waited + 5))
    done
    return 0
}

if wait_for_fsx; then
    log "${FSX_ROOT} is mounted, creating required directories"
    for d in ${FSX_DIRS}; do
        if mkdir -p "${FSX_ROOT}/${d}"; then
            log "[OK] ${FSX_ROOT}/${d} ready"
        else
            log "[WARN] Failed to create ${FSX_ROOT}/${d}"
        fi
    done

    # ElastiCache 接続情報の存在確認（warn のみ、失敗させない）
    # 理由: クラスター基盤は ElastiCache 非依存でなければならない。
    #       ElastiCache 設定は Slurm Job 実行前にオペレーターが配置する。
    if [[ -f "${FSX_ROOT}/elasticache_env_vars" ]]; then
        log "[INFO] ${FSX_ROOT}/elasticache_env_vars exists"
    else
        log "[INFO] ${FSX_ROOT}/elasticache_env_vars not found. This is expected if ElastiCache has not been provisioned yet."
        log "[INFO] Before submitting Slurm jobs, write ELASTICACHE_ENDPOINT=<endpoint> to ${FSX_ROOT}/elasticache_env_vars"
    fi
else
    # FSx 未マウントは致命的。Slurm Job が /fsx/models 前提で動かない
    fatal "${FSX_ROOT} did not become mounted within ${FSX_MOUNT_TIMEOUT:-300}s"
fi

log "vLLM post-install finished"
