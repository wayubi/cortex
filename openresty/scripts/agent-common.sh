#!/bin/sh
# Shared client-installer library for Cortex agents.
#
# This file is sourced by install-pi.sh and install-opencode.sh. It defines
# functions only; the caller sets AGENT_NAME and the INSTALL_* flags, then
# calls agent_init.
#
# Supports Debian/Ubuntu (apt) and Alpine (apk). Run as root.

agent_fail() {
    echo "  ! $*" >&2
    FAILED="${FAILED}$*
"
    if [ "${STRICT:-false}" = "true" ]; then
        echo "${AGENT_NAME:-install-agent}: aborting on first failure (--strict)" >&2
        exit 1
    fi
    return 0
}

agent_step() {
    echo
    echo "==> $*"
}

agent_fetch() {
    url=$1
    dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 300 "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        return 1
    fi
}

agent_init() {
    AGENT_NAME="${AGENT_NAME:-install-agent}"
    STRICT="${STRICT:-false}"
    FAILED=""

    if [ "$(id -u)" != "0" ]; then
        echo "Error: must run as root (apk/apt install system packages)." >&2
        exit 1
    fi

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

    case "$(uname -m)" in
        x86_64|amd64)  AGENT_ARCH_ALIASES="amd64 x86_64 x86-64 x64" ;;
        aarch64|arm64) AGENT_ARCH_ALIASES="arm64 aarch64" ;;
        armv7l|armv6l) AGENT_ARCH_ALIASES="armv7 armhf arm" ;;
        *)             AGENT_ARCH_ALIASES="" ;;
    esac

    INSTALL_BUILD=false
    [ "${INSTALL_PYTHON:-false}" = "true" ] && INSTALL_BUILD=true
    [ "${INSTALL_MEDIA:-false}" = "true" ] && INSTALL_BUILD=true
}

agent_summary() {
    echo
    if [ -n "$FAILED" ]; then
        echo "${AGENT_NAME}: completed with issues:"
        printf '%s' "$FAILED" | while IFS= read -r line; do
            [ -n "$line" ] && echo "  - $line"
        done
    else
        echo "${AGENT_NAME}: all requested components installed."
    fi
}

agent_parse_common_flag() {
    case "$1" in
        --python) INSTALL_PYTHON=true ;;
        --node)   INSTALL_NODE=true ;;
        --php)    INSTALL_PHP=true ;;
        --media)  INSTALL_MEDIA=true ;;
        --pdf)    INSTALL_PDF=true ;;
        --tools)  INSTALL_TOOLS=true ;;
        --go)     INSTALL_GO=true ;;
        --rust)   INSTALL_RUST=true ;;
        --c)      INSTALL_C=true ;;
        --ruby)   INSTALL_RUBY=true ;;
        --lua)    INSTALL_LUA=true ;;
        --strict) STRICT=true ;;
        *) return 1 ;;
    esac
    return 0
}

agent_install_pkgs() {
    [ "$#" -eq 0 ] && return 0
    $PKG_INSTALL "$@" >/dev/null 2>&1 && return 0
    for p in "$@"; do
        $PKG_INSTALL "$p" >/dev/null 2>&1 || agent_fail "unavailable: $p"
    done
    return 0
}

agent_pip_install() {
    [ "$#" -eq 0 ] && return 0
    if ! command -v pip3 >/dev/null 2>&1; then
        if ${IS_ALPINE}; then agent_install_pkgs python3 py3-pip
        else agent_install_pkgs python3 python3-pip; fi
    fi
    # shellcheck disable=SC2086
    pip3 install --no-cache-dir $PIP_BREAK_SYSTEM -U "$@" >/dev/null 2>&1 && return 0
    for p in "$@"; do
        # shellcheck disable=SC2086
        pip3 install --no-cache-dir $PIP_BREAK_SYSTEM -U "$p" >/dev/null 2>&1 \
            || agent_fail "unavailable: $p (pip)"
    done
    return 0
}

agent_npm_install() {
    [ "$#" -eq 0 ] && return 0
    npm install -g --prefix /usr/local --no-fund --no-audit "$@" >/dev/null 2>&1 && return 0
    for p in "$@"; do
        npm install -g --prefix /usr/local --no-fund --no-audit "$p" >/dev/null 2>&1 \
            || agent_fail "unavailable: $p (npm)"
    done
    return 0
}

