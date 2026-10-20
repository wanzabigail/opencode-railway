#!/usr/bin/env bash
# =============================================================================
# deploy.sh — deploy OpenCode (V2) terbaru ke Railway lewat Railway CLI
#
# Pemakaian:
#   ./deploy.sh
#
# Opsi environment (bisa lewat .env, lihat .env.example):
#   OPENCODE_SERVER_PASSWORD=...   (opsional; kalau kosong digenerate & disimpan)
#   PROJECT_NAME=opencode-railway
#   SERVICE_NAME=opencode-railway
#   APP_PORT=8080
#   PUBLIC_NETWORKING=http|tcp|both|none   (default: http)
#   TCP_PROXY_PORT=8080                    (default: APP_PORT)
#   ANTHROPIC_API_KEY / OPENAI_API_KEY / DEEPSEEK_API_KEY / ... (opsional)
#
# Login non-interaktif:
#   RAILWAY_TOKEN=... ./deploy.sh
#
# Fitur otomatis:
#   - Password kuat dibuat sekali (atau dipakai ulang dari Railway), diset
#     sebagai variable Railway, dan disimpan di ./.deploy-credentials.
#   - Public networking HTTP (domain *.up.railway.app) dan/atau TCP proxy
#     dibuat otomatis untuk service ini.
#   - Volume /data diverifikasi/dipasang agar session & workspace persisten.
# =============================================================================
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

if [ ! -f Dockerfile ] || [ ! -f railway.json ]; then
    die "Jalankan dari root repo opencode-railway (Dockerfile & railway.json tidak ditemukan)."
fi

PROJECT_NAME="${PROJECT_NAME:-opencode-railway}"
SERVICE_NAME="${SERVICE_NAME:-opencode-railway}"
APP_PORT="${APP_PORT:-8080}"
PUBLIC_NETWORKING="${PUBLIC_NETWORKING:-http}"
TCP_PROXY_PORT="${TCP_PROXY_PORT:-}"

# ---------------------------------------------------------------------------
# Load konfigurasi lokal
# ---------------------------------------------------------------------------
if [ -f .env ]; then
    info "Memuat .env"
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

# Password yang pernah digenerate dipakai ulang supaya tidak berubah tiap run.
if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ] && [ -f .deploy-credentials ]; then
    # shellcheck disable=SC1091
    . ./.deploy-credentials
fi

# Nilai lama dipakai sebagai fallback kalau pengecekan networking gagal.
PREVIOUS_PUBLIC_URL="${OPENCODE_PUBLIC_URL:-}"
PREVIOUS_TCP_ADDRESS="${OPENCODE_TCP_ADDRESS:-}"

# Tandai apakah password datang dari user/credentials. Kalau tidak, deploy.sh
# akan mencoba memakai password yang sudah ada di Railway sebelum membuat baru.
PASSWORD_EXPLICIT=0
if [ -n "${OPENCODE_SERVER_PASSWORD:-}" ]; then
    PASSWORD_EXPLICIT=1
fi

# APP_PORT bisa diubah lewat .env, jadi default TCP baru ditentukan di sini.
TCP_PROXY_PORT="${TCP_PROXY_PORT:-$APP_PORT}"

PUBLIC_NETWORKING="$(printf '%s' "${PUBLIC_NETWORKING:-http}" | tr '[:upper:]' '[:lower:]')"
case "$PUBLIC_NETWORKING" in
    http|https|http-only) PUBLIC_NETWORKING="http" ;;
    tcp|tcp-only)         PUBLIC_NETWORKING="tcp" ;;
    both|all|public)      PUBLIC_NETWORKING="both" ;;
    none|off|false)       PUBLIC_NETWORKING="none" ;;
    *) die "PUBLIC_NETWORKING harus 'http', 'tcp', 'both', atau 'none' (sekarang: ${PUBLIC_NETWORKING})." ;;
esac

