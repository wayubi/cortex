# syntax=docker/dockerfile:1
FROM node:22-alpine

RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      git \
      jq \
      ncurses-terminfo-base \
      openssh-client \
      ripgrep \
      python3

# Pi is not pinned: a build with a new CACHEBUST value re-runs only this
# layer and installs the latest release (CACHEBUST=$(date +%s) docker compose
# build pi). The system packages above stay cached.
ARG CACHEBUST=0
RUN echo "cachebust=$CACHEBUST" \
 && npm install -g --ignore-scripts @earendil-works/pi-coding-agent@latest \
 && npm cache clean --force

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENV TERM=xterm-256color \
    LANG=C.UTF-8 \
    PI_SKIP_VERSION_CHECK=1

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