agent_gem_install() {
    for p in "$@"; do
        gem install --no-document "$p" >/dev/null 2>&1 \
            || agent_fail "unavailable: $p (gem)"
    done
    return 0
}

agent_go_install() {
    for p in "$@"; do
        GOBIN=/usr/local/bin go install "$p" >/dev/null 2>&1 \
            || agent_fail "unavailable: $p (go)"
    done
    return 0
}

agent_arch_re() {
    out=""
    for a in $AGENT_ARCH_ALIASES; do
        out="${out}${out:+|}${a}"
    done
    printf '%s' "$out"
}

agent_github_asset_url() {
    agent_fetch "https://api.github.com/repos/$1/releases/tags/$2" "${TMPDIR:-/tmp}/cortex-release-$$.json" 2>/dev/null || return 1
    jq -r --arg re "$3" '.assets[] | select(.name | test($re)) | .browser_download_url' \
        "${TMPDIR:-/tmp}/cortex-release-$$.json" | head -n 1
    rm -f "${TMPDIR:-/tmp}/cortex-release-$$.json"
}

# agent_install_release OWNER/REPO ASSET_RE BIN_NAME [CHECKSUM_RE]
# ASSET_RE may contain @ARCH@, expanded to the host's architecture aliases.
agent_install_release() {
    repo=$1
    asset_re=$2
    bin_name=$3
    sum_re=${4:-"(checksums?(\\.(txt|sha256))?|SHA256SUMS|sha256sums|.*\\.sha256)(\\.txt)?\$"}

    if [ -z "$AGENT_ARCH_ALIASES" ]; then
        agent_fail "unavailable: $repo (unsupported arch $(uname -m))"
        return 0
    fi

    tag=$(agent_fetch "https://api.github.com/repos/$repo/releases/latest" "${TMPDIR:-/tmp}/cortex-latest-$$.json" 2>/dev/null \
          && jq -r '.tag_name // empty' "${TMPDIR:-/tmp}/cortex-latest-$$.json")
    rm -f "${TMPDIR:-/tmp}/cortex-latest-$$.json"
    [ -n "$tag" ] || { agent_fail "unavailable: $repo (no release)"; return 0; }

    # Group the aliases so their | stays inside @ARCH@, and anchor the whole
    # name so e.g. a .deb, another OS's build or a .sha256 sibling cannot match.
    are="^($(printf '%s' "$asset_re" | sed "s/@ARCH@/($(agent_arch_re))/g"))\$"
    url=$(agent_github_asset_url "$repo" "$tag" "$are")
    [ -n "$url" ] || { agent_fail "unavailable: $repo (no asset for this arch)"; return 0; }

    sumurl=$(agent_github_asset_url "$repo" "$tag" "$sum_re")
    [ -n "$sumurl" ] || { agent_fail "unavailable: $repo (no checksum asset to verify against)"; return 0; }

    name=$(basename "$url")
    tmp=$(mktemp -d)
    if ! agent_fetch "$url" "$tmp/$name" 2>/dev/null \
       || ! agent_fetch "$sumurl" "$tmp/checksums" 2>/dev/null; then
        agent_fail "download failed: $repo"
        rm -rf "$tmp"
        return 0
    fi

    chmod +x "$tmp/$name" 2>/dev/null || true
    line=$(grep -E "[[:space:]]\*?${name}\$" "$tmp/checksums" | head -n 1)
    if [ -z "$line" ]; then
        agent_fail "no checksum line for $name in $repo"
        rm -rf "$tmp"
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        if ! ( cd "$tmp" && printf '%s\n' "$line" | sha256sum -c - >/dev/null 2>&1 ); then
            agent_fail "checksum mismatch: $repo"
            rm -rf "$tmp"
            return 0
        fi
    elif command -v shasum >/dev/null 2>&1; then
        if ! ( cd "$tmp" && printf '%s\n' "$line" | shasum -a 256 -c - >/dev/null 2>&1 ); then
            agent_fail "checksum mismatch: $repo"
            rm -rf "$tmp"
            return 0
        fi
    else
        agent_fail "no sha256 tool for $repo"
        rm -rf "$tmp"
        return 0
    fi

    case "$name" in
        *.tar.gz|*.tgz) tar -xzf "$tmp/$name" -C "$tmp" 2>/dev/null ;;
        *.tar.xz)       tar -xJf "$tmp/$name" -C "$tmp" 2>/dev/null ;;
        *.zip)          unzip -qo "$tmp/$name" -d "$tmp" 2>/dev/null ;;
        *.gz)           gunzip -c "$tmp/$name" > "$tmp/$bin_name" 2>/dev/null ;;
        *)              ;;
    esac

    src=$(find "$tmp" -type f -name "$bin_name" 2>/dev/null | head -n 1)
    [ -n "$src" ] || src=$(find "$tmp" -type f -perm -u+x ! -name 'checksums*' 2>/dev/null | head -n 1)
    if [ -z "$src" ]; then
        agent_fail "no $bin_name binary in $repo archive"
        rm -rf "$tmp"
        return 0
    fi
    install -m 755 "$src" "/usr/local/bin/$bin_name" 2>/dev/null \
        || agent_fail "install failed: $bin_name"
    rm -rf "$tmp"
    return 0
}

