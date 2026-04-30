# runpod-ai

Self-hosted Gemma 4 E4B on RunPod GPU + Hetzner proxy, exposed as a private OpenAI-compatible API.

## Overview

This project runs Google's **Gemma 4 E4B** model on a RunPod RTX A4500 GPU via vLLM, fronted by a Hetzner proxy that handles TLS, Bearer token authentication, system prompt injection, and API key swapping.

Key properties:

- **OpenAI-compatible API** — drop-in for any client that speaks the OpenAI protocol
- **Multimodal** — text, images (JPEG/PNG), and video (MP4) via `/v1/chat/completions`
- **Private by design** — every request requires a Bearer token; unauthenticated requests get `401`
- **Thinking mode** — extended chain-of-thought reasoning
- **Tool calling** — native function calling support

## Architecture

```
Client
  │
  ▼
https://ai.bussolarialessio.me
  │
  ▼
Hetzner 46.224.11.206
├── Caddy 2 — TLS termination (Let's Encrypt)
└── FastAPI sidecar (vllm-proxy)
      ├── Validates CLIENT_API_KEY
      ├── Injects SYSTEM_PROMPT on /v1/chat/completions
      └── Swaps CLIENT_API_KEY → VLLM_API_KEY toward RunPod
              │
              ▼
      RunPod community cloud
      └── NVIDIA RTX A4500 20GB
          └── vLLM (vllm/vllm-openai:gemma4)
              └── google/gemma-4-E4B-it
```

## Stack

| Component | Details |
|---|---|
| Model | `google/gemma-4-E4B-it` — 4.5B effective params, Apache 2.0, released 2026-04-02 |
| Runtime | vLLM (`vllm/vllm-openai:gemma4`) |
| GPU | NVIDIA RTX A4500 20GB — RunPod community cloud |
| Proxy | Hetzner `46.224.11.206` — Caddy 2 + FastAPI sidecar |
| Secrets | Doppler — project `runpod-ai` |

## Connection Details

| Parameter | Value |
|---|---|
| **Base URL** | `https://ai.bussolarialessio.me` |
| **API Key** | `320acc1197521a9b74959f85518b5c6fefda8fb481afc8ca14857e7cc21ee6ad` |
| **Model name** | `gemma-4-E4B` |
| **Protocol** | OpenAI-compatible (`/v1/chat/completions`, `/v1/models`) |
| **Context window** | 8192 tokens (prompt + completion) |

## API — Quick Reference

| Endpoint | Method | Description |
|---|---|---|
| `/v1/models` | GET | List available models |
| `/v1/chat/completions` | POST | Chat completion — text, image, video |

---

## Usage Examples

### curl — text

```bash
curl https://ai.bussolarialessio.me/v1/chat/completions \
  -H "Authorization: Bearer 320acc1197521a9b74959f85518b5c6fefda8fb481afc8ca14857e7cc21ee6ad" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-E4B",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 200
  }'
```

### curl — image

```bash
IMG_B64=$(base64 -i photo.jpg | tr -d '\n')

curl https://ai.bussolarialessio.me/v1/chat/completions \
  -H "Authorization: Bearer 320acc1197521a9b74959f85518b5c6fefda8fb481afc8ca14857e7cc21ee6ad" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gemma-4-E4B\",
    \"messages\": [{\"role\": \"user\", \"content\": [
      {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/jpeg;base64,${IMG_B64}\"}},
      {\"type\": \"text\", \"text\": \"Describe this image in detail.\"}
    ]}],
    \"max_tokens\": 300
  }"
```

---

### Ruby

#### Setup

```ruby
# Gemfile
gem "ruby-openai"
```

```ruby
require "openai"

CLIENT = OpenAI::Client.new(
  access_token: "320acc1197521a9b74959f85518b5c6fefda8fb481afc8ca14857e7cc21ee6ad",
  uri_base:     "https://ai.bussolarialessio.me/v1/"
)
MODEL = "gemma-4-E4B"
```

#### Text chat

```ruby
response = CLIENT.chat(
  parameters: {
    model:    MODEL,
    messages: [{ role: "user", content: "Explain machine learning in simple terms." }],
    max_tokens: 300
  }
)
puts response.dig("choices", 0, "message", "content")
```

#### Multi-turn conversation

```ruby
messages = [
  { role: "system", content: "You are an expert Ruby on Rails engineer." },
  { role: "user",   content: "How do I write a complex ActiveRecord query?" }
]

response = CLIENT.chat(parameters: { model: MODEL, messages: messages, max_tokens: 500 })
reply = response.dig("choices", 0, "message", "content")

# Continue the conversation
messages << { role: "assistant", content: reply }
messages << { role: "user", content: "Can you show me an example with a JOIN?" }

response2 = CLIENT.chat(parameters: { model: MODEL, messages: messages, max_tokens: 500 })
puts response2.dig("choices", 0, "message", "content")
```

