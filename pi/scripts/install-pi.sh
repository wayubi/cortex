#!/bin/sh
# ------------------------------------------------------------------
# install-pi.sh — fetch from the cortex gateway:
#
#   curl -fsSL http://cortex-openresty-1/install-pi.sh | sh -s -- --python --tools
#
# Installs the pi-coding-agent into the current container and generates its
# .pi/models.json against the gateway's catalog. Pass flags for the toolkits
# that enhance agent understanding (LSP, lint, format), mirroring
# ../opencode/.opencode/scripts/install-opencode.sh:
#
#   --python    Python LSP + lint (ruff, mypy, pylint, pytest, ...)
#   --node      JS/TS/CSS/HTML LSP + lint + pyright
#   --php       PHP CLI + Composer
#   --media     Image/audio processing (Pillow, ffmpeg, ...)
#   --pdf       PDF generation (Pandoc + LaTeX)
#   --tools     cross-language agent essentials: fd, ast-grep, ctags,
#               difftastic, yq, sqlite, shfmt, taplo, gh, git-lfs, direnv,
#               just, hyperfine, make/cmake/ninja/meson, openssh-client
#   --go        Go + gopls + golangci-lint (+ staticcheck, gofumpt, dlv)
#   --rust      rustup toolchain + rust-analyzer, rustfmt, clippy
#   --c         clangd + clang-tidy/format, cppcheck, gdb, valgrind, build tools
#   --ruby      Ruby + rubocop + ruby-lsp
#   --lua       Lua + lua-language-server, luacheck, stylua
#
# Behaviour:
#   --no-agent    skip the pi-coding-agent binary installation
#   --models-only skip agent install, only (re)generate models.json
#   --strict      abort on the first failure (default: best-effort)
#   -h, --help    this help
#
# No flags = universal base + pi agent + generate-models.sh only.
#
# Best-effort by default: a package missing on this distro is logged and the
# run continues, ending in a summary. `--strict` restores abort-on-first-failure.
# Supports Debian/Ubuntu (apt) and Alpine (apk). Run as root.
# ------------------------------------------------------------------

set -u

# ------------------------------------------------------------------
# 1. Parse flags
# ------------------------------------------------------------------
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
INSTALL_AGENT=true
STRICT=false

usage() {
    # Print the header comment block (between the two rule lines), minus '# '.
    awk 'NR==1{next}
         /^# -{3,}/{n++; if(n==2) exit; next}
         {sub(/^# ?/,""); print}' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --python)      INSTALL_PYTHON=true ;;
        --node)        INSTALL_NODE=true ;;
        --php)         INSTALL_PHP=true ;;
        --media)       INSTALL_MEDIA=true ;;
        --pdf)         INSTALL_PDF=true ;;
        --tools)       INSTALL_TOOLS=true ;;
        --go)          INSTALL_GO=true ;;
        --rust)        INSTALL_RUST=true ;;
        --c)           INSTALL_C=true ;;
        --ruby)        INSTALL_RUBY=true ;;
        --lua)         INSTALL_LUA=true ;;
        --no-agent)    INSTALL_AGENT=false ;;
        --models-only) INSTALL_AGENT=false ;;
        --strict)      STRICT=true ;;
        -h|--help)     usage; exit 0 ;;
        *)
            echo "Unknown flag: $1" >&2
            echo "Usage: $0 [--python] [--node] [--php] [--media] [--pdf]" >&2
            echo "                [--tools] [--go] [--rust] [--c] [--ruby] [--lua]" >&2
            echo "                [--no-agent] [--models-only] [--strict]" >&2
            exit 1
            ;;
    esac
    shift
done

# ------------------------------------------------------------------
# 2. Preconditions
# ------------------------------------------------------------------
if [ "$(id -u)" != "0" ]; then
    echo "Error: must run as root (apk/apt install system packages)." >&2
    exit 1
fi

INSTALL_BUILD=false
$INSTALL_PYTHON && INSTALL_BUILD=true
$INSTALL_MEDIA && INSTALL_BUILD=true

