#!/usr/bin/env bash
# =============================================================================
# deploy.sh — deploy OpenCode (V2) terbaru ke Railway lewat Railway CLI
#
# Pemakaian:
#   ./deploy.sh
#
# Opsi environment (bisa lewat .env, lihat .env.example):
#   OPENCODE_SERVER_PASSWORD=...   (wajib; kalau kosong digenerate & disimpan)
#   PROJECT_NAME=opencode-railway
#   SERVICE_NAME=opencode-railway
#   APP_PORT=8080
#   ANTHROPIC_API_KEY / OPENAI_API_KEY / DEEPSEEK_API_KEY / ... (opsional)
#
# Login non-interaktif:
#   RAILWAY_TOKEN=... ./deploy.sh
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

if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ]; then
    OPENCODE_SERVER_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
    info "OPENCODE_SERVER_PASSWORD tidak di-set; password acak digenerate."
fi

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
    railway init --name "$PROJECT_NAME"
else
    info "Memakai project Railway yang sudah ter-link."
fi

STATUS_JSON="$(railway status --json 2>/dev/null || true)"
if ! printf '%s' "$STATUS_JSON" | grep -Eq '"service"[[:space:]]*:[[:space:]]*\{'; then
    info "Membuat service '${SERVICE_NAME}'..."
    if ! railway add --service "$SERVICE_NAME"; then
        die "Gagal membuat service otomatis. Jalankan 'railway link' lalu ulangi ./deploy.sh"
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

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
if railway variable set --help >/dev/null 2>&1; then
    SETVAR_MODE="new"
else
    SETVAR_MODE="old"
fi

# Tunda deploy sampai semua variable selesai diset, lalu deploy sekali di akhir.
SETVAR_FLAGS=()
if railway variable set --help 2>&1 | grep -q -- '--skip-deploys'; then
    SETVAR_FLAGS+=(--skip-deploys)
fi

set_var() {
    [ -n "${2:-}" ] || return 0
    if [ "$SETVAR_MODE" = "new" ]; then
        railway variable set "${SETVAR_FLAGS[@]}" "$1=$2" >/dev/null
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
# Deploy
# ---------------------------------------------------------------------------
info "Mendeploy (build Docker image di Railway)..."
railway up --detach --message "deploy $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# Domain publik (dibuat setelah service punya deployment)
# ---------------------------------------------------------------------------
DOMAIN=""

extract_domain() {
    sed -n 's/.*"domain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

ensure_domain() {
    local json out
    json="$(railway domain list --json --service "$SERVICE_NAME" 2>/dev/null || true)"
    DOMAIN="$(printf '%s' "$json" | extract_domain)"
    if [ -n "$DOMAIN" ]; then
        info "Domain sudah ada: https://${DOMAIN}"
        return 0
    fi

    info "Membuat domain publik (target port ${APP_PORT})..."
    out="$(railway domain --port "$APP_PORT" --service "$SERVICE_NAME" 2>&1 || true)"
    DOMAIN="$(printf '%s' "$out" | grep -oE '([A-Za-z0-9-]+\.)+up\.railway\.app' | head -n1 || true)"

    if [ -z "$DOMAIN" ]; then
        json="$(railway domain list --json --service "$SERVICE_NAME" 2>/dev/null || true)"
        DOMAIN="$(printf '%s' "$json" | extract_domain)"
    fi

    if [ -n "$DOMAIN" ]; then
        info "Domain: https://${DOMAIN}"
        return 0
    fi

    warn "Domain belum terbentuk otomatis. Cek: railway domain list --service ${SERVICE_NAME}"
    return 1
}

info "Menyiapkan domain publik..."
ensure_domain || true

# ---------------------------------------------------------------------------
# Simpan kredensial lokal
# ---------------------------------------------------------------------------
umask 077
cat > .deploy-credentials <<EOF
# Digenerate oleh deploy.sh pada $(date -u +%Y-%m-%dT%H:%M:%SZ)
# File ini di-ignore oleh git dan Docker.
OPENCODE_SERVER_PASSWORD=${OPENCODE_SERVER_PASSWORD}
EOF

URL="${DOMAIN:+https://${DOMAIN}}"

cat <<EOF

=============================================================================
Deploy dikirim ke Railway.

  URL      : ${URL:-<generate via: railway domain --port ${APP_PORT} --service ${SERVICE_NAME}>}
  Password : ${OPENCODE_SERVER_PASSWORD}

Password juga disimpan di ./.deploy-credentials (jangan di-commit).

Setelah build selesai:
  railway logs          # pantau startup
  railway domain        # lihat URL publik

Cara connect:
- Browser  : buka URL, masukkan password di atas.
- CLI      : opencode --server <URL>   (username Basic Auth: opencode)
- API      : curl -u "opencode:<password>" <URL>/api/info

Catatan:
- Volume /data menjaga session & workspace tetap ada saat redeploy.
- Set API key provider (mis. ANTHROPIC_API_KEY) sebagai variable Railway
  agar model bisa dipakai, atau hubungkan provider lewat web UI.
=============================================================================
EOF