case "$APP_PORT" in
    ''|*[!0-9]*) die "APP_PORT harus berupa angka (sekarang: ${APP_PORT})." ;;
esac
case "$TCP_PROXY_PORT" in
    ''|*[!0-9]*) die "TCP_PROXY_PORT harus berupa angka (sekarang: ${TCP_PROXY_PORT})." ;;
esac

# ---------------------------------------------------------------------------
# Validasi / dependency
# ---------------------------------------------------------------------------
if ! command -v railway >/dev/null 2>&1; then
    warn "Railway CLI belum terpasang."
    if command -v npm >/dev/null 2>&1; then
        info "Install Railway CLI: npm i -g @railway/cli"
        npm i -g @railway/cli
    else
        die "Install Railway CLI dulu: https://docs.railway.com/guides/cli"
    fi
fi

# ---------------------------------------------------------------------------
# Password
# ---------------------------------------------------------------------------
generate_password() {
    local length="${1:-32}" password=""
    while [ "${#password}" -lt "$length" ]; do
        password="${password}$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
    done
    printf '%s' "${password:0:$length}"
}

# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------
if [ -z "${RAILWAY_TOKEN:-}" ] && [ -z "${RAILWAY_API_TOKEN:-}" ]; then
    if ! railway whoami >/dev/null 2>&1; then
        info "Belum login ke Railway. Membuka proses login..."
        railway login
    fi
fi

# ---------------------------------------------------------------------------
# Project & service
# ---------------------------------------------------------------------------
if ! railway status --json >/dev/null 2>&1; then
    info "Membuat project Railway '${PROJECT_NAME}'..."
    if ! railway init --name "$PROJECT_NAME" --json >/tmp/railway-init.log 2>&1; then
        sed 's/^/    /' /tmp/railway-init.log >&2 || true
        die "Gagal membuat project Railway."
    fi
else
    info "Memakai project Railway yang sudah ter-link."
fi

service_exists() {
    local list flat
    list="$(railway service list --json 2>/dev/null || true)"
    if [ -n "$list" ]; then
        flat="$(printf '%s' "$list" | tr -d '\n\r')"
        case "$flat" in
            *"\"name\": \"${SERVICE_NAME}\""*) return 0 ;;
            *"\"name\":\"${SERVICE_NAME}\""*) return 0 ;;
        esac
        # Perintah list berhasil: jangan fallback ke status (bisa salah cocok
        # dengan nama project).
        return 1
    fi

    list="$(railway status --json 2>/dev/null || true)"
    [ -n "$list" ] || return 1
    flat="$(printf '%s' "$list" | tr -d '\n\r')"
    case "$flat" in
        *"\"name\": \"${SERVICE_NAME}\""*) return 0 ;;
        *"\"name\":\"${SERVICE_NAME}\""*) return 0 ;;
    esac
    return 1
}

if ! service_exists; then
    info "Membuat service '${SERVICE_NAME}'..."
    if ! railway add --service "$SERVICE_NAME" --json >/tmp/railway-add.log 2>&1; then
        if ! service_exists; then
            sed 's/^/    /' /tmp/railway-add.log >&2 || true
            die "Gagal membuat service otomatis. Jalankan 'railway link' lalu ulangi ./deploy.sh"
        fi
    fi
fi

# Volume dan domain selalu diarahkan ke service ini, bukan service lain yang
# kebetulan sedang ter-link.
info "Memilih service '${SERVICE_NAME}'..."
if ! railway service link "$SERVICE_NAME" >/dev/null 2>&1; then
    if ! railway link --service "$SERVICE_NAME" >/dev/null 2>&1; then
        die "Gagal link ke service '${SERVICE_NAME}'. Jalankan 'railway service link ${SERVICE_NAME}' lalu ulangi."
    fi
fi

