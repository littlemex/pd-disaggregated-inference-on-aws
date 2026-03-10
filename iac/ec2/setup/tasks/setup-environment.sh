#!/bin/bash
set -e

echo "[01] Checking GPU availability..."
nvidia-smi
GPU_COUNT=$(nvidia-smi --list-gpus | wc -l)
echo "GPUs found: ${GPU_COUNT}"

echo "[02] Creating .env file..."
cat > /home/ubuntu/vllm-di/.env << EOF
MODEL_NAME=${MODEL_NAME}
TENSOR_PARALLEL_SIZE=${TENSOR_PARALLEL_SIZE}
VLLM_PORT=${VLLM_PORT}
EOF

echo "[03] Installing Docker Compose V2..."
if ! docker compose version > /dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin
else
    echo "Docker Compose already installed, skipping"
fi

echo "[04] Configuring NVIDIA Container Toolkit..."
if ! (test -f /etc/docker/daemon.json && grep -q nvidia /etc/docker/daemon.json); then
    distribution=$(. /etc/os-release; echo ${ID}${VERSION_ID})
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list" \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
else
    echo "NVIDIA Container Toolkit already configured, skipping"
fi

echo "[05] Testing Docker GPU access..."
docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi

echo "[06] Creating working directory..."
if [ ! -d /home/ubuntu/vllm-di ]; then
    mkdir -p /home/ubuntu/vllm-di
    chown ubuntu:ubuntu /home/ubuntu/vllm-di
else
    echo "Working directory already exists, skipping"
fi

echo "[OK] Environment setup completed"