#### Image analysis

```ruby
require "base64"

def encode_image(path)
  ext  = File.extname(path).delete(".").downcase
  mime = ext == "jpg" ? "image/jpeg" : "image/#{ext}"
  "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
end

response = CLIENT.chat(
  parameters: {
    model:    MODEL,
    messages: [{
      role:    "user",
      content: [
        { type: "image_url", image_url: { url: encode_image("/path/to/photo.jpg") } },
        { type: "text", text: "Describe this image." }
      ]
    }],
    max_tokens: 400
  }
)
puts response.dig("choices", 0, "message", "content")
# ~323 prompt tokens per JPEG image
# AVIF must be converted to JPEG first: sips -s format jpeg in.avif --out out.jpg
```

#### Video analysis

```ruby
require "base64"

def encode_video(path)
  "data:video/mp4;base64,#{Base64.strict_encode64(File.binread(path))}"
end

response = CLIENT.chat(
  parameters: {
    model:    MODEL,
    messages: [{
      role:    "user",
      content: [
        { type: "video_url", video_url: { url: encode_video("/path/to/clip.mp4") } },
        { type: "text", text: "What happens in this video? Describe context and people." }
      ]
    }],
    max_tokens: 400
  }
)
puts response.dig("choices", 0, "message", "content")
# ~2400 prompt tokens per 1.8MB MP4 — keep videos under ~3MB
```

#### Streaming

```ruby
CLIENT.chat(
  parameters: {
    model:    MODEL,
    messages: [{ role: "user", content: "Write a short story." }],
    max_tokens: 500,
    stream:   proc { |chunk, _| print chunk.dig("choices", 0, "delta", "content") }
  }
)
```

#### Token usage

```ruby
response = CLIENT.chat(
  parameters: { model: MODEL, messages: [{ role: "user", content: "Hi" }], max_tokens: 50 }
)
u = response["usage"]
puts "prompt=#{u["prompt_tokens"]} completion=#{u["completion_tokens"]} total=#{u["total_tokens"]}"
```

#### Error handling

```ruby
begin
  response = CLIENT.chat(parameters: { model: MODEL, messages: messages, max_tokens: 300 })
  raise "API error: #{response.dig('error', 'message')}" if response["error"]
  response.dig("choices", 0, "message", "content")
rescue Faraday::TimeoutError
  # Pod cold start can take 60-120s — retry
  retry
rescue => e
  Rails.logger.error "Gemma API error: #{e.message}"
  raise
end
```

---

### Python

```python
from openai import OpenAI
import base64

client = OpenAI(
    base_url="https://ai.bussolarialessio.me/v1",
    api_key="320acc1197521a9b74959f85518b5c6fefda8fb481afc8ca14857e7cc21ee6ad",
)

# Text
response = client.chat.completions.create(
    model="gemma-4-E4B",
    messages=[{"role": "user", "content": "Hello!"}],
    max_tokens=200,
)
print(response.choices[0].message.content)

# Image
with open("photo.jpg", "rb") as f:
    img_b64 = base64.b64encode(f.read()).decode()

response = client.chat.completions.create(
    model="gemma-4-E4B",
    messages=[{"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{img_b64}"}},
        {"type": "text", "text": "Describe this image."},
    ]}],
    max_tokens=400,
)
print(response.choices[0].message.content)

# Video
with open("clip.mp4", "rb") as f:
    vid_b64 = base64.b64encode(f.read()).decode()

response = client.chat.completions.create(
    model="gemma-4-E4B",
    messages=[{"role": "user", "content": [
        {"type": "video_url", "video_url": {"url": f"data:video/mp4;base64,{vid_b64}"}},
        {"type": "text", "text": "What happens in this video?"},
    ]}],
    max_tokens=400,
)
print(response.choices[0].message.content)

# Streaming
stream = client.chat.completions.create(
    model="gemma-4-E4B",
    messages=[{"role": "user", "content": "Write a poem."}],
    max_tokens=300,
    stream=True,
)
for chunk in stream:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
```

---

### TypeScript

```typescript
import OpenAI from "openai";
import fs from "fs";

const client = new OpenAI({
  baseURL: "https://ai.bussolarialessio.me/v1",
  apiKey: "320acc1197521a9b74959f85518b5c6fefda8fb481afc8ca14857e7cc21ee6ad",
});

// Text
const response = await client.chat.completions.create({
  model: "gemma-4-E4B",
  messages: [{ role: "user", content: "Hello!" }],
  max_tokens: 200,
});
console.log(response.choices[0].message.content);

// Image
const imgB64 = fs.readFileSync("photo.jpg").toString("base64");
const imgResponse = await client.chat.completions.create({
  model: "gemma-4-E4B",
  messages: [{
    role: "user",
    content: [
      { type: "image_url", image_url: { url: `data:image/jpeg;base64,${imgB64}` } },
      { type: "text", text: "Describe this image." },
    ],
  }],
  max_tokens: 400,
});
console.log(imgResponse.choices[0].message.content);
```

