#!/bin/bash
set -e

# PARAM_NAME and AWS_REGION are injected by ssm_run_script_with_param
CONFIG=$(aws ssm get-parameter \
    --name "${PARAM_NAME}" \
    --region "${AWS_REGION}" \
    --query "Parameter.Value" \
    --output text)

S3_BUCKET=$(echo "$CONFIG" | jq -r '.s3_bucket')
MODEL=$(echo "$CONFIG" | jq -r '.model')
TP_SIZE=$(echo "$CONFIG" | jq -r '.tp_size')
VLLM_PORT=$(echo "$CONFIG" | jq -r '.vllm_port')

WORKDIR=/home/ubuntu/vllm-di

echo "[01] Downloading build context..."
mkdir -p ${WORKDIR}/docker/vllm-nixl
aws s3 cp "s3://${S3_BUCKET}/docker/vllm-nixl/" ${WORKDIR}/docker/vllm-nixl/ \
    --recursive --region "${AWS_REGION}"

echo "[02] Creating docker-compose.yml..."
cat > ${WORKDIR}/docker-compose.yml << EOF
services:
  vllm:
    build: ./docker/vllm-nixl
    image: vllm-nixl:latest
    environment:
      - VLLM_ROLE=unified
      - MODEL=${MODEL}
      - PORT=${VLLM_PORT}
      - TP_SIZE=${TP_SIZE}
    ports:
      - "${VLLM_PORT}:${VLLM_PORT}"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    volumes:
      - huggingface-cache:/root/.cache/huggingface

volumes:
  huggingface-cache:
EOF

echo "[03] Building Docker image..."
cd ${WORKDIR}
docker compose build

echo "[04] Starting vLLM..."
cd /home/ubuntu/vllm-di
docker compose down 2>/dev/null || true
docker compose up -d

echo "[05] Waiting for vLLM..."
COUNTER=0
while [ ${COUNTER} -lt 240 ]; do
    if curl -s "http://localhost:${VLLM_PORT}/health" > /dev/null 2>&1; then
        echo "vLLM is ready"
        break
    fi
    COUNTER=$((COUNTER + 1))
    echo "Waiting... (${COUNTER}/60)"
    sleep 5
done

echo "[06] Testing inference..."
curl -s -X POST "http://localhost:${VLLM_PORT}/v1/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"${MODEL}\", \"prompt\": \"Hello, \", \"max_tokens\": 10}"

echo ""
echo "[OK] Done"
