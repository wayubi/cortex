#!/bin/sh
# Shared model-discovery library for Cortex client generators.
#
# Sourced by generate-models-pi.sh (Pi) and generate-models-opencode.sh (OpenCode).
# The caller sets CORTEX_URL / OLLAMA_URL and calls models_main with a format.

# Merge new providers into an existing config. Earlier versions wrote the IDs
# cortex / ollama (Pi) and llama / ollama (OpenCode); those blocks are dropped
# when they point at this cortex and their replacement is being written now,
# so a model is not listed twice and a backend that returned nothing on this
# sync keeps its old block. A provider under one of those IDs that points
# anywhere else is the user's and stays.
MODELS_MERGE='.providers = ((.providers // {})
    | with_entries(select(
        (.key as $k | ["cortex", "ollama", "llama"] | index($k)) == null
        or ((.value.baseUrl // .value.settings.baseURL // "") as $u
            | ($u == $cortex_url and ($p | has("cortex-llama-cpp")))
              or ($u == $ollama_url and ($p | has("cortex-ollama")))
            | not)))
    + $p)'

# "Wrote ..." summary: the model count per provider, or "kept" for a provider
# left out because its source returned nothing.
MODELS_SUMMARY='[["cortex-llama-cpp", "llama.cpp"], ["cortex-ollama", "ollama"]]
    | map(.[0] as $k | .[1] as $n
          | if $p | has($k) then "\($p[$k].models | length) \($n)"
            else "\($n) list kept" end)
    | join(", ")'

models_fetch_url() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- -T 30 "$1"
    else
        return 1
    fi
}

models_fetch_post() {
    url=$1
    data=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 -X POST -H 'Content-Type: application/json' \
            -d "$data" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- -T 30 --header='Content-Type: application/json' \
            --post-data="$data" "$url"
    else
        return 1
    fi
}

models_init() {
    CORTEX_URL="${CORTEX_URL:-http://openresty:8080}"
    OLLAMA_URL="${OLLAMA_URL:-http://openresty:11434}"
    CORTEX_URL="${CORTEX_URL%/}"
    OLLAMA_URL="${OLLAMA_URL%/}"
    CORTEX_DEFAULT_CTX="${CORTEX_DEFAULT_CTX:-65536}"
    case "$CORTEX_DEFAULT_CTX" in
        ''|*[!0-9]*) CORTEX_DEFAULT_CTX=65536 ;;
    esac
    # The context Ollama gives a model whose Modelfile sets no num_ctx: its
    # OLLAMA_CONTEXT_LENGTH, or when that is unset its automatic VRAM-tier
    # default (logged at start as "vram-based default context"). 4096 is the
    # automatic default below 23 GiB of VRAM, Ollama's smallest tier, and what
    # cortex's Ollama logged on 2026-11-04 (11.6 GiB). Observed, not tuned.
    CORTEX_OLLAMA_CTX="${CORTEX_OLLAMA_CTX:-4096}"
    case "$CORTEX_OLLAMA_CTX" in
        ''|*[!0-9]*) CORTEX_OLLAMA_CTX=4096 ;;
    esac

    MODEL_META_FILE="${MODEL_META_FILE:-}"
    MODEL_META='{}'
    if [ -n "$MODEL_META_FILE" ] && [ -f "$MODEL_META_FILE" ]; then
        MODEL_META=$(cat "$MODEL_META_FILE")
        if [ -z "$MODEL_META" ] \
           || ! printf '%s' "$MODEL_META" | jq -e 'type == "object"' >/dev/null 2>&1; then
            echo "warning: invalid model metadata in $MODEL_META_FILE; ignoring" >&2
            MODEL_META='{}'
        fi
    fi
}

