#!/bin/bash
set -e

echo "[runpod-ai] Starting gemma-4-E4B on port 8001..."
python -m vllm.entrypoints.openai.api_server \
  --model google/gemma-4-E4B-it \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.80 \
  --dtype bfloat16 \
  --enforce-eager \
  --served-model-name gemma-4-E4B \
  --api-key "${VLLM_API_KEY}" \
  --download-dir /workspace/.huggingface \
  --host 0.0.0.0 \
  --port 8001 &
GEMMA_PID=$!

echo "[runpod-ai] Waiting for gemma-4-E4B to be ready..."
until curl -sf http://localhost:8001/health >/dev/null 2>&1; do
  if ! kill -0 $GEMMA_PID 2>/dev/null; then
    echo "[runpod-ai] ERROR: gemma-4-E4B process died" && exit 1
  fi
  sleep 5
done
echo "[runpod-ai] gemma-4-E4B ready."

echo "[runpod-ai] Starting BAAI/bge-m3 on port 8002..."
python -m vllm.entrypoints.openai.api_server \
  --model BAAI/bge-m3 \
  --task embed \
  --gpu-memory-utilization 0.10 \
  --dtype bfloat16 \
  --enforce-eager \
  --served-model-name bge-m3 \
  --api-key "${VLLM_API_KEY}" \
  --download-dir /workspace/.huggingface \
  --host 0.0.0.0 \
  --port 8002 &
EMBED_PID=$!

echo "[runpod-ai] Waiting for bge-m3 to be ready..."
until curl -sf http://localhost:8002/health >/dev/null 2>&1; do
  if ! kill -0 $EMBED_PID 2>/dev/null; then
    echo "[runpod-ai] ERROR: bge-m3 process died" && exit 1
  fi
  sleep 5
done
echo "[runpod-ai] bge-m3 ready."

echo "[runpod-ai] Starting nginx on port 8000..."
nginx

echo "[runpod-ai] All services up. gemma=8001, bge-m3=8002, nginx=8000"
wait -n $GEMMA_PID $EMBED_PID
echo "[runpod-ai] ERROR: a vLLM process exited unexpectedly — restarting container"
exit 1
