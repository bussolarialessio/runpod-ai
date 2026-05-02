#!/bin/bash
set -e

# Strip surrounding quotes injected by RunPod template env serialization
VLLM_API_KEY="${VLLM_API_KEY//\"/}"
HF_TOKEN="${HF_TOKEN//\"/}"

echo "[runpod-ai] Starting gemma-4-E4B on port 8000..."
exec python3 -m vllm.entrypoints.openai.api_server \
  --model google/gemma-4-E4B-it \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.95 \
  --dtype bfloat16 \
  --enforce-eager \
  --served-model-name gemma-4-E4B \
  --api-key "${VLLM_API_KEY}" \
  --download-dir /workspace/.huggingface \
  --host 0.0.0.0 \
  --port 8000
