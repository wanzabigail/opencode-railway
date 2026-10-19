#!/usr/bin/env bash
# =============================================================================
# push-github.sh — commit & push proyek ini ke GitHub
#
# Pemakaian:
#   ./push-github.sh
#
# Opsi environment:
#   REPO_NAME   nama repo (default: opencode-railway)
#   OWNER       owner/org GitHub (default: user yang login)
#   VISIBILITY  public | private (default: public)
#   GITHUB_TOKEN  Personal Access Token (scope "repo") untuk push non-interaktif
#
# Urutan auth:
#   1. Kalau `gh` sudah login -> pakai gh
#   2. Kalau GITHUB_TOKEN ada  -> pakai REST API + HTTPS
#   3. Selain itu              -> jalankan `gh auth login`
#
# Catatan: SSH ke github.com:22 diblokir di lingkungan ini, jadi selalu HTTPS.
# =============================================================================
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

REPO_NAME="${REPO_NAME:-opencode-railway}"
VISIBILITY="${VISIBILITY:-public}"
BRANCH="${BRANCH:-main}"

case "$VISIBILITY" in
    public|private) ;;
    *) die "VISIBILITY harus 'public' atau 'private' (sekarang: $VISIBILITY)" ;;
esac

command -v git >/dev/null 2>&1 || die "git tidak terpasang."

# ---------------------------------------------------------------------------
# Repo lokal
# ---------------------------------------------------------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    info "Inisialisasi repo git lokal (branch ${BRANCH})..."
    git init -b "$BRANCH"
fi

git add -A
if ! git diff --cached --quiet; then
    git commit -m "OpenCode V2 on Railway (Docker + deploy scripts)" >/dev/null
    info "Commit dibuat."
else
    info "Tidak ada perubahan untuk di-commit."
fi

# Jangan pernah push file rahasia.
if git ls-files --error-unmatch .env >/dev/null 2>&1; then
    die ".env ter-track git. Hapus dengan: git rm --cached .env"
fi
if git ls-files --error-unmatch .deploy-credentials >/dev/null 2>&1; then
    die ".deploy-credentials ter-track git. Hapus dengan: git rm --cached .deploy-credentials"
fi

# ---------------------------------------------------------------------------
# Auth + buat repo
# ---------------------------------------------------------------------------
OWNER="${OWNER:-}"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    info "Memakai GitHub CLI yang sudah login."
    if gh repo view "${OWNER:+$OWNER/}$REPO_NAME" >/dev/null 2>&1; then
        info "Repo sudah ada; memakai remote yang ada."
    else
        info "Membuat repo ${REPO_NAME} (${VISIBILITY})..."
        gh repo create "${OWNER:+$OWNER/}$REPO_NAME" "--$VISIBILITY" \
            --source=. --remote=origin --push
        info "Selesai: $(gh repo view "${OWNER:+$OWNER/}$REPO_NAME" --json url -q .url)"
        exit 0
    fi
    gh repo set-default "${OWNER:+$OWNER/}$REPO_NAME" >/dev/null 2>&1 || true
    if ! git remote get-url origin >/dev/null 2>&1; then
        git remote add origin "https://github.com/${OWNER:+$OWNER/}${REPO_NAME}.git"
    fi
    git push -u origin "$BRANCH"
    info "Selesai: https://github.com/${OWNER:+$OWNER/}${REPO_NAME}"
    exit 0
fi

# --- Fallback: GITHUB_TOKEN ---
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    info "Belum login. Menjalankan 'gh auth login'..."
    gh auth login --hostname github.com --git-protocol https --web
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
    die "Tidak ada kredensial. Set GITHUB_TOKEN atau jalankan 'gh auth login'."
fi

command -v curl >/dev/null 2>&1 || die "curl tidak terpasang (dibutuhkan untuk GITHUB_TOKEN)."

API="https://api.github.com"
AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"

if [ -z "$OWNER" ]; then
    OWNER="$(curl -fsS -H "$AUTH_HEADER" -H 'Accept: application/vnd.github+json' \
        "$API/user" | sed -n 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$OWNER" ] || die "Gagal membaca user GitHub dari token."
fi

FULL="${OWNER}/${REPO_NAME}"
info "Target repo: ${FULL}"

CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH_HEADER" "$API/repos/${FULL}")"
if [ "$CODE" = "404" ]; then
    info "Membuat repo ${FULL} (${VISIBILITY})..."
    PAYLOAD="{\"name\":\"${REPO_NAME}\",\"private\":$([ "$VISIBILITY" = private ] && echo true || echo false),\"auto_init\":false}"
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        -H "$AUTH_HEADER" -H 'Accept: application/vnd.github+json' \
        -d "$PAYLOAD" "$API/user/repos")"
    [ "$CODE" = "201" ] || die "Gagal membuat repo (HTTP ${CODE})."
elif [ "$CODE" != "200" ]; then
    die "Tidak bisa mengakses repo ${FULL} (HTTP ${CODE}). Cek scope token."
fi

# Push lewat HTTPS dengan token, lalu kembalikan remote ke URL bersih.
git remote remove origin >/dev/null 2>&1 || true
git remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${FULL}.git"
git push -u origin "$BRANCH"
git remote set-url origin "https://github.com/${FULL}.git"

info "Selesai: https://github.com/${FULL}"