models_fetch_cortex() {
    body=$(models_fetch_url "$CORTEX_URL/v1/models" 2>/dev/null || true)
    if [ -z "$body" ]; then
        printf '[]'
        return 0
    fi

    printf '%s' "$body" | jq -c --argjson m "$MODEL_META" \
        --argjson default_ctx "$CORTEX_DEFAULT_CTX" '
      [ .data[]
        | select(.id | contains("/") | not)
        | select(.id | contains("#") | not)
        | .id as $id
        | ((($m[$id].context) // (.meta.n_ctx) // (
            ((.status.args // []) | index("--ctx-size")) as $i
            | if $i then (.status.args[$i + 1] | tonumber? // $default_ctx)
              else $default_ctx end
          )) | tonumber? // $default_ctx) as $ctx
        | ((.architecture.input_modalities // []) | any(. == "image")) as $vision
        | {
            id: $id,
            name: ($m[$id].name // $id),
            context: $ctx,
            output: (($m[$id].output) | tonumber? // null),
            # llama.cpp reports tool support (/props chat_template_caps) only for a
            # loaded model, and loading one here would switch the GPU, so it is
            # assumed (unverified) unless model-meta.json sets tool_call.
            tools: (if ((($m[$id] | objects | has("tool_call")) // false)) then $m[$id].tool_call else true end),
            vision: (if ((($m[$id] | objects | has("vision")) // false)) then $m[$id].vision else $vision end)
          }
      ] | unique_by(.id)' 2>/dev/null || printf '[]'
}

models_fetch_ollama() {
    body=$(models_fetch_url "$OLLAMA_URL/api/tags" 2>/dev/null || true)
    if [ -z "$body" ]; then
        printf '[]'
        return 0
    fi

    printf '%s' "$body" | jq -r '
        .models[]?
        | [.name, (.details.family // ""), (.details.parameter_size // "")]
        | @tsv' 2>/dev/null \
    | while IFS="$(printf '\t')" read -r name family params; do
        [ -n "$name" ] || continue
        display=$(jq -rn --arg name "$name" --arg family "$family" \
            --arg params "$params" '
            (if $family != "" then $family else ($name | split(":")[0]) end)
            + (if $params != "" then " " + $params else "" end)')
        info=$(models_fetch_post "$OLLAMA_URL/api/show" \
            "$(jq -cn --arg m "$name" '{model: $m}')" 2>/dev/null \
            | jq -c --argjson ollama_ctx "$CORTEX_OLLAMA_CTX" '
                # What Ollama serves, not what the model was trained for:
                # the Modelfile num_ctx if it sets one (/api/show lists it in
                # "parameters", one "key  value" line each), else Ollama'"'"'s
                # default, never more than the trained context_length.
                ([.model_info // {} | to_entries[]
                  | select(.key | endswith(".context_length")) | .value
                  | numbers] | first) as $train
                | ((.parameters // "") | split("\n")
                   | map(select(startswith("num_ctx "))
                         | split(" ") | map(select(. != "")) | .[1] | tonumber?)
                   | first) as $own
                | {
                    ctx: ([($own // $ollama_ctx), $train]
                          | map(select(type == "number" and . > 0)) | min | floor),
                    vision: ((.capabilities // []) | any(. == "vision")),
                    # Ollama derives "tools" from the model'"'"'s template or
                    # parser, and refuses a request with tools for a model
                    # without it.
                    tools: ((.capabilities // []) | any(. == "tools"))
                  }' 2>/dev/null) || info=''
        # /api/show failed: nothing is known, so no tools are offered (Ollama
        # would refuse them if the model lacks support) and no image input.
        [ -n "$info" ] || info=$(jq -cn --argjson ollama_ctx "$CORTEX_OLLAMA_CTX" \
            '{ctx: $ollama_ctx, vision: false, tools: false}')

        jq -cn --arg id "$name" --arg display "$display" --argjson info "$info" \
            --argjson m "$MODEL_META" --argjson default_ctx "$CORTEX_DEFAULT_CTX" '
          {
            id: $id,
            name: ($m[$id].name // $display),
            context: (($m[$id].context // $info.ctx) | tonumber? // $default_ctx),
            output: (($m[$id].output) | tonumber? // null),
            tools: (if ((($m[$id] | objects | has("tool_call")) // false)) then $m[$id].tool_call else $info.tools end),
            vision: (if ((($m[$id] | objects | has("vision")) // false)) then $m[$id].vision else $info.vision end)
          }'
    done | jq -s 'unique_by(.id)' 2>/dev/null || printf '[]'
}

# Output limit (Pi maxTokens, OpenCode limit.output), same rule for both:
# min(context/4, 16384), unless model-meta.json sets "output". Chosen on
# 2026-11-04 from one day of router logs (212 Pi replies on four 72K-160K
# thinking models: median 177-1723 tokens, all under 5K but one at 16,321),
# not measured as best. 16384 covers every reply seen; context/4 keeps three
# quarters of a small model's context for input. Replaces min(context/2, 32768)
# (Pi) and a flat 8192 (OpenCode), both carried over from older scripts.
# Re-check with more days of logs, and OpenCode traffic, before trusting it.

models_write_pi() {
    llama=$1
    ollama=$2
    OUT="${PI_MODELS_FILE:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json}"
    mkdir -p "$(dirname "$OUT")"

    providers=$(jq -n \
        --argjson llama "$llama" \
        --argjson ollama "$ollama" \
        --arg cortex_url "$CORTEX_URL/v1" \
        --arg ollama_url "$OLLAMA_URL/v1" '
        {
          "cortex-llama-cpp": {
            baseUrl: $cortex_url,
            api: "openai-completions",
            apiKey: "cortex",
            models: ($llama | map({
              id: .id,
              contextWindow: .context,
              maxTokens: (.output // ([((.context / 4) | floor), 16384] | min)),
              input: (if .vision then ["text", "image"] else ["text"] end)
            }))
          },
          "cortex-ollama": {
            baseUrl: $ollama_url,
            api: "openai-completions",
            apiKey: "ollama",
            models: ($ollama | map({
              id: .id,
              contextWindow: .context,
              maxTokens: (.output // ([((.context / 4) | floor), 16384] | min)),
              input: (if .vision then ["text", "image"] else ["text"] end)
            }))
          }
        }
        # A source that returned nothing (a backend still starting, or down)
        # is left out, so the merge keeps that provider'"'"'s existing block
        # instead of replacing it with an empty list.
        | with_entries(select(.value.models | length > 0))') || return 1

    if [ -s "$OUT" ] && jq empty "$OUT" 2>/dev/null; then
        jq --argjson p "$providers" \
            --arg cortex_url "$CORTEX_URL/v1" --arg ollama_url "$OLLAMA_URL/v1" \
            "$MODELS_MERGE" "$OUT" > "$OUT.tmp.$$" && mv "$OUT.tmp.$$" "$OUT"
    else
        jq -n --argjson p "$providers" \
            '{ "$schema": "https://pi.dev/schemas/models.schema.json", providers: $p }' \
            > "$OUT.tmp.$$" && mv "$OUT.tmp.$$" "$OUT"
    fi

    printf 'Wrote %s (%s)\n' "$OUT" \
        "$(jq -rn --argjson p "$providers" "$MODELS_SUMMARY")"
}

models_write_opencode() {
    llama=$1
    ollama=$2
    OUT="${OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json}"
    mkdir -p "$(dirname "$OUT")"

    providers=$(jq -n \
        --argjson llama "$llama" \
        --argjson ollama "$ollama" \
        --arg cortex_url "$CORTEX_URL/v1" \
        --arg ollama_url "$OLLAMA_URL/v1" '
        {
          "cortex-llama-cpp": {
            name: "cortex-llama-cpp",
            package: "@opencode/ai/providers/openai-compatible",
            settings: { baseURL: $cortex_url },
            models: ($llama | map({
              key: .id,
              value: {
                modelID: .id,
                name: .name,
                limit: {
                  context: .context,
                  output: (.output // ([((.context / 4) | floor), 16384] | min))
                },
                capabilities: {
                  tools: .tools,
                  input: (if .vision then ["text", "image"] else ["text"] end),
                  output: ["text"]
                }
              }
            }) | from_entries)
          },
          "cortex-ollama": {
            name: "cortex-ollama",
            package: "@opencode/ai/providers/openai-compatible",
            settings: { baseURL: $ollama_url },
            models: ($ollama | map({
              key: .id,
              value: {
                modelID: .id,
                name: .name,
                limit: {
                  context: .context,
                  output: (.output // ([((.context / 4) | floor), 16384] | min))
                },
                capabilities: {
                  tools: .tools,
                  input: (if .vision then ["text", "image"] else ["text"] end),
                  output: ["text"]
                }
              }
            }) | from_entries)
          }
        }
        # A source that returned nothing (a backend still starting, or down)
        # is left out, so the merge keeps that provider'"'"'s existing block
        # instead of replacing it with an empty list.
        | with_entries(select(.value.models | length > 0))') || return 1

    if [ -s "$OUT" ] && jq empty "$OUT" 2>/dev/null; then
        jq --argjson p "$providers" \
            --arg cortex_url "$CORTEX_URL/v1" --arg ollama_url "$OLLAMA_URL/v1" \
            "$MODELS_MERGE" "$OUT" > "$OUT.tmp.$$" && mv "$OUT.tmp.$$" "$OUT"
    else
        jq -n --argjson p "$providers" \
            '{ "$schema": "https://opencode.ai/config.json", providers: $p }' \
            > "$OUT.tmp.$$" && mv "$OUT.tmp.$$" "$OUT"
    fi

    printf 'Wrote %s (%s)\n' "$OUT" \
        "$(jq -rn --argjson p "$providers" "$MODELS_SUMMARY")"
}

models_main() {
    format=${1:-pi}

    if [ -z "${MODEL_META_FILE:-}" ]; then
        case "$format" in
            pi)
                if [ -n "${PI_MODELS_FILE:-}" ]; then
                    meta_dir=$(dirname "$PI_MODELS_FILE")
                else
                    meta_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
                fi
                ;;
            opencode)
                if [ -n "${OPENCODE_CONFIG:-}" ]; then
                    meta_dir=$(dirname "$OPENCODE_CONFIG")
                else
                    meta_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
                fi
                ;;
            *)
                meta_dir=""
                ;;
        esac
        if [ -n "$meta_dir" ] && [ -f "$meta_dir/model-meta.json" ]; then
            MODEL_META_FILE="$meta_dir/model-meta.json"
        fi
    fi

    models_init

    llama=$(models_fetch_cortex)
    ollama=$(models_fetch_ollama)

    printf '%s' "$llama" | jq -e 'type == "array"' >/dev/null 2>&1 || llama='[]'
    printf '%s' "$ollama" | jq -e 'type == "array"' >/dev/null 2>&1 || ollama='[]'

    if [ "$llama" = "[]" ] && [ "$ollama" = "[]" ]; then
        echo "error: no models returned by $CORTEX_URL or $OLLAMA_URL; leaving config unchanged" >&2
        return 1
    fi
    [ "$llama" != "[]" ] || echo "warning: no llama.cpp models found at $CORTEX_URL; keeping the existing list" >&2
    [ "$ollama" != "[]" ] || echo "warning: no Ollama models found at $OLLAMA_URL; keeping the existing list" >&2

    case "$format" in
        pi)       models_write_pi "$llama" "$ollama" ;;
        opencode) models_write_opencode "$llama" "$ollama" ;;
        *)
            echo "error: unknown model format: $format" >&2
            return 1
            ;;
    esac
}