---

## Token Reference

| Input | Prompt tokens |
|---|---|
| Short text (~5 words) | ~58 |
| Medium text (~20 words) | ~74 |
| Long text (~50 words) | ~109 |
| JPEG image | ~323 |
| MP4 video (1.8MB) | ~2458 |

**Context window: 8192 tokens** — prompt + completion combined.

---

## Request Parameters

| Parameter | Type | Notes |
|---|---|---|
| `model` | string | Must be `gemma-4-E4B` |
| `messages` | array | Standard OpenAI `role`/`content` format |
| `max_tokens` | int | Cap output length — required to avoid hitting context limit |
| `stream` | bool | `true` returns SSE stream |
| `temperature` | float | Default `0.7` |
| `top_p` | float | Nucleus sampling |
| `stop` | array | Stop sequences |

---

## Operations

### Check model ready

```bash
curl https://ai.bussolarialessio.me/v1/models \
  -H "Authorization: Bearer 320acc1197521a9b74959f85518b5c6fefda8fb481afc8ca14857e7cc21ee6ad"
```

### Check pod status

```bash
curl -s -X POST "https://api.runpod.io/graphql" \
  -H "Authorization: Bearer $(doppler secrets get RUNPOD_API_KEY --project runpod-ai --config prd --plain)" \
  -H "Content-Type: application/json" -H "User-Agent: Mozilla/5.0" \
  -d '{"query":"{myself{pods{id name desiredStatus runtime{uptimeInSeconds}}}}"}' \
  | python3 -m json.tool
```

### Proxy logs

```bash
ssh hetzner-proxy 'cd /opt/gemma && docker compose logs -f vllm-proxy'
```

### Update proxy when pod changes

```bash
NEW_POD_ID="..."
ssh hetzner-proxy "cd /opt/gemma && \
  sed -i 's|RUNPOD_POD_ID=.*|RUNPOD_POD_ID=${NEW_POD_ID}|' .env && \
  docker compose up -d vllm-proxy"

for cfg in dev stg prd; do
  doppler secrets set RUNPOD_POD_ID="${NEW_POD_ID}" --project runpod-ai --config $cfg
done
```

---

## Secrets — Doppler project `runpod-ai`

| Key | Description |
|---|---|
| `GEMMA_API_KEY` | Client-facing Bearer token |
| `VLLM_API_KEY` | Internal proxy→vLLM token |
| `GEMMA_API_URL` | `https://ai.bussolarialessio.me` |
| `RUNPOD_POD_ID` | Active RunPod pod ID |
| `RUNPOD_API_KEY` | RunPod management API key |
| `HF_TOKEN` | HuggingFace token (gated model access) |
| `LLM_MODEL_NAME` | `gemma-4-E4B` |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` | Wrong or missing Bearer token | Check key against Doppler `GEMMA_API_KEY` |
| `404` on all endpoints | Pod not yet ready (downloading model ~16GB) | Wait 5–10 min; check pod uptime via GraphQL |
| `502 Bad Gateway` | vLLM crashed or pod restarting | Check pod status; redeploy if needed |
| First request takes 60–120s | Pod was idle, model loading | Normal — subsequent requests are fast |
| `context length exceeded` | Prompt + completion > 8192 tokens | Reduce `max_tokens` or shorten prompt |
| AVIF image not recognized | vLLM doesn't support AVIF | Convert to JPEG: `sips -s format jpeg in.avif --out out.jpg` |

---

## vLLM Pod Config (RunPod)

```
Image:   vllm/vllm-openai:gemma4
GPU:     NVIDIA RTX A4500 20GB
Cloud:   Community

dockerArgs:
  google/gemma-4-E4B-it
  --max-model-len 8192
  --gpu-memory-utilization 0.85
  --dtype bfloat16
  --enforce-eager
  --served-model-name gemma-4-E4B
  --api-key <VLLM_API_KEY>
  --download-dir /workspace/.huggingface
  --host 0.0.0.0
  --port 8000

ENV:
  HF_TOKEN=<from Doppler>
  HF_HOME=/workspace/.huggingface

Container disk: 60GB
```

> **Note:** Do NOT add `--kv-cache-dtype fp8` — causes OOM crash on A4500 with Gemma 4 E4B.
