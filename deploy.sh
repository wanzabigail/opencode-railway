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

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
if railway variable set --help >/dev/null 2>&1; then
    SETVAR_MODE="new"
else
    SETVAR_MODE="old"
fi

set_var() {
    [ -n "${2:-}" ] || return 0
    if [ "$SETVAR_MODE" = "new" ]; then
        railway variable set "$1=$2" >/dev/null
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
info "Memastikan volume /data terpasang..."
if ! railway volume add --mount-path /data >/dev/null 2>&1; then
    warn "Volume /data tidak bisa dibuat otomatis (mungkin sudah ada)."
    warn "Pastikan volume dengan mount path /data terpasang di dashboard Railway."
fi

# ---------------------------------------------------------------------------
# Domain publik
# ---------------------------------------------------------------------------
info "Menyiapkan domain publik..."
DOMAIN_OUT="$(railway domain --port "$APP_PORT" 2>&1 || true)"
DOMAIN="$(printf '%s' "$DOMAIN_OUT" | grep -oE 'https?://[A-Za-z0-9._-]+' | sed -n '1p' || true)"

if [ -z "$DOMAIN" ]; then
    DOMAIN_OUT="$(railway domain list --json 2>/dev/null || true)"
    DOMAIN="$(printf '%s' "$DOMAIN_OUT" | grep -oE 'https?://[A-Za-z0-9._-]+' | sed -n '1p' || true)"
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
info "Mendeploy (build Docker image di Railway)..."
railway up --detach --message "deploy $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# Simpan kredensial lokal
# ---------------------------------------------------------------------------
umask 077
cat > .deploy-credentials <<EOF
# Digenerate oleh deploy.sh pada $(date -u +%Y-%m-%dT%H:%M:%SZ)
# File ini di-ignore oleh git dan Docker.
OPENCODE_SERVER_PASSWORD=${OPENCODE_SERVER_PASSWORD}
EOF

cat <<EOF

=============================================================================
Deploy dikirim ke Railway.

  URL      : ${DOMAIN:-<generate via: railway domain --port ${APP_PORT}>}
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
