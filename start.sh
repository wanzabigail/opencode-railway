#!/usr/bin/env bash
# =============================================================================
# start.sh — entrypoint container OpenCode di Railway
#
# 1. Siapkan direktori persisten (/data)
# 2. Pastikan OPENCODE_SERVER_PASSWORD ada
# 3. Jalankan `opencode serve` di 0.0.0.0:$PORT (foreground, PID 1 via tini)
# =============================================================================
set -Eeuo pipefail

log()  { printf '[opencode] %s\n' "$*"; }
warn() { printf '[opencode] WARNING: %s\n' "$*" >&2; }
die()  { printf '[opencode] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Environment & direktori persisten
# ---------------------------------------------------------------------------
export PORT="${PORT:-8080}"

# HOME diarahkan ke volume supaya config, session, credential, dan cache
# OpenCode ikut persisten saat redeploy.
export HOME="${HOME:-/data/home}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

export OPENCODE_DISABLE_AUTOUPDATE="${OPENCODE_DISABLE_AUTOUPDATE:-true}"

mkdir -p /data/workspace "$HOME" \
    "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

# ---------------------------------------------------------------------------
# 2. Password server
# ---------------------------------------------------------------------------
if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ]; then
    OPENCODE_SERVER_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
    export OPENCODE_SERVER_PASSWORD
    warn "OPENCODE_SERVER_PASSWORD tidak diset. Password acak dibuat:"
    warn "  ${OPENCODE_SERVER_PASSWORD}"
    warn "Set variabel ini di Railway agar password tidak berubah tiap restart."
fi

# ---------------------------------------------------------------------------
# 3. Jalankan server
# ---------------------------------------------------------------------------
cd /data/workspace

log "OpenCode $(opencode --version 2>/dev/null || echo '?')"
log "Listening on 0.0.0.0:${PORT}"
log "Working directory: $(pwd)"
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    log "Public URL : https://${RAILWAY_PUBLIC_DOMAIN}"
fi
log "Login password: ${OPENCODE_SERVER_PASSWORD}"

# Basic Auth (jika diminta browser/klien): username "opencode",
# password = OPENCODE_SERVER_PASSWORD.
exec opencode serve \
    --hostname 0.0.0.0 \
    --port "$PORT" \
    --print-logs
