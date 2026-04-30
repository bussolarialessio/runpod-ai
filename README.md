# runpod-ai

Pod RunPod custom con due modelli vLLM — esposti come API privata OpenAI-compatible.

## Modelli

| Modello | Path proxy | Porta interna |
|---|---|---|
| `google/gemma-4-E4B-it` | `/ai/*` | 8001 |
| `BAAI/bge-m3` | `/embed/*` | 8002 |

Nginx esposto su porta 8000 smista: `/v1/embeddings` → bge-m3, tutto il resto → gemma.

## Stack

| Componente | Dettagli |
|---|---|
| **Base image** | `vllm/vllm-openai:gemma4` |
| **GPU** | NVIDIA RTX A4500 20GB |
| **VRAM** | gemma: 0.80 (16 GB) + bge-m3: 0.10 (2 GB) = ~18 GB |
| **Routing** | nginx porta 8000 → processi interni 8001/8002 |
| **Registry** | `ghcr.io/bussolarialessio/runpod-ai` |
| **Proxy** | Hetzner `46.224.11.206` — Caddy 2 + FastAPI sidecar |
| **URL pubblico** | `https://ai.bussolarialessio.me` |

## Architettura

```
Client
  │
  ▼
https://ai.bussolarialessio.me
  │
  ▼
Hetzner 46.224.11.206
├── Caddy 2 (TLS + Let's Encrypt)
└── FastAPI sidecar (vllm-proxy)
      ├── Verifica CLIENT_API_KEY
      ├── Inietta SYSTEM_PROMPT
      └── Swappa key → VLLM_API_KEY
              │
              ▼
      RunPod community cloud
      └── RTX A4500 20GB
          └── ghcr.io/bussolarialessio/runpod-ai
              ├── nginx :8000
              │   ├── /v1/embeddings → bge-m3 :8002
              │   └── /* → gemma :8001
              ├── vLLM gemma-4-E4B-it :8001
              └── vLLM BAAI/bge-m3 :8002
```

## ENV — Doppler progetto `gemma-llm`

```bash
doppler secrets download --no-file --format env --project gemma-llm --config prd > .env
```

| Variabile | Descrizione |
|---|---|
| `VLLM_API_KEY` | Bearer token interno proxy→vLLM |
| `GEMMA_API_KEY` | Bearer token client-facing |
| `RUNPOD_POD_ID` | ID pod RunPod attivo |
| `RUNPOD_API_KEY` | API key gestione RunPod |
| `HF_TOKEN` | HuggingFace token (gemma gated) |

## Endpoint

### Chat (gemma-4-E4B)

```bash
curl https://ai.bussolarialessio.me/v1/chat/completions \
  -H "Authorization: Bearer $GEMMA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-E4B","messages":[{"role":"user","content":"Ciao!"}],"max_tokens":200}'
```

### Embeddings (bge-m3)

```bash
curl https://ai.bussolarialessio.me/v1/embeddings \
  -H "Authorization: Bearer $GEMMA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"bge-m3","input":"testo da embeddare"}'
```

## Deploy pod

Vedi `INSTALLATION.md` per la procedura completa.

Image RunPod: `ghcr.io/bussolarialessio/runpod-ai:main`
ENV richiesti nel pod: `VLLM_API_KEY`, `HF_TOKEN`, `HF_HOME=/workspace/.huggingface`

## Comandi utili

```bash
# Verifica modelli
curl https://ai.bussolarialessio.me/v1/models \
  -H "Authorization: Bearer $GEMMA_API_KEY"

# Logs proxy Hetzner
ssh hetzner-proxy 'cd /opt/gemma && docker compose logs -f vllm-proxy'

# Stato pod RunPod
curl -s -X POST "https://api.runpod.io/graphql" \
  -H "Authorization: Bearer $(doppler secrets get RUNPOD_API_KEY --project gemma-llm --config prd --plain)" \
  -H "Content-Type: application/json" -H "User-Agent: Mozilla/5.0" \
  -d '{"query":"{myself{pods{id name desiredStatus runtime{uptimeInSeconds}}}}"}' \
  | python3 -m json.tool

# Aggiorna proxy dopo cambio pod
NEW_POD_ID="..."
ssh hetzner-proxy "cd /opt/gemma && sed -i 's|RUNPOD_POD_ID=.*|RUNPOD_POD_ID=${NEW_POD_ID}|' .env && docker compose up -d vllm-proxy"
for cfg in dev stg prd; do doppler secrets set RUNPOD_POD_ID="${NEW_POD_ID}" --project gemma-llm --config $cfg; done
```
