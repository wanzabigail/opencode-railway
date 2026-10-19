# syntax=docker/dockerfile:1
# =============================================================================
# OpenCode (V2) di Railway
#
# Arsitektur:
#   Internet -> Railway edge (HTTPS) -> opencode serve 0.0.0.0:$PORT
#
# OpenCode menjalankan server API + web UI sekaligus. Autentikasi memakai
# password bawaan OpenCode (OPENCODE_SERVER_PASSWORD).
#
# State persisten disimpan di volume /data:
#   /data/workspace -> working directory agent (repo & hasil kerja)
#   /data/home      -> HOME: config, session, credential, cache OpenCode
# =============================================================================
FROM node:24-slim

ARG OPENCODE_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_ENV=production \
    OPENCODE_DISABLE_AUTOUPDATE=true \
    OPENCODE_AUTO_UPDATE=true \
    OPENCODE_AUTO_UPDATE_INTERVAL=21600

# tini            : init/PID 1 agar sinyal & zombie process rapi
# git, curl, ssh  : kebutuhan agent di dalam container
# ripgrep         : pencarian file cepat yang dipakai OpenCode
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tini \
        git \
        curl \
        ca-certificates \
        openssh-client \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Paket CLI OpenCode V2 adalah @opencode/cli (bukan opencode-ai milik V1).
# postinstall mengunduh binary native sesuai platform image ini.
RUN npm install -g "@opencode/cli@${OPENCODE_VERSION}" --no-audit --no-fund \
    && npm cache clean --force \
    && opencode --version

# Dibuat di image supaya tetap jalan walau volume belum terpasang.
RUN mkdir -p /data/workspace /data/home

COPY start.sh /usr/local/bin/start-opencode.sh
RUN chmod 0755 /usr/local/bin/start-opencode.sh

WORKDIR /data/workspace

# Railway meng-inject $PORT; default start.sh adalah 8080.
EXPOSE 8080

# "/" mengembalikan halaman login (200) tanpa kredensial, cocok untuk probe.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT:-8080}/" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start-opencode.sh"]
