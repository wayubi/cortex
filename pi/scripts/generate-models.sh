#!/bin/sh
# Regenerate .pi/models.json from the Cortex gateway.
#
# Cortex exposes llama.cpp models at :8080/v1 and proxies Ollama at :11434.
# IDs containing "/" are raw Hugging Face cache entries; the slash-free
# aliases are the ones Pi should expose.
set -eu

CORTEX_URL="${CORTEX_URL:-http://cortex-openresty-1:8080}"
OLLAMA_URL="${OLLAMA_URL:-http://cortex-openresty-1:11434}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
if [ -n "${PI_MODELS_FILE:-}" ]; then
  OUT="$PI_MODELS_FILE"
elif [ -d "$SCRIPT_DIR/.pi" ]; then
  OUT="$SCRIPT_DIR/.pi/models.json"
else
  OUT="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json"
fi

mkdir -p "$(dirname "$OUT")"

llama_models=$(curl -sf --max-time 15 "$CORTEX_URL/v1/models" 2>/dev/null | jq -c '
  [ .data[]
    | select(.id | contains("/") | not)
    | select(.id | contains("#") | not)
    | .id as $id
    | ((.status.args // []) | index("--ctx-size")) as $i
    | (if $i then (.status.args[$i + 1] | tonumber? // 65536)
       elif .meta.n_ctx then .meta.n_ctx
       else 65536 end) as $ctx
    | (.architecture.input_modalities // []) as $modalities
    | {
        id: $id,
        contextWindow: $ctx,
        maxTokens: ([($ctx / 2 | floor), 32768] | min),
        input: (if ($modalities | any(. == "image"))
                then ["text", "image"]
                else ["text"] end)
      }
  ] | unique_by(.id)') || llama_models='[]'
if [ -z "$llama_models" ]; then
  llama_models='[]'
fi

ollama_models=$(
  curl -sf --max-time 15 "$OLLAMA_URL/api/tags" 2>/dev/null \
  | jq -r '.models[].name' \
  | while IFS= read -r name; do
      info=$(curl -sf --max-time 10 -X POST "$OLLAMA_URL/api/show" \
               -d "$(jq -cn --arg m "$name" '{model: $m}')" 2>/dev/null \
             | jq -c '{
                 ctx: ([.model_info // {} | to_entries[]
                       | select(.key | endswith(".context_length"))
                       | .value] | first // 65536),
                 vision: ((.capabilities // []) | any(. == "vision"))
               }' 2>/dev/null) || info=''
      [ -n "$info" ] || info='{"ctx":65536,"vision":false}'
      jq -cn --arg id "$name" --argjson info "$info" '
        { id: $id, contextWindow: $info.ctx,
          maxTokens: ([($info.ctx / 2 | floor), 32768] | min),
          input: (if $info.vision then ["text", "image"] else ["text"] end) }'
    done | jq -s 'unique_by(.id)'
) || ollama_models='[]'
if [ -z "$ollama_models" ]; then
  ollama_models='[]'
fi

[ "$llama_models" != "[]" ] || echo "warning: no Cortex llama.cpp models found" >&2
[ "$ollama_models" != "[]" ] || echo "warning: no Ollama models found" >&2

providers=$(jq -n \
  --argjson llama "$llama_models" \
  --argjson ollama "$ollama_models" \
  --arg cortex_url "$CORTEX_URL/v1" \
  --arg ollama_url "$OLLAMA_URL/v1" '
  {
    cortex: {
      baseUrl: $cortex_url,
      api: "openai-completions",
      apiKey: "cortex",
      models: $llama
    },
    ollama: {
      baseUrl: $ollama_url,
      api: "openai-completions",
      apiKey: "ollama",
      models: $ollama
    }
  }')

if [ -s "$OUT" ] && jq empty "$OUT" 2>/dev/null; then
  jq --argjson p "$providers" '.providers = ((.providers // {}) + $p)' "$OUT" > "$OUT.tmp"
  mv "$OUT.tmp" "$OUT"
else
  jq -n --argjson p "$providers" \
    '{ "$schema": "https://pi.dev/schemas/models.schema.json", providers: $p }' > "$OUT"
fi

printf 'Wrote %s (%s cortex, %s ollama models)\n' "$OUT" \
  "$(printf '%s' "$providers" | jq '.cortex.models | length')" \
  "$(printf '%s' "$providers" | jq '.ollama.models | length')"
