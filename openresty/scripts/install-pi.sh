#!/bin/sh
# Install the Pi coding agent and optional language toolkits.
#
# Usage:
#   install-pi.sh [flags]
#
#   --all          Pi plus every toolkit below
#   --models-only  Only install curl/jq and regenerate the Pi model list
#   --no-pi        Skip the Pi binary
#   --no-tools     Do not install any language toolkit
#   --no-models    Do not regenerate the model list
#   --ctx-size N   Context assumed for a model Cortex reports none for
#                  (default 65536)
#
# Toolkits:
#   --python  Python LSP, lint and format tools
#   --node    TypeScript/JavaScript/CSS/HTML tooling and pyright
#   --php     PHP CLI and Composer
#   --media   Image/audio processing (Pillow, ffmpeg, ...)
#   --pdf     PDF generation (Pandoc + LaTeX)
#   --tools   fd, ast-grep, ctags, difftastic, yq (Alpine), sqlite, shfmt, taplo,
#             gh, git-lfs, direnv, just, hyperfine, make/cmake/ninja/meson
#   --go      Go, gopls, golangci-lint (+ staticcheck, gofumpt, dlv)
#   --rust    rustup toolchain, rust-analyzer, rustfmt, clippy
#   --c       clangd, clang-tidy/format, cppcheck, gdb, valgrind
#   --ruby    Ruby, rubocop and ruby-lsp
#   --lua     Lua, lua-language-server, luacheck and stylua
#
#   --strict  Abort on the first failure (default: best-effort)
#   -h, --help
#
# No flags installs Pi and regenerates the model list from Cortex.
# Supports Debian/Ubuntu (apt) and Alpine (apk). Run as root.

set -u

AGENT_NAME="install-pi"
INSTALL_PI=true
INSTALL_MODELS=true
INSTALL_TOOLKITS=false
INSTALL_PYTHON=false
INSTALL_NODE=false
INSTALL_PHP=false
INSTALL_MEDIA=false
INSTALL_PDF=false
INSTALL_TOOLS=false
INSTALL_GO=false
INSTALL_RUST=false
INSTALL_C=false
INSTALL_RUBY=false
INSTALL_LUA=false
NO_TOOLKITS=false
NO_MODELS=false
STRICT=false
SELECTED=false

usage() {
    cat <<'EOF'
Install the Pi coding agent and optional language toolkits.

Usage:
  install-pi.sh [flags]

  --all          Pi plus every toolkit below
  --models-only  Only install curl/jq and regenerate the Pi model list
  --no-pi        Skip the Pi binary
  --no-tools     Do not install any language toolkit
  --no-models    Do not regenerate the model list
  --ctx-size N   Context assumed for a model Cortex reports none for
                 (default 65536)

Toolkits:
  --python  Python LSP, lint and format tools
  --node    TypeScript/JavaScript/CSS/HTML tooling and pyright
  --php     PHP CLI and Composer
  --media   Image/audio processing (Pillow, ffmpeg, ...)
  --pdf     PDF generation (Pandoc + LaTeX)
  --tools   fd, ast-grep, ctags, difftastic, yq (Alpine), sqlite, shfmt, taplo,
            gh, git-lfs, direnv, just, hyperfine, make/cmake/ninja/meson
  --go      Go, gopls, golangci-lint (+ staticcheck, gofumpt, dlv)
  --rust    rustup toolchain, rust-analyzer, rustfmt, clippy
  --c       clangd, clang-tidy/format, cppcheck, gdb, valgrind
  --ruby    Ruby, rubocop and ruby-lsp
  --lua     Lua, lua-language-server, luacheck and stylua

  --strict  Abort on the first failure (default: best-effort)
  -h, --help

No flags installs Pi and regenerates the model list from Cortex.
Supports Debian/Ubuntu (apt) and Alpine (apk). Run as root.
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
    esac
done

# Only a script run from a file has a directory of its own. Piped in
# (`curl URL | sh`), $0 is the shell, and dirname would give the current
# directory, whose *-common.sh files must not be sourced.
SCRIPT_DIR=""
case "$0" in
    sh|bash|dash|ash|-*|*/sh|*/bash|*/dash|*/ash) ;;
    *) [ -f "$0" ] && SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd) || SCRIPT_DIR="" ;;
esac