agent_node_at_least() {
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

agent_ensure_node_npm() {
    if command -v node >/dev/null 2>&1 && agent_node_at_least 22 19 0 && command -v npm >/dev/null 2>&1; then
        return 0
    fi

    # The official Node builds are glibc binaries, so use the distro package on
    # musl (Alpine) instead of downloading one that cannot execute there.
    if ${IS_ALPINE}; then
        agent_install_pkgs nodejs npm
        command -v node >/dev/null 2>&1 \
            && agent_node_at_least 22 19 0 \
            && command -v npm >/dev/null 2>&1
        return $?
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
    node_tmp_dir="${TMPDIR:-/tmp}/cortex-node.$$"
    rm -rf "$node_tmp_dir"
    mkdir -p "$node_tmp_dir" || return 1

    if ! command -v xz >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y --no-install-recommends xz-utils >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --update-cache xz >/dev/null 2>&1
        fi
        command -v xz >/dev/null 2>&1 || return 1
    fi

    agent_fetch "$node_dist_base/SHASUMS256.txt" "$node_tmp_dir/SHASUMS256.txt" || return 1
    node_file=$(awk -v suffix="-$node_platform-$node_arch.tar.xz" \
        'index($2, "node-v") == 1 && length($2) >= length(suffix) && \
         substr($2, length($2) - length(suffix) + 1) == suffix { print $2; exit }' \
        "$node_tmp_dir/SHASUMS256.txt")
    [ -n "$node_file" ] || return 1

    agent_fetch "$node_dist_base/$node_file" "$node_tmp_dir/$node_file" || return 1

    awk -v file="$node_file" '$2 == file { print }' "$node_tmp_dir/SHASUMS256.txt" \
        > "$node_tmp_dir/SHASUMS256.selected"
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$node_tmp_dir" && sha256sum -c SHASUMS256.selected) >/dev/null 2>&1 \
            || return 1
    elif command -v shasum >/dev/null 2>&1; then
        (cd "$node_tmp_dir" && shasum -a 256 -c SHASUMS256.selected) >/dev/null 2>&1 \
            || return 1
    else
        return 1
    fi

    node_dir="$node_base_dir/${node_file%.tar.xz}"
    rm -rf "$node_dir"
    tar -xf "$node_tmp_dir/$node_file" -C "$node_base_dir" || return 1
    rm -rf "$node_tmp_dir"

    for bin in node npm npx; do
        ln -sfn "$node_dir/bin/$bin" "$node_base_dir/bin/$bin" 2>/dev/null
    done

    command -v node >/dev/null 2>&1 && agent_node_at_least 22 19 0 && command -v npm >/dev/null 2>&1
}

agent_install_base() {
    agent_step "universal base"
    $PKG_UPDATE
    if ${IS_ALPINE}; then
        agent_install_pkgs bash curl ca-certificates git unzip zip tar xz \
            ripgrep jq less procps shellcheck openssh-client
    else
        agent_install_pkgs bash curl ca-certificates git unzip zip tar xz-utils \
            ripgrep jq less procps shellcheck openssh-client libstdc++6
    fi
}

agent_install_build_toolchain() {
    agent_step "C build toolchain"
    if ${IS_ALPINE}; then
        agent_install_pkgs build-base pkgconf libjpeg-turbo-dev zlib-dev libpng-dev
    else
        agent_install_pkgs build-essential pkg-config libjpeg-dev zlib1g-dev libpng-dev
    fi
}

agent_install_python() {
    agent_step "Python tooling"
    if ${IS_ALPINE}; then
        agent_install_pkgs python3 py3-pip python3-dev py3-pytest
    else
        agent_install_pkgs python3 python3-pip python3-venv python3-dev python3-pytest
    fi
    agent_pip_install \
        python-lsp-server pylsp-mypy python-lsp-black pyls-isort \
        pylint mypy ruff black isort yamllint \
        vulture codespell coverage
}

agent_install_node() {
    agent_step "Node tooling"
    if agent_ensure_node_npm; then
        agent_npm_install \
            typescript eslint prettier @typescript-eslint/eslint-plugin \
            @typescript-eslint/parser pyright stylelint stylelint-config-standard \
            htmlhint markdownlint-cli
    else
        agent_fail "Node >= 22.19.0 + npm unavailable for Node tooling"
    fi
}

agent_install_php() {
    agent_step "PHP tooling"
    if ${IS_ALPINE}; then
        agent_install_pkgs php php-mbstring php-xml php-curl php-zip php-intl
    else
        agent_install_pkgs php-cli php-mbstring php-xml php-curl php-zip php-intl
    fi
    if command -v php >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer 2>/dev/null | php -- \
            --install-dir=/usr/local/bin --filename=composer >/dev/null 2>&1 \
            || agent_fail "composer install failed"
    fi
}

agent_install_media() {
    agent_step "Media tooling"
    agent_install_pkgs ffmpeg
    agent_pip_install Pillow imagehash audioread
}

agent_install_pdf() {
    agent_step "PDF tooling"
    $PKG_UPDATE
    if ${IS_ALPINE}; then
        agent_install_pkgs pandoc texlive-xetex texlive-latex-extra \
            texlive-fonts-recommended texlive-science texlive-latexmk \
            poppler ghostscript imagemagick \
            font-noto font-noto-cjk font-liberation font-dejavu
    else
        agent_install_pkgs pandoc texlive-xetex texlive-latex-extra \
            texlive-fonts-recommended texlive-science latexmk \
            poppler-utils ghostscript imagemagick \
            fonts-noto fonts-noto-cjk fonts-liberation fonts-dejavu
    fi
}

agent_install_tools() {
    agent_step "agent tools"
    if ${IS_ALPINE}; then
        agent_install_pkgs fd ctags ast-grep difftastic yq-go xmlstarlet sqlite \
            shfmt taplo github-cli git-lfs direnv just hyperfine \
            make cmake samurai meson pkgconf openssh-client
    else
        agent_install_pkgs fd-find universal-ctags xmlstarlet sqlite3 shfmt \
            direnv git-lfs hyperfine make cmake ninja-build meson pkg-config \
            openssh-client
        if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
            ln -sf "$(command -v fdfind)" /usr/local/bin/fd
        fi
        command -v fd >/dev/null 2>&1 \
            || agent_install_release sharkdp/fd 'fd-v[0-9.]+-@ARCH@-unknown-linux-(gnu|musl)\.tar\.gz' fd
        command -v ast-grep >/dev/null 2>&1 \
            || agent_install_release ast-grep/ast-grep 'app-@ARCH@-unknown-linux-gnu\.zip' ast-grep
        command -v difft >/dev/null 2>&1 \
            || agent_install_release Wilfred/difftastic 'difft-@ARCH@-unknown-linux-(gnu|musl)\.tar\.gz' difft
        command -v taplo >/dev/null 2>&1 \
            || agent_install_release tamasfe/taplo 'taplo-linux-@ARCH@\.gz' taplo
        command -v just >/dev/null 2>&1 \
            || agent_install_release casey/just 'just-[0-9.]+-@ARCH@-unknown-linux-musl\.tar\.gz' just
        command -v shfmt >/dev/null 2>&1 \
            || agent_install_release mvdan/sh 'shfmt_v[0-9.]+_linux_@ARCH@' shfmt
        command -v gh >/dev/null 2>&1 \
            || agent_install_release cli/cli 'gh_[0-9.]+_linux_@ARCH@\.tar\.gz' gh
        command -v hadolint >/dev/null 2>&1 \
            || agent_install_release hadolint/hadolint 'hadolint-Linux-@ARCH@' hadolint
    fi
}

agent_install_go() {
    agent_step "Go tooling"
    if ${IS_ALPINE}; then
        agent_install_pkgs go gopls golangci-lint
    else
        agent_install_pkgs golang-go
        agent_go_install golang.org/x/tools/gopls@latest \
            github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest
    fi
    agent_go_install honnef.co/go/tools/cmd/staticcheck@latest \
        mvdan.cc/gofumpt@latest \
        github.com/go-delve/delve/cmd/dlv@latest
}

agent_install_rust() {
    agent_step "Rust tooling"
    if ${IS_ALPINE}; then
        agent_install_pkgs rustup
    else
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs 2>/dev/null \
            | sh -s -- -y --no-modify-path >/dev/null 2>&1 \
            || agent_fail "rustup install failed"
        [ -d "$HOME/.cargo/bin" ] && PATH="$HOME/.cargo/bin:$PATH"
    fi
    agent_install_pkgs rust-analyzer
    if command -v rustup >/dev/null 2>&1; then
        rustup default stable >/dev/null 2>&1 || agent_fail "rustup default stable failed"
        rustup component add rustfmt clippy rust-analyzer >/dev/null 2>&1 \
            || agent_fail "rustup components failed"
    fi
}

agent_install_c() {
    agent_step "C/C++ tooling"
    if ${IS_ALPINE}; then
        agent_install_pkgs clang-extra-tools cppcheck gdb valgrind strace ltrace \
            make cmake samurai pkgconf build-base
    else
        agent_install_pkgs clang clangd clang-format clang-tidy cppcheck \
            gdb valgrind strace ltrace make cmake ninja-build pkg-config \
            build-essential
    fi
}

agent_install_ruby() {
    agent_step "Ruby tooling"
    if ${IS_ALPINE}; then
        agent_install_pkgs ruby ruby-dev ruby-bundler
    else
        agent_install_pkgs ruby ruby-dev bundler
    fi
    if command -v gem >/dev/null 2>&1; then
        agent_gem_install rubocop ruby-lsp
    fi
}

agent_install_lua() {
    agent_step "Lua tooling"
    if ${IS_ALPINE}; then
        agent_install_pkgs lua5.4 lua5.4-dev luarocks lua-language-server stylua luacheck
    else
        agent_install_pkgs lua5.4 lua5.4-dev luarocks
        command -v lua-language-server >/dev/null 2>&1 \
            || agent_install_release LuaLS/lua-language-server 'lua-language-server-[0-9.]+-linux-@ARCH@\.tar\.gz' lua-language-server
        command -v stylua >/dev/null 2>&1 \
            || agent_install_release JohnnyMorganz/StyLua 'stylua-linux-@ARCH@\.zip' stylua
        if command -v luarocks >/dev/null 2>&1; then
            luarocks install luacheck >/dev/null 2>&1 \
                || agent_fail "unavailable: luacheck (luarocks)"
        else
            agent_fail "unavailable: luacheck (no luarocks)"
        fi
    fi
}

agent_install_requested_toolkits() {
    [ "${INSTALL_BUILD:-false}" = "true" ] && agent_install_build_toolchain
    [ "${INSTALL_PYTHON:-false}" = "true" ] && agent_install_python
    [ "${INSTALL_NODE:-false}" = "true" ] && agent_install_node
    [ "${INSTALL_PHP:-false}" = "true" ] && agent_install_php
    [ "${INSTALL_MEDIA:-false}" = "true" ] && agent_install_media
    [ "${INSTALL_PDF:-false}" = "true" ] && agent_install_pdf
    [ "${INSTALL_TOOLS:-false}" = "true" ] && agent_install_tools
    [ "${INSTALL_GO:-false}" = "true" ] && agent_install_go
    [ "${INSTALL_RUST:-false}" = "true" ] && agent_install_rust
    [ "${INSTALL_C:-false}" = "true" ] && agent_install_c
    [ "${INSTALL_RUBY:-false}" = "true" ] && agent_install_ruby
    [ "${INSTALL_LUA:-false}" = "true" ] && agent_install_lua
}

agent_cleanup() {
    $PKG_CLEAN
}
