#!/bin/bash
set -e

# Strip surrounding quotes injected by RunPod template env serialization
VLLM_API_KEY="${VLLM_API_KEY//\"/}"
HF_TOKEN="${HF_TOKEN//\"/}"

echo "[runpod-ai] Starting gemma-4-26B-A4B-it on port 8000..."
exec python3 -m vllm.entrypoints.openai.api_server \
  --model google/gemma-4-26B-A4B-it \
  --max-model-len 40000 \
  --kv-cache-dtype fp8 \
  --gpu-memory-utilization 0.85 \
  --enable-auto-tool-choice \
  --reasoning-parser gemma4 \
  --default-chat-template-kwargs '{"enable_thinking": true}' \
  --tool-call-parser gemma4 \
  --async-scheduling \
  --language-model-only \
  --served-model-name gemma-4-26B-A4B \
  --api-key "${VLLM_API_KEY}" \
  --download-dir /workspace/.huggingface \
  --host 0.0.0.0 \
  --port 8000
