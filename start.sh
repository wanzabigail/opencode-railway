#!/usr/bin/env bash
# =============================================================================
# start.sh — entrypoint container OpenCode di Railway
#
# 1. Siapkan direktori persisten (/data)
# 2. Pastikan OPENCODE_SERVER_PASSWORD ada
# 3. Jalankan `opencode serve` (foreground, PID 1 via tini) dengan supervisor:
#    kalau server mati -> restart; kalau ada versi baru -> upgrade & restart
#
# Auto-update (opsional, default aktif):
#   OPENCODE_AUTO_UPDATE=true|false
#   OPENCODE_AUTO_UPDATE_INTERVAL=<detik>   (default 21600 = 6 jam, min 300)
# =============================================================================
set -Eeuo pipefail

log()  { printf '[opencode] %s\n' "$*"; }
warn() { printf '[opencode] WARNING: %s\n' "$*" >&2; }
die()  { printf '[opencode] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Environment & direktori persisten
# ---------------------------------------------------------------------------
export PORT="${PORT:-8080}"

# HOME dipaksa ke volume supaya config, session, credential, dan cache
# OpenCode ikut persisten saat redeploy. Jangan pakai "${HOME:-...}" karena
# Railway sudah meng-inject HOME=/root (ephemeral). Override dengan OPENCODE_HOME.
export HOME="${OPENCODE_HOME:-/data/home}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

# Biarkan supervisor kita yang menangani update, bukan updater internal.
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
# 3. Profil hemat RAM/CPU
#
# Menyalakan flag yang mematikan pekerjaan latar belakang (file watcher,
# fetch daftar model, pemindaian Claude Code) dan memasang config OpenCode
# hemat resource (LSP, formatter, snapshot, warming, plugin mati).
# ---------------------------------------------------------------------------
LOW_RESOURCE="${OPENCODE_LOW_RESOURCE:-true}"
case "$LOW_RESOURCE" in
    1|true|yes|on) LOW_RESOURCE=true ;;
    *)             LOW_RESOURCE=false ;;
esac

TEMPLATE="${OPENCODE_LOW_RESOURCE_CONFIG:-/opt/opencode/low-resource.json}"
[ -f "$TEMPLATE" ] || TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/low-resource.json"
CONFIG_TARGET="$XDG_CONFIG_HOME/opencode/opencode.json"

apply_low_resource() {
    if [ "$LOW_RESOURCE" = true ]; then
        export OPENCODE_DISABLE_FILEWATCHER="${OPENCODE_DISABLE_FILEWATCHER:-true}"
        export OPENCODE_DISABLE_MODELS_FETCH="${OPENCODE_DISABLE_MODELS_FETCH:-true}"
        export OPENCODE_DISABLE_CLAUDE_CODE="${OPENCODE_DISABLE_CLAUDE_CODE:-true}"
        export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS="${OPENCODE_DISABLE_CLAUDE_CODE_SKILLS:-true}"

        if [ ! -f "$TEMPLATE" ]; then
            warn "Profil hemat: template config tidak ditemukan (${TEMPLATE}); dilewati."
            return 0
        fi
        mkdir -p "$(dirname "$CONFIG_TARGET")"
        if [ ! -f "$CONFIG_TARGET" ] || cmp -s "$CONFIG_TARGET" "$TEMPLATE"; then
            cp "$TEMPLATE" "$CONFIG_TARGET"
        else
            log "Profil hemat: config kustom ada di ${CONFIG_TARGET}; tidak ditimpa."
        fi
    else
        if [ -f "$CONFIG_TARGET" ] && [ -f "$TEMPLATE" ] && cmp -s "$CONFIG_TARGET" "$TEMPLATE"; then
            rm -f "$CONFIG_TARGET"
            log "Profil hemat: config bawaan dihapus."
        fi
    fi
}
apply_low_resource

# ---------------------------------------------------------------------------
# 4. Konfigurasi auto-update
# ---------------------------------------------------------------------------
AUTO_UPDATE="${OPENCODE_AUTO_UPDATE:-true}"
case "$AUTO_UPDATE" in
    1|true|yes|on) AUTO_UPDATE=true ;;
    *)             AUTO_UPDATE=false ;;
esac

UPDATE_INTERVAL="${OPENCODE_AUTO_UPDATE_INTERVAL:-21600}"
case "$UPDATE_INTERVAL" in
    ''|*[!0-9]*) UPDATE_INTERVAL=21600 ;;