# ------------------------------------------------------------------
# 3. Failure tracking (best-effort unless --strict)
# ------------------------------------------------------------------
FAILED=""
fail() {
    echo "  ! $*" >&2
    FAILED="${FAILED}$*
"
    if [ "$STRICT" = "true" ]; then
        echo "install-pi: aborting on first failure (--strict)" >&2
        exit 1
    fi
    return 0
}
step() { echo; echo "==> $*"; }

# ------------------------------------------------------------------
# 4. Detect distro and set package-manager variables
# ------------------------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
    PKG_UPDATE="apt-get update -qq"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="rm -rf /var/lib/apt/lists/*"
    PIP_BREAK_SYSTEM="--break-system-packages"
    IS_ALPINE=false
elif command -v apk >/dev/null 2>&1; then
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="rm -rf /var/cache/apk/*"
    PIP_BREAK_SYSTEM="--break-system-packages"
    IS_ALPINE=true
else
    echo "Error: No supported package manager (apt-get or apk)." >&2
    exit 1
fi

# ------------------------------------------------------------------
# 5. Best-effort install helpers
# ------------------------------------------------------------------
install_pkgs() {
    [ "$#" -eq 0 ] && return 0
    $PKG_INSTALL "$@" >/dev/null 2>&1 && return 0
    for p in "$@"; do
        $PKG_INSTALL "$p" >/dev/null 2>&1 || fail "unavailable: $p"
    done
    return 0
}

pip_install() {
    [ "$#" -eq 0 ] && return 0
    if ! command -v pip3 >/dev/null 2>&1; then
        if ${IS_ALPINE}; then install_pkgs python3 py3-pip
        else install_pkgs python3 python3-pip; fi
    fi
    # shellcheck disable=SC2086
    pip3 install --no-cache-dir $PIP_BREAK_SYSTEM -U "$@" >/dev/null 2>&1 && return 0
    for p in "$@"; do
        # shellcheck disable=SC2086
        pip3 install --no-cache-dir $PIP_BREAK_SYSTEM -U "$p" >/dev/null 2>&1 \
            || fail "unavailable: $p (pip)"
    done
    return 0
}

npm_install() {
    [ "$#" -eq 0 ] && return 0
    npm install -g --no-fund --no-audit "$@" >/dev/null 2>&1 && return 0
    for p in "$@"; do
        npm install -g --no-fund --no-audit "$p" >/dev/null 2>&1 \
            || fail "unavailable: $p (npm)"
    done
    return 0
}

gem_install() {
    for p in "$@"; do
        gem install --no-document "$p" >/dev/null 2>&1 \
            || fail "unavailable: $p (gem)"
    done
    return 0
}