# Jangan rotasi password yang sudah dipakai service kalau .deploy-credentials
# hilang (mis. deploy dari mesin lain). Ambil nilai yang ada di Railway.
if [ "$PASSWORD_EXPLICIT" -eq 0 ]; then
    REMOTE_VARS="$(railway variable list --kv --service "$SERVICE_NAME" 2>/dev/null || true)"
    if [ -z "$REMOTE_VARS" ]; then
        # CLI lama memakai subcommand jamak.
        REMOTE_VARS="$(railway variables --kv --service "$SERVICE_NAME" 2>/dev/null || true)"
    fi
    REMOTE_PASSWORD="$(printf '%s\n' "$REMOTE_VARS" \
        | sed -n 's/^OPENCODE_SERVER_PASSWORD=//p' \
        | tr -d '\r' \
        | head -n1 || true)"
    case "$REMOTE_PASSWORD" in
        ''|'<sealed>'|'null') REMOTE_PASSWORD="" ;;
    esac
    if [ -n "$REMOTE_PASSWORD" ]; then
        OPENCODE_SERVER_PASSWORD="$REMOTE_PASSWORD"
        PASSWORD_EXPLICIT=1
        info "Memakai password yang sudah ada di Railway (tidak dirotasi)."
    fi
fi

if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ]; then
    OPENCODE_SERVER_PASSWORD="$(generate_password 32)"
    info "OPENCODE_SERVER_PASSWORD kosong; password acak 32 karakter digenerate."
fi

if [ "${#OPENCODE_SERVER_PASSWORD}" -lt 16 ]; then
    warn "OPENCODE_SERVER_PASSWORD hanya ${#OPENCODE_SERVER_PASSWORD} karakter; sebaiknya minimal 16."
fi

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
if railway variable set --help >/dev/null 2>&1; then
    SETVAR_MODE="new"
    VAR_HELP="$(railway variable set --help 2>&1 || true)"
else
    SETVAR_MODE="old"
    VAR_HELP=""
fi

# Tunda deploy sampai semua variable selesai diset, lalu deploy sekali di akhir.
SETVAR_FLAGS=()
case "$VAR_HELP" in
    *--skip-deploys*) SETVAR_FLAGS+=(--skip-deploys) ;;
esac

set_var() {
    [ -n "${2:-}" ] || return 0
    if [ "$SETVAR_MODE" = "new" ]; then
        if [ "${#SETVAR_FLAGS[@]}" -gt 0 ]; then
            railway variable set "${SETVAR_FLAGS[@]}" "$1=$2" >/dev/null
        else
            railway variable set "$1=$2" >/dev/null
        fi
    else
        railway variables --set "$1=$2" >/dev/null
    fi
}

info "Menyetel environment variables..."
set_var NODE_ENV "production"
set_var PORT "$APP_PORT"
set_var OPENCODE_SERVER_PASSWORD "$OPENCODE_SERVER_PASSWORD"
set_var OPENCODE_DISABLE_AUTOUPDATE "true"
set_var OPENCODE_AUTO_UPDATE "${OPENCODE_AUTO_UPDATE:-true}"
set_var OPENCODE_AUTO_UPDATE_INTERVAL "${OPENCODE_AUTO_UPDATE_INTERVAL:-21600}"
set_var OPENCODE_LOW_RESOURCE "${OPENCODE_LOW_RESOURCE:-true}"

# Provider model (opsional). Hanya yang terisi yang dikirim.
for var in \
    OPENCODE_API_KEY \
    ANTHROPIC_API_KEY \
    OPENAI_API_KEY \
    OPENAI_BASE_URL \
    DEEPSEEK_API_KEY \
    DEEPSEEK_BASE_URL \
    OPENROUTER_API_KEY \
    OPENROUTER_BASE_URL \
    GOOGLE_GENERATIVE_AI_API_KEY \
    GEMINI_API_KEY \
    GROQ_API_KEY
do
    set_var "$var" "${!var:-}"
done