esac
[ "$UPDATE_INTERVAL" -ge 300 ] 2>/dev/null || UPDATE_INTERVAL=300

# ---------------------------------------------------------------------------
# 5. Supervisor
# ---------------------------------------------------------------------------
SHUTDOWN=0
SERVER_PID=""
TIMER_PID=""
FAILS=0

shutdown() {
    SHUTDOWN=1
    log "Menerima sinyal berhenti; mematikan server..."
    [ -n "$SERVER_PID" ] && kill -TERM "$SERVER_PID" 2>/dev/null || true
    [ -n "$TIMER_PID" ] && kill "$TIMER_PID" 2>/dev/null || true
}
trap shutdown TERM INT

# Cek versi npm lalu pasang bila lebih baru, kemudian hentikan server
# (argumen 1) supaya loop utama menjalankannya ulang.
updater_loop() {
    server_pid="$1"
    while :; do
        sleep "$UPDATE_INTERVAL" || return 0
        [ "$SHUTDOWN" = 1 ] && return 0

        log "Auto-update: memeriksa versi terbaru di npm..."
        latest="$(npm view @opencode/cli version 2>/dev/null || true)"
        if [ -z "$latest" ]; then
            warn "Auto-update: gagal membaca versi npm; coba lagi nanti."
            continue
        fi

        current="$(opencode --version 2>/dev/null | sed -E 's/^[^0-9]*//' || true)"
        if [ "$latest" = "$current" ]; then
            log "Auto-update: sudah versi terbaru (${current})."
            continue
        fi

        newest="$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n 1)"
        if [ "$newest" != "$latest" ]; then
            log "Auto-update: terpasang (${current}) lebih baru dari npm (${latest}); dilewati."
            continue
        fi

        log "Auto-update: ${current} -> ${latest}. Memasang..."
        if npm install -g "@opencode/cli@${latest}" --no-audit --no-fund \
                --allow-scripts=@opencode/cli >/tmp/opencode-update.log 2>&1 \
           || npm install -g "@opencode/cli@${latest}" --no-audit --no-fund \
                >>/tmp/opencode-update.log 2>&1; then
            npm cache clean --force >/dev/null 2>&1 || true
            log "Auto-update: ${latest} terpasang; restart server..."
            kill -TERM "$server_pid" 2>/dev/null || true
            return 0
        fi
        warn "Auto-update gagal; tetap di ${current}. Log: /tmp/opencode-update.log"
    done
}

cd /data/workspace

log "Working directory: $(pwd)"
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    log "Public URL : https://${RAILWAY_PUBLIC_DOMAIN}"
fi
log "Login password: ${OPENCODE_SERVER_PASSWORD}"
if [ "$AUTO_UPDATE" = true ]; then
    log "Auto-update: aktif (interval ${UPDATE_INTERVAL}s)"
else
    log "Auto-update: nonaktif"
fi
if [ "$LOW_RESOURCE" = true ]; then
    log "Profil hemat: aktif (LSP/formatter/snapshot/warming off, watcher off)"
else
    log "Profil hemat: nonaktif"
fi

while :; do
    VERSION="$(opencode --version 2>/dev/null | sed -E 's/^[^0-9]*//' || echo '?')"
    log "Menjalankan opencode ${VERSION} di 0.0.0.0:${PORT}"

    opencode serve \
        --hostname 0.0.0.0 \
        --port "$PORT" \
        --print-logs &
    SERVER_PID=$!

    TIMER_PID=""
    if [ "$AUTO_UPDATE" = true ]; then
        updater_loop "$SERVER_PID" &
        TIMER_PID=$!
    fi

    STARTED_AT="$(date +%s)"
    STATUS=0
    wait "$SERVER_PID" || STATUS=$?

    if [ -n "$TIMER_PID" ]; then
        kill "$TIMER_PID" 2>/dev/null || true
        wait "$TIMER_PID" 2>/dev/null || true
        TIMER_PID=""
    fi

    if [ "$SHUTDOWN" = 1 ]; then
        log "Shutdown selesai."
        exit 0
    fi

    # Deteksi crash-loop: server yang mati < 10 detik berturut-turut.
    if [ $(( $(date +%s) - STARTED_AT )) -lt 10 ]; then
        FAILS=$(( FAILS + 1 ))
    else
        FAILS=0
    fi
    if [ "$FAILS" -ge 5 ]; then
        die "Server berhenti 5x berturut-turut; keluar agar Railway me-restart container."
    fi

    log "Server berhenti (status ${STATUS}); restart dalam 3 detik..."
    sleep 3
done