# node_at_least MAJOR MINOR PATCH: return 0 if the current node >= that version.
node_at_least() {
    node_ver=$(node -v 2>/dev/null | sed 's/^v//' || true)
    [ -z "$node_ver" ] && return 1
    node_major=${node_ver%%.*}
    node_rest=${node_ver#*.}
    node_minor=${node_rest%%.*}
    node_rest=${node_rest#*.}
    node_patch=${node_rest%%.*}
    if [ "$node_major" -gt "$1" ]; then
        return 0
    elif [ "$node_major" -eq "$1" ]; then
        if [ "$node_minor" -gt "$2" ]; then
            return 0
        elif [ "$node_minor" -eq "$2" ]; then
            [ "$node_patch" -ge "$3" ] && return 0
        fi
    fi
    return 1
}

# ensure_node_npm: return 0 if Node >= 22.19.0 + npm are already usable.
# Otherwise provision a *standalone* Node.js 22.x binary (bundles npm) — no
# apt/apk node/npm package is assumed — extract under /usr/local, symlink
# node/npm/npx into /usr/local/bin (the default on-PATH location), then
# return 0 if node + npm are usable. Non-interactive, never runs pi. Best-
# effort: returns 1 if the binary can't be downloaded/installed, so the agent
# install is skipped but models.json is still generated. Requires: curl, tar,
# xz (xz auto-provisioned), and write access to /usr/local.
ensure_node_npm() {
    if command -v node >/dev/null 2>&1 && node_at_least 22 19 0 && command -v npm >/dev/null 2>&1; then
        return 0
    fi

    node_platform=$(case "$(uname -s)" in
        Linux)  printf 'linux'  ;;
        Darwin) printf 'darwin' ;;
        *)      return 1 ;;
    esac)
    node_arch=$(case "$(uname -m)" in
        x86_64|amd64)  printf 'x64'   ;;
        arm64|aarch64) printf 'arm64' ;;
        *)            return 1 ;;
    esac)

    node_dist_base="https://nodejs.org/dist/latest-v22.x"
    node_base_dir="/usr/local"
    node_tmp_dir="${TMPDIR:-/tmp}/pi-node.$$"
    rm -rf "$node_tmp_dir"
    mkdir -p "$node_tmp_dir" || return 1

    # xz is required to unpack the .tar.xz; provision it best-effort.
    if ! command -v xz >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y --no-install-recommends xz-utils >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --update-cache xz >/dev/null 2>&1
        fi
        command -v xz >/dev/null 2>&1 || return 1
    fi

    # Resolve the exact binary name from the dist checksum file.
    curl -fsSL "$node_dist_base/SHASUMS256.txt" -o "$node_tmp_dir/SHASUMS256.txt" \
        || return 1
    node_file=$(awk -v suffix="-$node_platform-$node_arch.tar.xz" \
        'index($2, "node-v") == 1 && length($2) >= length(suffix) && \
         substr($2, length($2) - length(suffix) + 1) == suffix { print $2; exit }' \
        "$node_tmp_dir/SHASUMS256.txt")
    [ -n "$node_file" ] || return 1

    curl -fsSL "$node_dist_base/$node_file" -o "$node_tmp_dir/$node_file" \
        || return 1

    # Verify the download checksum.
    awk -v file="$node_file" '$2 == file { print }' "$node_tmp_dir/SHASUMS256.txt" \
        > "$node_tmp_dir/SHASUMS256.selected"
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$node_tmp_dir" && sha256sum -c SHASUMS256.selected) >/dev/null 2>&1 \
            || return 1
    elif command -v shasum >/dev/null 2>&1; then
        (cd "$node_tmp_dir" && shasum -a 256 -c SHASUMS256.selected) >/dev/null 2>&1 \
            || return 1
    fi

    node_dir="$node_base_dir/${node_file%.tar.xz}"
    rm -rf "$node_dir"
    tar -xf "$node_tmp_dir/$node_file" -C "$node_base_dir" || return 1
    rm -rf "$node_tmp_dir"

    # Put node/npm/npx on the default PATH so the current (and future)
    # shells find them without any PATH export.
    for bin in node npm npx; do
        ln -sfn "$node_dir/bin/$bin" "$node_base_dir/bin/$bin" 2>/dev/null
    done

    command -v node >/dev/null 2>&1 && node_at_least 22 19 0 && command -v npm >/dev/null 2>&1
}

# ------------------------------------------------------------------
# 6. Update the package index (best-effort: installs will fail loudly if it did not)
# ------------------------------------------------------------------
$PKG_UPDATE

# ------------------------------------------------------------------
# 7. Universal packages — always installed
# ------------------------------------------------------------------
step "universal base"
if ${IS_ALPINE}; then
    install_pkgs bash
fi
install_pkgs \
    curl ca-certificates git unzip tar jq ripgrep less procps openssh-client

# ------------------------------------------------------------------
# 8. C/C++ build toolchain (transitive dep for --python, --media)
# ------------------------------------------------------------------
if $INSTALL_BUILD; then
    step "C build toolchain"
    if ${IS_ALPINE}; then
        install_pkgs build-base pkgconf libjpeg-turbo-dev zlib-dev libpng-dev
    else
        install_pkgs build-essential pkg-config libjpeg-dev zlib1g-dev libpng-dev
    fi
fi

