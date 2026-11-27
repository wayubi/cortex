# syntax=docker/dockerfile:1
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      jq \
      less \
      libstdc++6 \
      openssh-client \
      procps \
      ripgrep \
      unzip \
      xz-utils \
 && rm -rf /var/lib/apt/lists/*

# OpenCode is not pinned: a build with a new CACHEBUST value re-runs only this
# layer and installs the latest release (CACHEBUST=$(date +%s) docker compose
# build opencode). The system packages above stay cached.
ARG CACHEBUST=0
RUN echo "cachebust=$CACHEBUST" \
 && curl -fsSL https://opencode.ai/v2/install | bash \
 && (install -m 755 /root/.opencode/bin/opencode /usr/local/bin/opencode \
     || install -m 755 /root/.local/bin/opencode /usr/local/bin/opencode \
     || command -v opencode >/dev/null) \
 && opencode --version

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
# `opencode pair` defaults to --url "$OPENCODE_PAIR_URL" (see the script)
COPY --chmod=755 opencode-pair-url.sh /usr/local/sbin/opencode
# the installer prepends /root/.opencode/bin to PATH in .bashrc; keep the wrapper first
RUN echo 'export PATH=/usr/local/sbin:$PATH' >> /root/.bashrc

ENV TERM=xterm-256color \
    LANG=C.UTF-8

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
