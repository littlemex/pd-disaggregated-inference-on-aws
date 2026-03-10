#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ssm_helper.sh"

# Parse arguments
MODE=""
CONFIG_FILE=""
TASK=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --mode)  MODE="$2"; shift 2 ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --task)  TASK="$2"; shift 2 ;;
        --logs)
            if [ ! -f /tmp/ssm-last-command.json ]; then
                error "No previous command found"
            fi
            CID=$(jq -r '.command_id' /tmp/ssm-last-command.json)
            IID=$(jq -r '.instance_id' /tmp/ssm-last-command.json)
            RGN=$(jq -r '.region' /tmp/ssm-last-command.json)
            echo "=== stdout ==="
            aws ssm get-command-invocation \
                --command-id "$CID" --instance-id "$IID" --region "$RGN" \
                --query "StandardOutputContent" --output text
            echo ""
            echo "=== stderr ==="
            aws ssm get-command-invocation \
                --command-id "$CID" --instance-id "$IID" --region "$RGN" \
                --query "StandardErrorContent" --output text
            exit 0
            ;;
        *) error "Unknown option: $1" ;;
    esac
done

[ -z "$MODE" ] && error "Mode not specified"
[ -z "$CONFIG_FILE" ] && error "Config file not specified"
[ ! -f "$CONFIG_FILE" ] && error "Config file not found: $CONFIG_FILE"

# Load config
source "$CONFIG_FILE"

# Write config to Parameter Store as JSON
PARAM_NAME="/vllm-di/${MODE}/config"
log "Writing config to Parameter Store: ${PARAM_NAME}"

CONFIG_JSON=$(jq -n \
    --arg s3_bucket "$S3_BUCKET" \
    --arg region "$AWS_REGION" \
    --arg model "${MODEL_NAME:-Qwen/Qwen2.5-7B-Instruct}" \
    --arg tp_size "${TENSOR_PARALLEL_SIZE:-1}" \
    --arg vllm_port "${VLLM_PORT:-8000}" \
    --arg ucx_tls "${UCX_TLS:-tcp,self,sm}" \
    --arg kv_device "${KV_BUFFER_DEVICE:-cpu}" \
    --arg kv_size "${KV_BUFFER_SIZE:-10000000000}" \
    --arg producer_port "${PRODUCER_PORT:-8100}" \
    --arg consumer_port "${CONSUMER_PORT:-8200}" \
    --arg proxy_port "${PROXY_PORT:-8000}" \
    '{
        s3_bucket: $s3_bucket,
        region: $region,
        model: $model,
        tp_size: $tp_size,
        vllm_port: $vllm_port,
        ucx_tls: $ucx_tls,
        kv_device: $kv_device,
        kv_size: $kv_size,
        producer_port: $producer_port,
        consumer_port: $consumer_port,
        proxy_port: $proxy_port
    }')

aws ssm put-parameter \
    --name "$PARAM_NAME" \
    --value "$CONFIG_JSON" \
    --type String \
    --overwrite \
    --region "$AWS_REGION"

success "Config written to Parameter Store"

# Determine target instances
if [ "$MODE" == "single" ]; then
    INSTANCES=("$INSTANCE_ID")
else
    INSTANCES=("$NODE1_INSTANCE_ID" "$NODE2_INSTANCE_ID")
fi

# If task specified, run it
if [ -n "$TASK" ]; then
    log "Running task: $TASK"
    TASK_SCRIPT="${SCRIPT_DIR}/tasks/${TASK}.sh"
    [ ! -f "$TASK_SCRIPT" ] && error "Task script not found: $TASK_SCRIPT"

    for INST_ID in "${INSTANCES[@]}"; do
        log "Running on $INST_ID..."
        ssm_run_script_with_param "$INST_ID" "$AWS_REGION" "$S3_BUCKET" "$TASK_SCRIPT" "$PARAM_NAME" 600
    done
    success "Task completed: $TASK"
    exit 0
fi

# Main deploy: upload Docker build context to S3
log "Uploading Docker build context to S3..."
DOCKER_BUILD_DIR="/work/data-science/pd-disaggregated-inference-on-aws/01-tutorial/docker/vllm-nixl"
aws s3 cp "${DOCKER_BUILD_DIR}/" "s3://${S3_BUCKET}/docker/vllm-nixl/" \
    --recursive --region "${AWS_REGION}" --quiet

success "Upload complete"

# Run setup
SETUP_SCRIPT="${SCRIPT_DIR}/tasks/setup-environment.sh"
if [ -f "$SETUP_SCRIPT" ]; then
    for INST_ID in "${INSTANCES[@]}"; do
        log "Setting up $INST_ID..."
        ssm_run_script_with_param "$INST_ID" "$AWS_REGION" "$S3_BUCKET" "$SETUP_SCRIPT" "$PARAM_NAME" 600
    done
fi

echo ""
echo "Next steps:"
echo "  ./deploy.sh --mode $MODE --config $CONFIG_FILE --task test-single-node-aggregated"