# ------------------------------------------------------------------
# 9. Python tooling (LSP, lint, format)
# ------------------------------------------------------------------
if $INSTALL_PYTHON; then
    step "Python tooling"
    if ${IS_ALPINE}; then
        install_pkgs python3 py3-pip python3-dev py3-pytest
    else
        install_pkgs python3 python3-pip python3-venv python3-dev python3-pytest
    fi
    pip_install \
        python-lsp-server pylsp-mypy python-lsp-black pyls-isort \
        pylint mypy ruff black isort yamllint \
        vulture codespell coverage
fi

# ------------------------------------------------------------------
# 10. Node / TS tooling (LSP, lint, format, pyright)
# ------------------------------------------------------------------
if $INSTALL_NODE; then
    step "Node tooling"
    ensure_node_npm || fail "Node >= 22.19.0 + npm unavailable for Node tooling"
    npm_install \
        typescript eslint prettier @typescript-eslint/eslint-plugin \
        @typescript-eslint/parser pyright stylelint stylelint-config-standard \
        htmlhint markdownlint-cli
fi

# ------------------------------------------------------------------
# 11. PHP tooling (LSP + Composer)
# ------------------------------------------------------------------
if $INSTALL_PHP; then
    step "PHP tooling"
    if ${IS_ALPINE}; then
        install_pkgs php php-mbstring php-xml php-curl php-zip php-intl
    else
        install_pkgs php-cli php-mbstring php-xml php-curl php-zip php-intl
    fi
    if command -v php >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer 2>/dev/null | php -- \
            --install-dir=/usr/local/bin --filename=composer >/dev/null 2>&1 \
            || fail "composer install failed"
    fi
fi

# ------------------------------------------------------------------
# 12. Media processing (image/audio)
# ------------------------------------------------------------------
if $INSTALL_MEDIA; then
    step "Media tooling"
    install_pkgs ffmpeg
    pip_install Pillow imagehash audioread
fi

# ------------------------------------------------------------------
# 13. PDF processing (Pandoc + LaTeX)
# ------------------------------------------------------------------
if $INSTALL_PDF; then
    step "PDF tooling"
    $PKG_UPDATE
    if ${IS_ALPINE}; then
        install_pkgs pandoc texlive-xetex texlive-latex-extra \
            texlive-fonts-recommended texlive-science texlive-latexmk \
            poppler ghostscript imagemagick font-noto font-noto-cjk \
            font-liberation font-dejavu
    else
        install_pkgs pandoc texlive-xetex texlive-latex-extra \
            texlive-fonts-recommended texlive-science latexmk \
            poppler-utils ghostscript imagemagick fonts-noto fonts-noto-cjk \
            fonts-liberation fonts-dejavu
    fi
fi

# ------------------------------------------------------------------
# 14. Cross-language agent essentials
# ------------------------------------------------------------------
if $INSTALL_TOOLS; then
    step "agent tools"
    if ${IS_ALPINE}; then
        install_pkgs fd ctags ast-grep difftastic yq-go xmlstarlet sqlite \
            shfmt taplo github-cli git-lfs direnv just hyperfine \
            make cmake samurai meson pkgconf openssh-client
    else
        install_pkgs fd-find universal-ctags xmlstarlet sqlite3 shfmt \
            direnv git-lfs hyperfine make cmake ninja-build meson pkg-config \
            openssh-client
    fi
fi

# ------------------------------------------------------------------
# 15. Go tooling
# ------------------------------------------------------------------
if $INSTALL_GO; then
    step "Go tooling"
    if ${IS_ALPINE}; then
        install_pkgs go gopls golangci-lint
    else
        install_pkgs golang-go
    fi
fi

# ------------------------------------------------------------------
# 16. Rust tooling
# ------------------------------------------------------------------
if $INSTALL_RUST; then
    step "Rust tooling"
    if ${IS_ALPINE}; then
        install_pkgs rustup
    else
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs 2>/dev/null \
            | sh -s -- -y --no-modify-path >/dev/null 2>&1 \
            || fail "rustup install failed"
    fi
    install_pkgs rust-analyzer
