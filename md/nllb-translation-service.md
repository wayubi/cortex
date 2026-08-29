# NLLB Translation Service

GPU-accelerated translation service running inside the Cortex stack. Any Hugging Face translation model can be used — no config changes needed, just pass the model name in the request.

**Access:** `http://cortex-openresty-1:5002` (OpenResty proxies to the NLLB backend)
**Default model:** `facebook/nllb-200-3.3B` (3.3B params, ~6 GB VRAM)
**GPU:** Required. If another backend (llama-cpp, ollama) is using VRAM, the coordinator automatically unloads it before serving translation requests.

---

## Quick start

```bash
# Health check
curl http://cortex-openresty-1:5002/health

# Translate English → Pashto (uses default NLLB 3.3B)
curl -X POST http://cortex-openresty-1:5002/v1/translate \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello, how are you?", "tgt_lang": "pbt_Arab"}'

# Translate English → French with a specific model
curl -X POST http://cortex-openresty-1:5002/v1/translate \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello, how are you?", "model": "facebook/nllb-200-distilled-600M", "tgt_lang": "fra_Latn"}'
```

---

## API reference

### `POST /v1/translate`

Translate text using any Hugging Face translation model.

**Request body (JSON):**

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `text` | string | yes | — | Text to translate |
| `tgt_lang` | string | yes | — | Target language FLORES-200 code |
| `model` | string | no | `facebook/nllb-200-3.3B` | Hugging Face model name |
| `src_lang` | string | no | `eng_Latn` | Source language FLORES-200 code |
| `max_length` | int | no | `4096` | Max output tokens |

**Response:**

```json
{
  "translated": "کړیڅه ستونه ونکړئ؟"
}
```

**Model loading:** The first request for a given model downloads it from HuggingFace (~6 GB for the default 3.3B). Subsequent requests reuse the cached model. If a different model is requested, the previous model is evicted from VRAM automatically.

### `GET /v1/models`

List currently loaded translation models. Returns the same format as llama-cpp for coordinator compatibility.

```bash
curl http://cortex-openresty-1:5002/v1/models
```

```json
{
  "data": [
    {
      "id": "facebook/nllb-200-3.3B",
      "status": {"value": "loaded"}
    }
  ]
}
```

### `POST /v1/models/unload`

Unload model(s) to free VRAM. Used by the coordinator during backend switches.

```bash
curl -X POST "http://cortex-openresty-1:5002/v1/models/unload?name=facebook/nllb-200-3.3B"
```

**Parameters (query string):**

| Param | Required | Description |
|---|---|---|
| `name` | no | Model name to unload. If omitted, unloads all loaded models. |

**Response:**

```json
{
  "status": "unloaded",
  "model": "facebook/nllb-200-3.3B"
}
```

### `GET /health`

Service health check.

```bash
curl http://cortex-openresty-1:5002/health
```

```json
{
  "status": "ok",
  "gpu": true,
  "gpu_name": "NVIDIA GeForce RTX 3060",
  "loaded_models": ["facebook/nllb-200-3.3B"]
}
```

---

## Available models

All models support 200 languages via FLORES-200 codes.

| Model | Params | ~VRAM | Quality | Speed | When to use |
|---|---|---|---|---|---|
| `facebook/nllb-200-3.3B` | 3.3B | ~6 GB | Best | Slowest | Default — best quality |
| `facebook/nllb-200-1.3B` | 1.3B | ~3 GB | Good | Medium | When VRAM is tight |
| `facebook/nllb-200-distilled-1.3B` | 1.3B | ~3 GB | Good | Faster | Faster alternative to 1.3B |
| `facebook/nllb-200-distilled-600M` | 600M | ~1.5 GB | Decent | Fastest | Speed over quality |

Any Hugging Face model compatible with `AutoModelForSeq2SeqLM` works — including fine-tuned variants. Just pass the full model name in the `model` field.

---

## Language codes (FLORES-200)

Common codes:

