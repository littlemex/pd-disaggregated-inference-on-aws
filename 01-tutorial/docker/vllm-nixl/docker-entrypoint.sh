#!/bin/bash
set -euo pipefail

# --- Configuration ---
VLLM_ROLE="${VLLM_ROLE:-unified}"
MODEL="${MODEL:?MODEL environment variable is required}"
PORT="${PORT:-8000}"
TP_SIZE="${TP_SIZE:-1}"
ENABLE_LMCACHE="${ENABLE_LMCACHE:-false}"

echo "[INFO] vllm-nixl entrypoint"
echo "[INFO]   VLLM_ROLE=$VLLM_ROLE"
echo "[INFO]   MODEL=$MODEL"
echo "[INFO]   PORT=$PORT"
echo "[INFO]   TP_SIZE=$TP_SIZE"
echo "[INFO]   ENABLE_LMCACHE=$ENABLE_LMCACHE"

# --- Build vLLM arguments ---
VLLM_ARGS=(
    --model "$MODEL"
    --port "$PORT"
    --tensor-parallel-size "$TP_SIZE"
)

# Append any extra arguments passed via VLLM_EXTRA_ARGS
if [ -n "${VLLM_EXTRA_ARGS:-}" ]; then
    read -ra EXTRA_ARGS <<< "$VLLM_EXTRA_ARGS"
    VLLM_ARGS+=("${EXTRA_ARGS[@]}")
fi

# --- Role-specific configuration ---
case "$VLLM_ROLE" in
    unified)
        echo "[INFO] Starting vLLM in unified mode"
        ;;
    producer)
        KV_CONFIG_FILE="${KV_CONFIG_FILE:-/config/kv_producer.json}"
        if [ ! -f "$KV_CONFIG_FILE" ]; then
            echo "[ERROR] KV config file not found: $KV_CONFIG_FILE"
            exit 1
        fi
        KV_CONFIG=$(cat "$KV_CONFIG_FILE")
        echo "[INFO] Starting vLLM as producer (prefill)"
        echo "[INFO]   KV config: $KV_CONFIG_FILE"
        VLLM_ARGS+=(--kv-transfer-config "$KV_CONFIG")
        ;;
    consumer)
        KV_CONFIG_FILE="${KV_CONFIG_FILE:-/config/kv_consumer.json}"
        if [ ! -f "$KV_CONFIG_FILE" ]; then
            echo "[ERROR] KV config file not found: $KV_CONFIG_FILE"
            exit 1
        fi
        KV_CONFIG=$(cat "$KV_CONFIG_FILE")
        echo "[INFO] Starting vLLM as consumer (decode)"
        echo "[INFO]   KV config: $KV_CONFIG_FILE"
        VLLM_ARGS+=(--kv-transfer-config "$KV_CONFIG")
        ;;
    *)
        echo "[ERROR] Invalid VLLM_ROLE: $VLLM_ROLE (must be unified, producer, or consumer)"
        exit 1
        ;;
esac

# --- LMCache configuration ---
if [ "$ENABLE_LMCACHE" = "true" ]; then
    LMCACHE_CONFIG="${LMCACHE_CONFIG:-/config/lmcache.yaml}"
    if [ ! -f "$LMCACHE_CONFIG" ]; then
        echo "[ERROR] LMCache config file not found: $LMCACHE_CONFIG"
        exit 1
    fi
    echo "[INFO] LMCache enabled: $LMCACHE_CONFIG"
    VLLM_ARGS+=(--lmcache-config "$LMCACHE_CONFIG")
fi

echo "[INFO] Executing: vllm serve ${VLLM_ARGS[*]}"
exec vllm serve "${VLLM_ARGS[@]}"