fi

# ------------------------------------------------------------------
# 17. C/C++ tooling
# ------------------------------------------------------------------
if $INSTALL_C; then
    step "C/C++ tooling"
    if ${IS_ALPINE}; then
        install_pkgs clang-extra-tools cppcheck gdb valgrind strace ltrace \
            make cmake samurai pkgconf build-base
    else
        install_pkgs clang clangd clang-format clang-tidy cppcheck \
            gdb valgrind strace ltrace make cmake ninja-build pkg-config \
            build-essential
    fi
fi

# ------------------------------------------------------------------
# 18. Ruby tooling
# ------------------------------------------------------------------
if $INSTALL_RUBY; then
    step "Ruby tooling"
    if ${IS_ALPINE}; then
        install_pkgs ruby ruby-dev ruby-bundler
    else
        install_pkgs ruby ruby-dev bundler
    fi
    if command -v gem >/dev/null 2>&1; then
        gem_install rubocop ruby-lsp
    fi
fi

# ------------------------------------------------------------------
# 19. Lua tooling
# ------------------------------------------------------------------
if $INSTALL_LUA; then
    step "Lua tooling"
    if ${IS_ALPINE}; then
        install_pkgs lua5.4 lua5.4-dev luarocks lua-language-server stylua luacheck
    else
        install_pkgs lua5.4 luarocks
    fi
fi

# ------------------------------------------------------------------
# 20. pi agent binary (non-interactive)
# Installs the @earendil-works/pi-coding-agent npm package via npm — the
# same command pi.dev/install.sh runs — after ensuring Node >= 22.19.0 +
# npm. No prompts, no /dev/tty, never launches pi. Best-effort: if node
# can't be provisioned, skip the agent install but still generate
# models.json (works on any container).
# ------------------------------------------------------------------
if $INSTALL_AGENT; then
    step "pi agent"
    if ensure_node_npm; then
        AGENT_VER="${PI_AGENT_VERSION:-1.5.0}"
        npm install -g --prefix /usr/local --ignore-scripts --min-release-age=0 \
            --no-fund --no-audit --progress=false \
            "@earendil-works/pi-coding-agent@${AGENT_VER}" >/dev/null 2>&1 \
            || fail "pi agent npm install failed"
        command -v pi >/dev/null 2>&1 || fail "pi binary not found after install"
    else
        fail "pi agent needs Node >= 22.19.0 + npm (node: $(node -v 2>/dev/null || echo none)); agent install skipped"
    fi
fi

AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
MODELS_FILE="${PI_MODELS_FILE:-$AGENT_DIR/models.json}"
CORTEX_URL="${CORTEX_URL:-http://cortex-openresty-1:8080}"
OLLAMA_URL="${OLLAMA_URL:-http://cortex-openresty-1:11434}"

step "models.json"
mkdir -p "$(dirname "$MODELS_FILE")"
export CORTEX_URL OLLAMA_URL PI_MODELS_FILE="$MODELS_FILE"
if command -v generate-models.sh >/dev/null 2>&1; then
    generate-models.sh || fail "models.json generation failed"
else
    GEN_SH="/tmp/gen-pi-$$.sh"
    if curl -fsSL "$CORTEX_URL/generate-models.sh" -o "$GEN_SH"; then
        sh "$GEN_SH" || fail "models.json generation failed"
        rm -f "$GEN_SH"
    else
        fail "could not fetch generate-models.sh from cortex gateway"
    fi
fi

# ------------------------------------------------------------------
# 22. Clean up package cache
# ------------------------------------------------------------------
$PKG_CLEAN

# ------------------------------------------------------------------
# 23. Summary
# ------------------------------------------------------------------
echo
if [ -n "$FAILED" ]; then
    echo "install-pi: completed with issues:"
    printf '%s' "$FAILED" | while IFS= read -r line; do
        [ -n "$line" ] && echo "  - $line"
    done
else
    echo "install-pi: completed with no issues."
fi
