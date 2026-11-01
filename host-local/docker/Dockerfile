FROM node:24-trixie

ARG PNPM_VERSION=11.28.5

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    bubblewrap \
    ca-certificates \
    curl \
    git \
    iproute2 \
    jq \
    openssh-client \
    procps \
    python3 \
    python3-venv \
    ripgrep \
    tini \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable \
  && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
  && groupmod --new-name uadmin node \
  && usermod --login uadmin --home /home/uadmin --move-home node \
  && python3 -m venv /opt/dsh-bdd \
  && /opt/dsh-bdd/bin/pip install --no-cache-dir pytest==8.4.2 pytest-bdd==8.1.0

ENV HOME=/home/uadmin \
    DSH_HOME=/home/uadmin/.dsh \
    PNPM_CONFIG_STORE_DIR=/home/uadmin/.dsh/.pnpm-store \
    PATH=/mnt/82A23910A2390A65/Trade/EducationAndHack/LLM/Proxy/BrowserRunner/.venv/bin:/home/uadmin/.local/bin:/home/uadmin/.bun/bin:/opt/dsh-bdd/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER uadmin
WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bash", "host-local/docker/run-dsh.sh"]
