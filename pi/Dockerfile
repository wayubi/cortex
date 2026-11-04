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
      python3 \
 && npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.5.0 \
 && npm cache clean --force

COPY --chmod=755 generate-models.sh /usr/local/bin/generate-models.sh

# Pre-trusted hosts for SSH; avoids interactive host-key confirmation in a container
RUN mkdir -p /root/.ssh \
 && ssh-keyscan -t ed25519 github.com > /root/.ssh/known_hosts \
 && chmod 755 /root/.ssh

ENV TERM=xterm-256color \
    LANG=C.UTF-8 \
    PI_SKIP_VERSION_CHECK=1

WORKDIR /workspace
CMD ["sleep", "infinity"]
