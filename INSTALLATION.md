# INSTALLATION — runpod-ai

Procedura completa per deployare il pod RunPod con gemma-4-E4B + bge-m3 e il proxy Hetzner.

## Prerequisites

| Requisito | Note |
|---|---|
| Account RunPod | Con metodo di pagamento attivo |
| Account Doppler | Progetto `runpod-ai` già configurato |
| VPS Hetzner | `46.224.11.206` — Ubuntu, Docker installato |
| Account HuggingFace | Con accesso approvato a `google/gemma-4-E4B-it` (modello gated) |
| DNS record | `ai.bussolarialessio.me A 46.224.11.206` |

> ⚠️ Il modello gemma è **gated** — richiedere accesso su HuggingFace prima di iniziare.

---

## Step 1 — Build e push Docker image

Il repo ha GitHub Actions che buildano automaticamente su push a `main`.
L'immagine viene pubblicata su GHCR come `ghcr.io/bussolarialessio/runpod-ai:main`.

Per buildare manualmente:

```bash
docker build -t ghcr.io/bussolarialessio/runpod-ai:main .
docker push ghcr.io/bussolarialessio/runpod-ai:main
```

> La prima build scarica l'immagine base `vllm/vllm-openai:gemma4` (~10GB).

---

## Step 2 — RunPod: deploy pod con image custom