| Language | Code |
|---|---|
| English | `eng_Latn` |
| Pashto | `pbt_Arab` |
| Dari | `fas_Arab` |
| Urdu | `urd_Arab` |
| Arabic | `arb_Arab` |
| French | `fra_Latn` |
| German | `deu_Latn` |
| Spanish | `spa_Latn` |
| Portuguese | `por_Latn` |
| Russian | `rus_Cyrl` |
| Chinese | `zho_Hans` |
| Japanese | `jpn_Jpan` |
| Korean | `kor_Hang` |
| Hindi | `hin_Deva` |
| Turkish | `tur_Latn` |

Full list: [FLORES-200 language codes](https://github.com/facebookresearch/flores/blob/main/flores200/README.md#languages-in-flores-200)

---

## VRAM management

The service runs inside the Cortex VRAM coordinator. On a single GPU:

1. **Only one backend active at a time** — if llama-cpp or ollama has a model loaded, the coordinator drains active requests and unloads it before switching to NLLB.
2. **Model eviction** — if a new translation model is requested while a different one is loaded, the old model is evicted from VRAM automatically.
3. **First request latency** — the initial request for a model includes download time (if not cached) + GPU load time. Subsequent requests are fast.

---

## Integration examples

### Python (stdlib only — no extra dependencies)

```python
import urllib.request
import json

NLLB_URL = "http://cortex-openresty-1:5002/v1/translate"

def translate(text, tgt_lang, model="facebook/nllb-200-3.3B",
              src_lang="eng_Latn", max_length=4096):
    payload = json.dumps({
        "text": text,
        "model": model,
        "src_lang": src_lang,
        "tgt_lang": tgt_lang,
        "max_length": max_length,
    }).encode()
    req = urllib.request.Request(
        NLLB_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read())["translated"]

# Usage
result = translate("Hello world", tgt_lang="pbt_Arab")
print(result)
```

### Python (requests)

```python
import requests

NLLB_URL = "http://cortex-openresty-1:5002/v1/translate"

resp = requests.post(NLLB_URL, json={
    "text": "The weather is nice today.",
    "tgt_lang": "fra_Latn",
})
print(resp.json()["translated"])
```

### curl

```bash
# Basic translation
curl -X POST http://cortex-openresty-1:5002/v1/translate \
  -H "Content-Type: application/json" \
  -d '{"text": "Good morning", "tgt_lang": "deu_Latn"}'

# With specific model
curl -X POST http://cortex-openresty-1:5002/v1/translate \
  -H "Content-Type: application/json" \
  -d '{"text": "Good morning", "model": "facebook/nllb-200-distilled-600M", "tgt_lang": "deu_Latn"}'

# Pashto translation
curl -X POST http://cortex-openresty-1:5002/v1/translate \
  -H "Content-Type: application/json" \
  -d '{"text": "Kabul is the capital of Afghanistan", "tgt_lang": "pbt_Arab"}'
```

---

## Troubleshooting

**First request is slow:**
Model downloads from HuggingFace on first use. The 3.3B model is ~6 GB. Check `docker logs -f cortex-nllb-1` for download progress.

**GPU out of memory:**
Use a smaller model (`facebook/nllb-200-distilled-600M` uses ~1.5 GB). The coordinator handles VRAM conflicts with other backends automatically.

**Connection refused:**
Ensure the service is running: `docker compose ps`. The NLLB container must be up and healthy before requests succeed. All requests go through `cortex-openresty-1`, not directly to the NLLB container.

**Model not found (404 on unload):**
The model name must match exactly what was loaded. Check loaded models: `curl http://cortex-openresty-1:5002/v1/models`.

---

## Architecture

```
Client → cortex-openresty-1:5002 → coordinator.lua → nllb:5002
                                                        ↓
                                              POST /v1/translate  (translate text)
                                              GET  /v1/models     (list loaded models)
                                              POST /v1/models/unload (free VRAM)
                                              GET  /health         (status check)
```

The client always connects to `cortex-openresty-1:5002`. OpenResty proxies through the coordinator, which manages VRAM. When a translation request arrives on port 5002, the coordinator:
1. Detects the backend switch (e.g., llama-cpp → nllb)
2. Drains active requests on the current backend (up to 600s)
3. Unloads the current backend's model from VRAM via its API
4. Forwards the request to the NLLB server
5. The NLLB server loads the requested model into the freed VRAM