# ---------------------------------------------------------------------------
# Volume persisten
# ---------------------------------------------------------------------------
volume_has_data_path() {
    local json
    json="$(railway volume list --json 2>/dev/null || true)"
    if [ -n "$json" ]; then
        printf '%s' "$json" \
            | grep -Eq '"mountPath"[[:space:]]*:[[:space:]]*"/data"|"/data"' \
            && return 0
    fi
    railway volume list 2>/dev/null | grep -q '/data' && return 0
    return 1
}

ensure_volume() {
    if volume_has_data_path; then
        info "Volume /data sudah terpasang."
        return 0
    fi

    warn "Volume /data belum ada. Menambahkannya sekarang..."
    warn "Kalau service ini sudah pernah jalan, isi /data lama akan tertutup volume baru."
    if railway volume add --mount-path /data >/tmp/railway-volume.log 2>&1; then
        info "Volume /data ditambahkan."
        return 0
    fi

    # Kadang perintah add gagal karena volume sudah ada; cek ulang.
    if volume_has_data_path; then
        info "Volume /data sudah terpasang."
        return 0
    fi

    warn "Gagal menambahkan volume /data:"
    sed 's/^/    /' /tmp/railway-volume.log >&2 || true
    warn "Tambahkan manual: service → Settings → Volumes → Add Volume → mount path /data"
    return 1
}

info "Memastikan volume persisten..."
ensure_volume || die "Volume /data wajib ada agar session & workspace tidak hilang saat redeploy."

# ---------------------------------------------------------------------------
# Public networking (HTTP domain + TCP proxy)
# ---------------------------------------------------------------------------
HTTP_DOMAIN=""
TCP_ADDRESS=""

# Ambil semua nilai field "domain" dari JSON Railway (aman untuk JSON
# multi-baris maupun satu baris).
domain_fields() {
    grep -oE '"domain"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/^"domain"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/'
}

# Ambil domain dari output teks biasa (fallback CLI lama / bukan --json).
domain_from_text() {
    grep -oE '([A-Za-z0-9-]+\.)+up\.railway\.app' | head -n1 || true
}

# Ambil endpoint TCP proxy dari JSON atau teks.
tcp_endpoint_fields() {
    local json="$1" domain port endpoint
    domain="$(printf '%s' "$json" \
        | grep -oE '"domain"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/^"domain"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/' \
        | head -n1 || true)"
    port="$(printf '%s' "$json" \
        | grep -oE '"proxyPort"[[:space:]]*:[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+' \
        | head -n1 || true)"

    if [ -n "$domain" ] && [ -n "$port" ]; then
        printf '%s:%s' "$domain" "$port"
        return 0
    fi

    endpoint="$(printf '%s' "$json" \
        | grep -oE '"endpoint"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/^"endpoint"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/' \
        | head -n1 || true)"
    if [ -n "$endpoint" ]; then
        printf '%s' "$endpoint"
        return 0
    fi

    printf '%s' "$json" \
        | grep -oE '[A-Za-z0-9.-]+\.proxy\.rlwy\.net:[0-9]+' \
        | head -n1 || true
}

http_domain_from_list() {
    local json domain
    json="$(railway domain list --json --service "$SERVICE_NAME" 2>/dev/null || true)"
    [ -n "$json" ] || return 1

    # Utamakan domain Railway (*.up.railway.app), lalu domain lain (custom).
    domain="$(printf '%s' "$json" | domain_fields | grep -E '\.up\.railway\.app$' | head -n1 || true)"
    [ -n "$domain" ] || domain="$(printf '%s' "$json" | domain_fields | head -n1 || true)"
    [ -n "$domain" ] || return 1
    printf '%s' "$domain"
}

