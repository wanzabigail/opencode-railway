#!/usr/bin/env bash
# =============================================================================
# start.sh — entrypoint container OpenCode di Railway
#
# 1. Siapkan environment, verifikasi /data ter-mount, siapkan direktori
# 2. Pastikan OPENCODE_SERVER_PASSWORD ada (env / file persisten / generate)
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

# ---------------------------------------------------------------------------
# 2. Pastikan /data benar-benar volume persisten
#
# Kalau volume tidak ter-mount, semua tulisan ke /data hanya masuk ke
# filesystem container dan hilang saat redeploy. Lebih baik gagal dengan jelas
# daripada kehilangan session tanpa peringatan.
# ---------------------------------------------------------------------------
MOUNTS_FILE="${OPENCODE_MOUNTS_FILE:-/proc/mounts}"

data_is_mount_point() {
    [ -r "$MOUNTS_FILE" ] || return 1
    awk -v target=/data '$2 == target { found = 1 } END { exit found ? 0 : 1 }' "$MOUNTS_FILE"
}

DATA_IS_MOUNT=0
if data_is_mount_point; then
    DATA_IS_MOUNT=1
fi

# Kadang mount baru muncul beberapa saat setelah entrypoint mulai.
if [ "$DATA_IS_MOUNT" -eq 0 ] && [ -n "${RAILWAY_VOLUME_MOUNT_PATH:-}" ]; then
    tries=0
    while [ "$tries" -lt 10 ] && ! data_is_mount_point; do
        sleep 1
        tries=$((tries + 1))
    done
    if data_is_mount_point; then
        DATA_IS_MOUNT=1
    fi
fi

if [ -n "${RAILWAY_VOLUME_MOUNT_PATH:-}" ]; then
    log "Railway volume : ${RAILWAY_VOLUME_NAME:-<tanpa nama>} di '${RAILWAY_VOLUME_MOUNT_PATH}'"
fi

if [ "$DATA_IS_MOUNT" -eq 1 ]; then
    log "Persistent data: /data ter-mount."
else
    warn "/data BUKAN mount point terpisah."
    warn "Session, config, dan workspace akan hilang saat container di-redeploy."
    if [ -n "${RAILWAY_ENVIRONMENT:-}" ] || [ -n "${RAILWAY_PROJECT_ID:-}" ]; then
        case "${ALLOW_EPHEMERAL_DATA:-false}" in
            1|true|yes|on)
                warn "ALLOW_EPHEMERAL_DATA aktif; melanjutkan dengan /data ephemeral."
                ;;
            *)
                die "Pasang volume Railway di /data (tanpa spasi) lalu redeploy. Set ALLOW_EPHEMERAL_DATA=true hanya untuk uji sementara."
                ;;
        esac
    else
        warn "Di luar Railway, jalankan container dengan -v <host>:/data agar data persisten."
    fi
fi

# Lokasi database session dibuat eksplisit dan diikat ke HOME (yang berada di
# volume), bukan ke XDG_DATA_HOME yang bisa di-inject platform. Default OpenCode
# adalah ~/.local/share/opencode/opencode.db.
export OPENCODE_DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
DB_DIR="$(dirname "$OPENCODE_DB")"

case "$HOME" in
    /data|/data/*) ;;
    *)
        if [ -n "${RAILWAY_ENVIRONMENT:-}" ] || [ -n "${RAILWAY_PROJECT_ID:-}" ]; then
            warn "HOME berada di luar /data (${HOME}); config/password bisa hilang saat redeploy."
        fi
        ;;
esac
case "$OPENCODE_DB" in
    /data|/data/*) ;;
    *)
        if [ -n "${RAILWAY_ENVIRONMENT:-}" ] || [ -n "${RAILWAY_PROJECT_ID:-}" ]; then
            warn "OPENCODE_DB berada di luar /data (${OPENCODE_DB}); session tidak akan persisten."
        fi
        ;;
esac

# XDG bisa di-inject platform. Kalau di luar /data, sebagian state OpenCode
# (config/auth/service) tidak ikut volume.
if [ -n "${RAILWAY_ENVIRONMENT:-}" ] || [ -n "${RAILWAY_PROJECT_ID:-}" ]; then
    for xdg_var in XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME; do
        case "${!xdg_var}" in
            /data|/data/*) ;;
            *) warn "${xdg_var} berada di luar /data (${!xdg_var}); state OpenCode bisa hilang saat redeploy." ;;
        esac
    done
fi

mkdir -p /data/workspace "$HOME" "$DB_DIR" \
    "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

# ---------------------------------------------------------------------------
# 3. Password server
#
# Urutan sumber password:
#   1. OPENCODE_SERVER_PASSWORD dari environment (variable Railway)
#   2. file di volume (password yang pernah digenerate)
#   3. generate baru, lalu simpan ke volume
#
# Dengan begitu password tetap sama setelah restart/redeploy walau variable
# Railway tidak diset (mis. deploy langsung dari dashboard).
# ---------------------------------------------------------------------------
PASSWORD_FILE="${OPENCODE_PASSWORD_FILE:-$HOME/.opencode-server-password}"
PASSWORD_SOURCE="environment"

mkdir -p "$(dirname "$PASSWORD_FILE")" 2>/dev/null || true

generate_password() {
    local length="${1:-32}" password=""
    while [ "${#password}" -lt "$length" ]; do
        password="${password}$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
    done
    printf '%s' "${password:0:$length}"
}

if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ] && [ -s "$PASSWORD_FILE" ]; then
    OPENCODE_SERVER_PASSWORD="$(cat "$PASSWORD_FILE" 2>/dev/null || true)"
    if [ -n "$OPENCODE_SERVER_PASSWORD" ]; then
        PASSWORD_SOURCE="file ${PASSWORD_FILE}"
    fi
fi

if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ]; then
    OPENCODE_SERVER_PASSWORD="$(generate_password 32)"
    PASSWORD_SOURCE="generated"
    if ( umask 077 && printf '%s\n' "$OPENCODE_SERVER_PASSWORD" > "$PASSWORD_FILE" ); then
        PASSWORD_SOURCE="generated, disimpan di ${PASSWORD_FILE}"
    else
        warn "Password acak dibuat, tetapi gagal disimpan ke ${PASSWORD_FILE}."
        warn "Password akan berubah saat container restart."
    fi
fi

export OPENCODE_SERVER_PASSWORD

# ---------------------------------------------------------------------------
# 4. Profil hemat RAM/CPU
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
# 5. Konfigurasi auto-update
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
# 6. Supervisor
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

if [ "$DATA_IS_MOUNT" -eq 1 ]; then
    PERSISTENT_LABEL="volume /data"
else
    PERSISTENT_LABEL="EPHEMERAL (tanpa volume)"
fi

log "Working directory: $(pwd)"
log "Session DB : ${OPENCODE_DB}"
log "Persistent : ${PERSISTENT_LABEL}"
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    log "Public URL : https://${RAILWAY_PUBLIC_DOMAIN}"
fi
if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ] && [ -n "${RAILWAY_TCP_PROXY_PORT:-}" ]; then
    log "TCP URL    : ${RAILWAY_TCP_PROXY_DOMAIN}:${RAILWAY_TCP_PROXY_PORT}"
fi
log "Login password: ${OPENCODE_SERVER_PASSWORD} (${PASSWORD_SOURCE})"
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