load_common() {
    if [ -n "${CORTEX_AGENT_COMMON:-}" ] && [ -f "$CORTEX_AGENT_COMMON" ]; then
        . "$CORTEX_AGENT_COMMON"
        return 0
    fi
    for p in /opt/cortex-scripts/agent-common.sh /usr/local/lib/cortex/agent-common.sh; do
        if [ -f "$p" ]; then
            . "$p"
            return 0
        fi
    done
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/agent-common.sh" ]; then
        . "$SCRIPT_DIR/agent-common.sh"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y --no-install-recommends curl ca-certificates >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --update-cache curl ca-certificates >/dev/null 2>&1
        fi
    fi
    tmp="${TMPDIR:-/tmp}/cortex-agent-common.$$.sh"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 "${CORTEX_URL:-http://openresty:8080}/agent-common.sh" -o "$tmp"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp" "${CORTEX_URL:-http://openresty:8080}/agent-common.sh"
    else
        echo "error: curl or wget is required" >&2
        exit 1
    fi
    if [ ! -s "$tmp" ]; then
        echo "error: could not fetch agent-common.sh from ${CORTEX_URL:-http://openresty:8080}" >&2
        rm -f "$tmp"
        exit 1
    fi
    . "$tmp"
    rm -f "$tmp"
}

CORTEX_URL="${CORTEX_URL:-http://openresty:8080}"
CORTEX_URL="${CORTEX_URL%/}"

load_common

while [ $# -gt 0 ]; do
    case "$1" in
        --all)
            SELECTED=true
            INSTALL_PI=true
            INSTALL_MODELS=true
            INSTALL_TOOLKITS=true
            INSTALL_PYTHON=true
            INSTALL_NODE=true
            INSTALL_PHP=true
            INSTALL_MEDIA=true
            INSTALL_PDF=true
            INSTALL_TOOLS=true
            INSTALL_GO=true
            INSTALL_RUST=true
            INSTALL_C=true
            INSTALL_RUBY=true
            INSTALL_LUA=true
            NO_TOOLKITS=false
            NO_MODELS=false
            ;;
        --models-only)
            SELECTED=true
            INSTALL_PI=false
            INSTALL_MODELS=true
            INSTALL_TOOLKITS=false
            ;;
        --no-pi)     SELECTED=true; INSTALL_PI=false ;;
        --no-tools)  SELECTED=true; NO_TOOLKITS=true ;;
        --no-models) SELECTED=true; NO_MODELS=true ;;
        --ctx-size)
            if [ $# -lt 2 ]; then
                echo "error: --ctx-size requires a value" >&2
                exit 1
            fi
            CORTEX_DEFAULT_CTX=$2
            SELECTED=true
            shift
            ;;
        --ctx-size=*)
            CORTEX_DEFAULT_CTX=${1#*=}
            SELECTED=true
            ;;
        -h|--help) usage; exit 0 ;;
        --strict) SELECTED=true; STRICT=true ;;
        *)
            if agent_parse_common_flag "$1"; then
                SELECTED=true
                INSTALL_TOOLKITS=true
            else
                echo "Unknown flag: $1" >&2
                echo "Run with --help for usage." >&2
                exit 1
            fi
            ;;
    esac
    shift
done

[ "$NO_TOOLKITS" = "true" ] && INSTALL_TOOLKITS=false
[ "$NO_MODELS" = "true" ] && INSTALL_MODELS=false
if [ "$SELECTED" = "false" ]; then
    INSTALL_PI=true
    INSTALL_MODELS=true
fi

agent_init

if [ "$INSTALL_PI" = "true" ] || [ "$INSTALL_TOOLKITS" = "true" ]; then
    agent_install_base
else
    $PKG_UPDATE
    agent_install_pkgs curl ca-certificates jq
fi

if [ "$INSTALL_TOOLKITS" = "true" ]; then
    agent_install_requested_toolkits
fi

install_model_helpers() {
    mkdir -p /usr/local/lib/cortex || { agent_fail "cannot create /usr/local/lib/cortex"; return 0; }
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/models-common.sh" ]; then
        cp "$SCRIPT_DIR/models-common.sh" /usr/local/lib/cortex/models-common.sh
    else
        agent_fetch "$CORTEX_URL/models-common.sh" /usr/local/lib/cortex/models-common.sh 2>/dev/null \
            || { agent_fail "could not fetch models-common.sh"; return 0; }
    fi
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/generate-models-pi.sh" ]; then
        cp "$SCRIPT_DIR/generate-models-pi.sh" /usr/local/lib/cortex/generate-models-pi.sh
    else
        agent_fetch "$CORTEX_URL/generate-models-pi.sh" /usr/local/lib/cortex/generate-models-pi.sh 2>/dev/null \
            || { agent_fail "could not fetch generate-models-pi.sh"; return 0; }
    fi
    chmod 755 /usr/local/lib/cortex/models-common.sh \
        /usr/local/lib/cortex/generate-models-pi.sh
    ln -sf /usr/local/lib/cortex/generate-models-pi.sh /usr/local/bin/generate-models-pi.sh
}

if [ "$INSTALL_PI" = "true" ]; then
    agent_step "Pi"
    if agent_ensure_node_npm; then
        PI_AGENT_VERSION="${PI_AGENT_VERSION:-latest}"
        npm install -g --prefix /usr/local --ignore-scripts --min-release-age=0 \
            --no-fund --no-audit --progress=false \
            "@earendil-works/pi-coding-agent@${PI_AGENT_VERSION}" >/dev/null 2>&1 \
            || agent_fail "Pi agent npm install failed"
    else
        agent_fail "Pi needs Node >= 22.19.0 + npm"
    fi
    if command -v pi >/dev/null 2>&1; then
        pi --version || true
    else
        agent_fail "Pi binary is not on PATH after install"
    fi
fi

if [ "$INSTALL_MODELS" = "true" ]; then
    install_model_helpers
    agent_step "Pi models"
    gen=""
    for p in /opt/cortex-scripts/generate-models-pi.sh /usr/local/bin/generate-models-pi.sh; do
        if [ -f "$p" ]; then
            gen="$p"
            break
        fi
    done
    if [ -z "$gen" ]; then
        agent_fail "generate-models-pi.sh not found"
    else
        CORTEX_URL="${CORTEX_URL:-http://openresty:8080}" \
        OLLAMA_URL="${OLLAMA_URL:-http://openresty:11434}" \
        CORTEX_DEFAULT_CTX="${CORTEX_DEFAULT_CTX:-65536}" \
        PI_MODELS_FILE="${PI_MODELS_FILE:-}" \
            "$gen" || agent_fail "model generation failed"
    fi
fi

agent_cleanup
agent_summary