ensure_http_networking() {
    local json out text
    HTTP_DOMAIN="$(http_domain_from_list || true)"

    if [ -n "$HTTP_DOMAIN" ]; then
        info "Domain HTTP sudah ada: https://${HTTP_DOMAIN}"
        return 0
    fi

    info "Membuat domain publik HTTP (target port ${APP_PORT})..."
    out="$(railway domain --json --port "$APP_PORT" --service "$SERVICE_NAME" 2>&1 || true)"
    HTTP_DOMAIN="$(printf '%s' "$out" | domain_fields | head -n1 || true)"
    if [ -z "$HTTP_DOMAIN" ]; then
        HTTP_DOMAIN="$(printf '%s' "$out" | domain_from_text)"
    fi

    if [ -z "$HTTP_DOMAIN" ]; then
        sleep 2
        HTTP_DOMAIN="$(http_domain_from_list || true)"
    fi

    # Fallback terakhir: output tabel non-JSON dari CLI lama.
    if [ -z "$HTTP_DOMAIN" ]; then
        text="$(railway domain list --service "$SERVICE_NAME" 2>/dev/null || true)"
        HTTP_DOMAIN="$(printf '%s' "$text" | domain_from_text)"
    fi

    if [ -n "$HTTP_DOMAIN" ]; then
        info "Domain HTTP: https://${HTTP_DOMAIN}"
        return 0
    fi

    warn "Domain HTTP belum terbentuk otomatis."
    printf '%s\n' "$out" | sed 's/^/    /' >&2 || true
    warn "Coba manual: railway domain --port ${APP_PORT} --service ${SERVICE_NAME}"
    return 1
}

ensure_tcp_networking() {
    local json out endpoint app_port tries
    if ! railway tcp-proxy --help >/dev/null 2>&1; then
        warn "Railway CLI ini belum mendukung 'railway tcp-proxy'."
        warn "Upgrade CLI: railway upgrade --yes (atau npm i -g @railway/cli@latest)"
        return 1
    fi

    json="$(railway tcp-proxy list --json --service "$SERVICE_NAME" 2>/dev/null || true)"
    endpoint="$(tcp_endpoint_fields "$json")"

    if [ -z "$endpoint" ]; then
        out="$(railway tcp-proxy list --service "$SERVICE_NAME" 2>/dev/null || true)"
        endpoint="$(printf '%s' "$out" \
            | grep -oE '[A-Za-z0-9.-]+\.proxy\.rlwy\.net:[0-9]+' \
            | head -n1 || true)"
    fi

    if [ -n "$endpoint" ]; then
        app_port="$(printf '%s' "$json" \
            | grep -oE '"applicationPort"[[:space:]]*:[[:space:]]*[0-9]+' \
            | grep -oE '[0-9]+' \
            | head -n1 || true)"
        if [ -n "$app_port" ] && [ "$app_port" != "$TCP_PROXY_PORT" ]; then
            warn "TCP proxy sudah ada untuk port aplikasi ${app_port} (diminta ${TCP_PROXY_PORT})."
            warn "Hanya satu TCP proxy per service; proxy lama dipakai."
        fi
        TCP_ADDRESS="$endpoint"
        info "TCP proxy sudah ada: ${TCP_ADDRESS}"
        return 0
    fi

    info "Membuat TCP proxy (port aplikasi ${TCP_PROXY_PORT})..."
    out="$(railway tcp-proxy create --port "$TCP_PROXY_PORT" --service "$SERVICE_NAME" --json 2>&1 || true)"
    endpoint="$(tcp_endpoint_fields "$out")"

    # Kadang proxy baru terbaca beberapa detik setelah dibuat.
    tries=0
    while [ -z "$endpoint" ] && [ "$tries" -lt 5 ]; do
        sleep 2
        json="$(railway tcp-proxy list --json --service "$SERVICE_NAME" 2>/dev/null || true)"
        endpoint="$(tcp_endpoint_fields "$json")"
        tries=$((tries + 1))
    done

    if [ -n "$endpoint" ]; then
        TCP_ADDRESS="$endpoint"
        info "TCP proxy: ${TCP_ADDRESS}"
        return 0
    fi

    warn "TCP proxy belum terbentuk otomatis."
    printf '%s\n' "$out" | sed 's/^/    /' >&2 || true
    warn "Coba manual: railway tcp-proxy create --port ${TCP_PROXY_PORT} --service ${SERVICE_NAME}"
    return 1
}