1. Vai su [runpod.io](https://runpod.io) → **Deploy** → **GPU Pod**
2. Seleziona **Community Cloud**
3. Cerca GPU: `NVIDIA RTX A4500 20GB`
4. Configura:

**Container image:**
```
ghcr.io/bussolarialessio/runpod-ai:main
```

**Container disk:** `60 GB`

**Docker command (dockerArgs):** *(lasciare vuoto — start.sh gestisce tutto)*

**Environment variables:**
```
VLLM_API_KEY=<da Doppler: runpod-ai/prd VLLM_API_KEY>
HF_TOKEN=<da Doppler: runpod-ai/prd HF_TOKEN>
HF_HOME=/workspace/.huggingface
```

5. Deploy → attendere che il pod sia **Running**
6. Copia il **Pod ID**

**Aggiorna Pod ID su Doppler:**
```bash
NEW_POD_ID="<pod id copiato>"
for CFG in dev stg prd; do
  doppler secrets set RUNPOD_POD_ID="${NEW_POD_ID}" --project runpod-ai --config $CFG
done
```

Startup: nginx aspetta che entrambi i vLLM siano pronti.
Prima avvio scarica modelli (~16GB gemma + ~1GB bge-m3). **Attendi 10-15 minuti.**

---

## Step 3 — Hetzner: setup proxy (prima volta)

SSH sul server:
```bash
ssh hetzner-proxy
mkdir -p /opt/gemma/vllm-proxy
```

### docker-compose.yml

```bash
cat > /opt/gemma/docker-compose.yml << 'EOF'
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    env_file: .env
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - vllm-proxy

  vllm-proxy:
    build: ./vllm-proxy
    restart: unless-stopped
    environment:
      UPSTREAM_URL: https://${RUNPOD_POD_ID}-8000.proxy.runpod.net
      SYSTEM_PROMPT: "Rispondi sempre ed esclusivamente in italiano, con stile chiaro e naturale."
    env_file: .env
    expose:
      - "8001"

volumes:
  caddy_data:
  caddy_config:
EOF
```

### Caddyfile

```bash
cat > /opt/gemma/Caddyfile << 'EOF'
ai.bussolarialessio.me {
  encode zstd gzip

  @authorized header Authorization "Bearer {$CLIENT_API_KEY}"

  handle @authorized {
    request_header Authorization "Bearer {$VLLM_API_KEY}"
    reverse_proxy http://vllm-proxy:8001
  }

  handle {
    respond "unauthorized" 401
  }
}
EOF
```

### vllm-proxy/Dockerfile

```bash
cat > /opt/gemma/vllm-proxy/Dockerfile << 'EOF'
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi "uvicorn[standard]" httpx
COPY app.py .
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8001"]
EOF
```

### vllm-proxy/app.py

```bash
cat > /opt/gemma/vllm-proxy/app.py << 'EOF'
import os
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse
import httpx

UPSTREAM     = os.environ["UPSTREAM_URL"].rstrip("/")
SYSTEM       = os.environ["SYSTEM_PROMPT"]
PROXY_SECRET = os.environ["PROXY_SECRET"]

app = FastAPI()
client = httpx.AsyncClient(timeout=httpx.Timeout(300.0, connect=15.0))


def inject_system(body: dict) -> dict:
    msgs = body.get("messages") or []
    if msgs and msgs[0].get("role") == "system":
        msgs[0]["content"] = f"{SYSTEM}\n\n{msgs[0]['content']}"
    else:
        body["messages"] = [{"role": "system", "content": SYSTEM}, *msgs]
    return body


def upstream_headers(auth: str) -> dict:
    return {"Authorization": auth, "Content-Type": "application/json", "X-Proxy-Secret": PROXY_SECRET}


@app.post("/v1/chat/completions")
async def chat(request: Request):
    body = await request.json()
    body = inject_system(body)
    auth = request.headers.get("authorization", "")
    headers = upstream_headers(auth)
    if body.get("stream"):
        async def gen():
            async with client.stream("POST", f"{UPSTREAM}/v1/chat/completions",
                                     json=body, headers=headers) as r:
                async for chunk in r.aiter_raw():
                    yield chunk
        return StreamingResponse(gen(), media_type="text/event-stream")
    r = await client.post(f"{UPSTREAM}/v1/chat/completions", json=body, headers=headers)
    return Response(content=r.content, status_code=r.status_code,
                    media_type=r.headers.get("content-type", "application/json"))


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE"])
async def passthrough(path: str, request: Request):
    auth = request.headers.get("authorization", "")
    body = await request.body()
    headers = upstream_headers(auth)
    headers.pop("Content-Type", None)
    r = await client.request(request.method, f"{UPSTREAM}/{path}",
                             content=body, headers=headers,
                             params=dict(request.query_params))
    return Response(content=r.content, status_code=r.status_code,
                    media_type=r.headers.get("content-type", "application/json"))
EOF
```

### .env da Doppler

```bash
doppler secrets download --no-file --format env --project runpod-ai --config prd > /opt/gemma/.env
echo "CLIENT_API_KEY=$(grep GEMMA_API_KEY /opt/gemma/.env | cut -d= -f2)" >> /opt/gemma/.env
echo "PROXY_SECRET=$(openssl rand -hex 16)" >> /opt/gemma/.env
```

### Avvia

```bash
cd /opt/gemma && docker compose up -d --build
```

---

## Step 4 — Verifica

```bash
GEMMA_API_KEY=$(doppler secrets get GEMMA_API_KEY --project runpod-ai --config prd --plain)

# Modelli
curl https://ai.bussolarialessio.me/v1/models -H "Authorization: Bearer $GEMMA_API_KEY"

# Chat
curl https://ai.bussolarialessio.me/v1/chat/completions \
  -H "Authorization: Bearer $GEMMA_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-E4B","messages":[{"role":"user","content":"Ciao!"}],"max_tokens":50}'

# Embedding
curl https://ai.bussolarialessio.me/v1/embeddings \
  -H "Authorization: Bearer $GEMMA_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"bge-m3","input":"testo di test"}'
```

---

## Aggiornamento pod (cambio ID)

```bash
NEW_POD_ID="<nuovo pod id>"
ssh hetzner-proxy "cd /opt/gemma && \
  sed -i 's|RUNPOD_POD_ID=.*|RUNPOD_POD_ID=${NEW_POD_ID}|' .env && \
  docker compose up -d vllm-proxy"
for CFG in dev stg prd; do
  doppler secrets set RUNPOD_POD_ID="${NEW_POD_ID}" --project runpod-ai --config $CFG
done
```

---

## Troubleshooting

| Sintomo | Causa | Fix |
|---|---|---|
| `401 Unauthorized` | Token errato | Verifica `GEMMA_API_KEY` su Doppler |
| `404` su tutti gli endpoint | Pod in avvio (download ~17GB) | Attendi 10-15 min |
| `502 Bad Gateway` | vLLM crashato | Controlla stato pod RunPod |
| `/v1/embeddings` → 502 | bge-m3 non ancora pronto | Attendi 2-3 min in più |
| OOM crash al boot | VRAM insufficiente | Riduci `--gpu-memory-utilization` in `start.sh` |
| AVIF non riconosciuto | vLLM non supporta AVIF | `sips -s format jpeg in.avif --out out.jpg` |

> ⚠️ **NON aggiungere** `--kv-cache-dtype fp8` — causa OOM su A4500 con Gemma 4 E4B.