ensure_public_networking() {
    local failed=0
    case "$PUBLIC_NETWORKING" in
        http)
            ensure_http_networking || failed=1
            ;;
        tcp)
            ensure_tcp_networking || failed=1
            ;;
        both)
            ensure_http_networking || failed=1
            ensure_tcp_networking || failed=1
            ;;
    esac
    return "$failed"
}

NETWORK_FAILED=0
if [ "$PUBLIC_NETWORKING" = "none" ]; then
    info "PUBLIC_NETWORKING=none: tidak membuat/mengecek public networking."
else
    info "Menyiapkan public networking (${PUBLIC_NETWORKING})..."
    ensure_public_networking || NETWORK_FAILED=1
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
info "Mendeploy (build Docker image di Railway)..."
railway up --detach --service "$SERVICE_NAME" \
    --message "deploy $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Domain/TCP bisa saja baru bisa dibuat setelah service punya deployment.
if [ "$PUBLIC_NETWORKING" != "none" ] && [ "$NETWORK_FAILED" -ne 0 ]; then
    info "Mencoba ulang public networking setelah deployment..."
    ensure_public_networking || true
fi

# ---------------------------------------------------------------------------
# Simpan kredensial lokal
# ---------------------------------------------------------------------------
URL="${HTTP_DOMAIN:+https://${HTTP_DOMAIN}}"
URL="${URL:-$PREVIOUS_PUBLIC_URL}"
TCP_ADDRESS="${TCP_ADDRESS:-$PREVIOUS_TCP_ADDRESS}"

umask 077
{
    printf '# Digenerate oleh deploy.sh pada %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# File ini di-ignore oleh git dan Docker.\n'
    printf 'OPENCODE_SERVER_PASSWORD=%q\n' "$OPENCODE_SERVER_PASSWORD"
    printf 'OPENCODE_PUBLIC_URL=%q\n' "$URL"
    printf 'OPENCODE_TCP_ADDRESS=%q\n' "$TCP_ADDRESS"
} > .deploy-credentials

cat <<EOF

=============================================================================
Deploy dikirim ke Railway.

  HTTP URL : ${URL:-<tidak dibuat>}
  TCP      : ${TCP_ADDRESS:-<tidak dibuat>}
  Password : ${OPENCODE_SERVER_PASSWORD}

Password dan URL juga disimpan di ./.deploy-credentials (jangan di-commit).

Public networking:
- HTTP domain dibuat otomatis bila PUBLIC_NETWORKING=http atau both.
- TCP proxy dibuat otomatis bila PUBLIC_NETWORKING=tcp atau both.
- Cek status:
    railway domain list --service ${SERVICE_NAME}
    railway tcp-proxy list --service ${SERVICE_NAME}

Setelah build selesai:
  railway logs          # pantau startup
  railway domain        # lihat URL publik

Cara connect:
- Browser  : buka URL di atas, masukkan password.
- CLI      : opencode --server <URL>   (username Basic Auth: opencode)
- API      : curl -u "opencode:<password>" <URL>/api/info
- TCP      : http://${TCP_ADDRESS:-<tcp-host:port>}  (TCP mentah, tanpa TLS)

Catatan:
- Volume /data menjaga session & workspace tetap ada saat redeploy.
- Password yang dipakai deploy.sh diset sebagai variable Railway, jadi
  tetap sama saat restart/redeploy.
- Kalau container dijalankan tanpa variable password (mis. deploy langsung
  dari dashboard), start.sh menyimpan password otomatis di volume:
  /data/home/.opencode-server-password
- Set API key provider (mis. ANTHROPIC_API_KEY) sebagai variable Railway
  agar model bisa dipakai, atau hubungkan provider lewat web UI.
=============================================================================
EOF
