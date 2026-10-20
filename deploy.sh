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
#   MIGRATE_EXISTING_DATA=true             (backup /data lama sebelum volume diubah)
#   MIGRATE_WORKSPACE=true                 (ikut migrasikan /data/workspace)
#   ALLOW_DATA_LOSS=true                   (skip migrasi; data ephemeral lama hilang)
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

# Saat script dijalankan dari dalam container Railway, Railway menyuntikkan
# RAILWAY_PROJECT_ID/ENVIRONMENT_ID/SERVICE_ID runtime. Railway CLI memberi
# prioritas pada variabel itu di atas project yang di-link, sehingga deploy
# bisa nyasar ke service tempat script berjalan. Hapus metadata runtime saja;
# RAILWAY_TOKEN / RAILWAY_API_TOKEN tetap dipakai untuk autentikasi.
RAILWAY_RUNTIME=0
if [ -n "${RAILWAY_DEPLOYMENT_ID:-}" ] || [ -n "${RAILWAY_REPLICA_ID:-}" ]; then
    RAILWAY_RUNTIME=1
    info "Terdeteksi runtime Railway; mengabaikan metadata RAILWAY_* runtime."
    unset RAILWAY_PROJECT_ID RAILWAY_PROJECT_NAME RAILWAY_ENVIRONMENT \
          RAILWAY_ENVIRONMENT_ID RAILWAY_ENVIRONMENT_NAME \
          RAILWAY_SERVICE_ID RAILWAY_SERVICE_NAME \
          RAILWAY_PRIVATE_DOMAIN RAILWAY_PUBLIC_DOMAIN RAILWAY_STATIC_URL \
          RAILWAY_DEPLOYMENT_ID RAILWAY_REPLICA_ID RAILWAY_SNAPSHOT_ID
    while IFS= read -r _railway_var; do
        unset "$_railway_var"
    done < <(compgen -v | grep -E '^RAILWAY_SERVICE_.*_URL$' || true)
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
    if [ "$RAILWAY_RUNTIME" = "1" ]; then
        die "Tidak ada project Railway yang di-link. Dari dalam container, jalankan: railway link --project <nama-project> --environment <nama-environment> --service ${SERVICE_NAME}"
    fi
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
# Volume persisten
#
# `railway volume list` berlaku untuk seluruh environment, bukan hanya service
# yang sedang di-link. Pengecekan lama yang hanya mencari string "/data" bisa
# false-positive karena volume milik service lain. Semua pengecekan di sini
# di-scope ke SERVICE_NAME, dan mount path harus persis "/data" tanpa spasi.
# ---------------------------------------------------------------------------
SERVICE_ID=""
SERVICE_DEPLOYMENT_ID=""
VOLUME_ID=""
VOLUME_NAME=""
VOLUME_MOUNT_RAW=""
VOLUME_SERVICE=""
VOLUME_STATUS=""
VOLUME_PENDING=""
VOLUME_CHANGED=0
VOLUME_CREATED=0
MIGRATION_BACKUP_DIR=""
MIGRATE_EXISTING_DATA="${MIGRATE_EXISTING_DATA:-false}"
MIGRATE_WORKSPACE="${MIGRATE_WORKSPACE:-false}"
ALLOW_DATA_LOSS="${ALLOW_DATA_LOSS:-false}"

resolve_service_id() {
    local json id deployment_id
    if [ -n "$SERVICE_ID" ]; then
        return 0
    fi

    # Untuk service yang sudah punya deployment, ini paling sederhana.
    json="$(railway service status --json 2>/dev/null || true)"
    if [ -n "$json" ]; then
        id="$(printf '%s' "$json" \
            | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | head -n1 \
            | sed -E 's/.*"([^"]+)"$/\1/' || true)"
        deployment_id="$(printf '%s' "$json" \
            | grep -oE '"deploymentId"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | head -n1 \
            | sed -E 's/.*"([^"]+)"$/\1/' || true)"
        if [ -n "$deployment_id" ] && [ "$deployment_id" != "null" ]; then
            SERVICE_DEPLOYMENT_ID="$deployment_id"
        fi
        if [ -n "$id" ]; then
            SERVICE_ID="$id"
            return 0
        fi
    fi

    # Fallback: `railway service list --json` (array of services).
    json="$(railway service list --json 2>/dev/null || true)"
    if [ -n "$json" ]; then
        if command -v node >/dev/null 2>&1; then
            id="$(printf '%s' "$json" | node -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  let data;
  try { data = JSON.parse(input); } catch { process.exit(2); }
  const name = process.argv[1];
  const rows = Array.isArray(data) ? data : (data.services || []);
  const service = rows.find((row) => row.name === name);
  if (!service || !service.id) process.exit(1);
  process.stdout.write(service.id);
});
' "$SERVICE_NAME" 2>/dev/null || true)"
        elif command -v python3 >/dev/null 2>&1; then
            id="$(printf '%s' "$json" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)

name = sys.argv[1]
rows = data if isinstance(data, list) else data.get("services", [])
service = next((row for row in rows if row.get("name") == name), None)
if not service or not service.get("id"):
    sys.exit(1)
sys.stdout.write(service["id"])
' "$SERVICE_NAME" 2>/dev/null || true)"
        fi
    fi

    [ -n "$id" ] || return 1
    SERVICE_ID="$id"
}

# Perintah volume selalu memakai service ini. Kalau service ID tidak terbaca,
# perintah tetap jalan memakai service yang sedang ter-link.
volume_cmd() {
    local subcommand="$1"
    shift
    if [ -n "$SERVICE_ID" ]; then
        # --service adalah opsi parent, harus sebelum subcommand.
        railway volume --service "$SERVICE_ID" "$subcommand" "$@"
    else
        railway volume "$subcommand" "$@"
    fi
}

strip_ansi() {
    sed $'s/\033\\[[0-9;]*[A-Za-z]//g'
}

normalize_mount_path() {
    printf '%s' "${1:-}" \
        | tr -d '\r' \
        | sed -E 's/[[:space:]]+$//'
}

# Output baris TSV dengan pemisah unit separator (0x1f):
#   id, name, mountPath, serviceName, status, isPendingDeletion
volume_rows() {
    local json
    json="$(railway volume list --json 2>/dev/null || true)"
    if [ -n "$json" ]; then
        if command -v node >/dev/null 2>&1; then
            if printf '%s' "$json" | node -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  let data;
  try { data = JSON.parse(input); } catch { process.exit(2); }
  const volumes = Array.isArray(data) ? data : (data.volumes || []);
  const clean = (value) => String(value ?? "").replace(/[\t\r\n\u001f]+/g, " ");
  for (const volume of volumes) {
    console.log([
      volume.id,
      volume.name,
      volume.mountPath,
      volume.serviceName,
      volume.status,
      volume.isPendingDeletion,
    ].map(clean).join("\u001f"));
  }
});
'; then
                return 0
            fi
        elif command -v python3 >/dev/null 2>&1; then
            if printf '%s' "$json" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)

volumes = data if isinstance(data, list) else data.get("volumes", [])
for volume in volumes:
    values = [
        volume.get("id", ""),
        volume.get("name", ""),
        volume.get("mountPath", ""),
        volume.get("serviceName", ""),
        volume.get("status", ""),
        volume.get("isPendingDeletion", ""),
    ]
    cleaned = []
    for value in values:
        if value is None:
            text = ""
        elif isinstance(value, bool):
            text = "true" if value else "false"
        else:
            text = str(value)
        for char in ("\t", "\r", "\n", "\x1f"):
            text = text.replace(char, " ")
        cleaned.append(text)
    print("\x1f".join(cleaned))
'; then
                return 0
            fi
        fi
    fi

    # Fallback untuk CLI lama / tanpa Node/Python: parse output teks.
    railway volume list 2>/dev/null \
        | strip_ansi \
        | awk '
            function emit() {
                if (name != "") {
                    printf "%s\037%s\037%s\037%s\037%s\037%s\n", name, name, mount, service, status, "false"
                }
            }
            /^Volume:[[:space:]]*/ {
                emit()
                name = $0
                sub(/^Volume:[[:space:]]*/, "", name)
                service = ""
                mount = ""
                status = ""
                next
            }
            /^Attached to:[[:space:]]*/ {
                service = $0
                sub(/^Attached to:[[:space:]]*/, "", service)
                if (service == "N/A") service = ""
                next
            }
            /^Mount path:[[:space:]]*/ {
                mount = $0
                sub(/^Mount path:[[:space:]]*/, "", mount)
                next
            }
            /^Status:[[:space:]]*/ {
                status = $0
                sub(/^Status:[[:space:]]*/, "", status)
                next
            }
            END { emit() }
        '
}

read_volume_row() {
    IFS=$'\037' read -r VOLUME_ID VOLUME_NAME VOLUME_MOUNT_RAW \
        VOLUME_SERVICE VOLUME_STATUS VOLUME_PENDING <<< "$1"
}

refresh_attached_volume() {
    local rows row
    rows="$(volume_rows | awk -F '\037' -v service="$SERVICE_NAME" '
        $4 == service && tolower($6) != "true" && tolower($5) !~ /^(deleting|deleted)$/ { print }
    ')"
    [ -n "$rows" ] || return 1

    # Utamakan volume yang sudah tepat di /data. Kalau tidak ada, volume dengan
    # mount path /data + spasi (yang bisa diperbaiki) lebih dipilih daripada
    # volume lain milik service yang sama.
    row="$(printf '%s\n' "$rows" | awk -F '\037' '$3 == "/data" { print; exit }')"
    if [ -z "$row" ]; then
        row="$(printf '%s\n' "$rows" | awk -F '\037' '
            { mount = $3; sub(/[[:space:]]+$/, "", mount) }
            mount == "/data" { print; exit }
        ')"
    fi
    if [ -z "$row" ]; then
        row="$(printf '%s\n' "$rows" | head -n1)"
    fi

    [ -n "$row" ] || return 1
    read_volume_row "$row"
    return 0
}

detached_volume_rows() {
    volume_rows | awk -F '\037' '
        ($4 == "" || $4 == "N/A") && tolower($6) != "true" && tolower($5) !~ /^(deleting|deleted)$/ {
            mount = $3
            sub(/[[:space:]]+$/, "", mount)
            if (mount == "/data") print
        }
    '
}

wait_for_attached_volume() {
    local tries=0
    while [ "$tries" -lt 15 ]; do
        if refresh_attached_volume; then
            return 0
        fi
        sleep 2
        tries=$((tries + 1))
    done
    return 1
}

wait_for_exact_mount_path() {
    local tries=0
    while [ "$tries" -lt 15 ]; do
        if refresh_attached_volume && [ "$VOLUME_MOUNT_RAW" = "/data" ]; then
            return 0
        fi
        sleep 2
        tries=$((tries + 1))
    done
    return 1
}

ensure_volume_mount_path() {
    local normalized
    normalized="$(normalize_mount_path "$VOLUME_MOUNT_RAW")"

    if [ "$VOLUME_MOUNT_RAW" = "/data" ]; then
        return 0
    fi

    if [ "$normalized" = "/data" ]; then
        warn "Mount path volume '${VOLUME_NAME}' berisi spasi di akhir ('${VOLUME_MOUNT_RAW}')."
        warn "Railway akan me-mount volume di path yang salah; memperbaiki ke '/data'..."
    else
        warn "Mount path volume '${VOLUME_NAME}' adalah '${VOLUME_MOUNT_RAW}', bukan '/data'."
        warn "Memindahkan mount path ke '/data' (isi volume dipertahankan)..."
    fi

    if ! volume_cmd update --volume "$VOLUME_ID" --mount-path /data >/tmp/railway-volume.log 2>&1; then
        warn "Gagal memperbaiki mount path volume:"
        sed 's/^/    /' /tmp/railway-volume.log >&2 || true
        return 1
    fi
    VOLUME_CHANGED=1

    if ! wait_for_exact_mount_path; then
        warn "Mount path volume masih '${VOLUME_MOUNT_RAW}' setelah update."
        return 1
    fi
    return 0
}

bool_true() {
    case "${1:-false}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

backup_existing_data() {
    local stamp dir
    if ! railway service files --help >/dev/null 2>&1; then
        warn "Railway CLI ini belum mendukung 'railway service files'."
        warn "Upgrade CLI: railway upgrade --yes (atau npm i -g @railway/cli@latest)"
        return 1
    fi
    if ! railway volume files --help >/dev/null 2>&1; then
        warn "Railway CLI ini belum mendukung 'railway volume files'."
        warn "Upgrade CLI: railway upgrade --yes (atau npm i -g @railway/cli@latest)"
        return 1
    fi

    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    dir=".deploy-backup/recovery-${stamp}"
    mkdir -p "$dir"

    info "Menyimpan /data/home dari deployment yang sedang berjalan ke ${dir}/home..."
    if ! railway service files --service "$SERVICE_NAME" download /data/home "$dir/home" --overwrite >/tmp/railway-backup.log 2>&1; then
        warn "Gagal backup /data/home:"
        sed 's/^/    /' /tmp/railway-backup.log >&2 || true
        return 1
    fi

    if bool_true "$MIGRATE_WORKSPACE"; then
        info "Menyimpan /data/workspace ke ${dir}/workspace..."
        if ! railway service files --service "$SERVICE_NAME" download /data/workspace "$dir/workspace" --overwrite >>/tmp/railway-backup.log 2>&1; then
            warn "Gagal backup /data/workspace:"
            sed 's/^/    /' /tmp/railway-backup.log >&2 || true
            return 1
        fi
    fi

    MIGRATION_BACKUP_DIR="$dir"
    info "Backup selesai: ${dir}"
    return 0
}

preflight_existing_data() {
    if [ -z "$SERVICE_DEPLOYMENT_ID" ]; then
        return 0
    fi

    # Kalau volume sudah terpasang tepat di /data, tidak ada data yang akan
    # tertutup oleh perubahan volume.
    if refresh_attached_volume && [ "$VOLUME_MOUNT_RAW" = "/data" ]; then
        return 0
    fi

    warn "Service '${SERVICE_NAME}' sedang berjalan tanpa volume /data yang benar."
    warn "Membuat/melampirkan/memperbaiki volume akan menyembunyikan isi /data"
    warn "yang sekarang (session, config, workspace)."

    # Migrasi menang kalau kedua flag aktif: jangan buang data hanya karena
    # ALLOW_DATA_LOSS juga ter-set di .env.
    if bool_true "$MIGRATE_EXISTING_DATA"; then
        info "MIGRATE_EXISTING_DATA aktif: backup otomatis sebelum volume diubah..."
        if ! backup_existing_data; then
            die "Backup otomatis gagal; volume belum diubah, data lama masih aman. Backup manual lalu ulangi."
        fi
        return 0
    fi

    if bool_true "$ALLOW_DATA_LOSS"; then
        warn "ALLOW_DATA_LOSS aktif: isi /data lama tidak dipindahkan ke volume."
        return 0
    fi

    warn "Backup manual:"
    warn "  railway service files --service ${SERVICE_NAME} download /data/home ./.deploy-backup/home --overwrite"
    warn "  railway service files --service ${SERVICE_NAME} download /data/workspace ./.deploy-backup/workspace --overwrite"
    die "Dibatalkan agar data lama tidak hilang. Backup dulu, lalu jalankan lagi dengan MIGRATE_EXISTING_DATA=true. Kalau data lama tidak diperlukan: ALLOW_DATA_LOSS=true ./deploy.sh"
}

restore_migration_backup() {
    [ -n "$MIGRATION_BACKUP_DIR" ] || return 0
    if [ -z "$VOLUME_ID" ]; then
        warn "Volume ID tidak diketahui; upload backup dilewati."
        return 1
    fi

    if [ "$VOLUME_CREATED" -eq 1 ]; then
        # Volume baru/kosong: isi backup menjadi state utama.
        info "Mengunggah backup ke volume baru /data (${VOLUME_NAME:-$VOLUME_ID})..."
        if ! railway volume files --volume "$VOLUME_ID" upload "$MIGRATION_BACKUP_DIR/home" / --overwrite >/tmp/railway-restore.log 2>&1; then
            warn "Gagal upload backup home ke volume:"
            sed 's/^/    /' /tmp/railway-restore.log >&2 || true
            return 1
        fi

        if [ -d "$MIGRATION_BACKUP_DIR/workspace" ]; then
            info "Mengunggah workspace ke volume..."
            if ! railway volume files --volume "$VOLUME_ID" upload "$MIGRATION_BACKUP_DIR/workspace" / --overwrite >>/tmp/railway-restore.log 2>&1; then
                warn "Gagal upload backup workspace ke volume:"
                sed 's/^/    /' /tmp/railway-restore.log >&2 || true
                return 1
            fi
        fi
    else
        # Volume sudah punya data. Jangan timpa database/session lama; simpan
        # backup saat ini di folder terpisah agar bisa digabung manual.
        info "Volume sudah berisi data; menyimpan backup saat ini ke /recovery-..."
        if ! railway volume files --volume "$VOLUME_ID" upload "$MIGRATION_BACKUP_DIR" / --overwrite >/tmp/railway-restore.log 2>&1; then
            warn "Gagal upload folder recovery ke volume:"
            sed 's/^/    /' /tmp/railway-restore.log >&2 || true
            return 1
        fi
        warn "Backup saat ini disimpan di volume pada /$(basename "$MIGRATION_BACKUP_DIR")/home"
        warn "Volume tetap memakai data lamanya. Gabungkan manual bila perlu."
    fi

    info "Backup berhasil diunggah ke volume. Data lokal tetap ada di ${MIGRATION_BACKUP_DIR}."
    return 0
}

ensure_volume() {
    local row candidate="" ignored_detached=0

    if ! preflight_existing_data; then
        return 1
    fi

    if refresh_attached_volume; then
        if ensure_volume_mount_path; then
            info "Volume /data sudah terpasang di service '${SERVICE_NAME}' (${VOLUME_NAME})."
            return 0
        fi
        warn "Volume ada tetapi mount path belum bisa diperbaiki otomatis."
        warn "Perbaiki manual: railway volume update --volume ${VOLUME_ID:-$VOLUME_NAME} --mount-path /data"
        return 1
    fi

    # Cari volume detached yang sudah di /data. Volume ini mungkin berisi data
    # dari deployment sebelumnya, jadi lebih baik dipakai ulang daripada
    # membuat volume kosong baru. Hanya volume yang namanya mengandung nama
    # service ini yang dipakai otomatis, supaya volume milik service lain
    # (volume list berlaku environment-wide) tidak ikut ter-attach.
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        read_volume_row "$row"
        case "$(printf '%s' "$VOLUME_NAME" | tr '[:upper:]' '[:lower:]')" in
            *"$(printf '%s' "$SERVICE_NAME" | tr '[:upper:]' '[:lower:]')"*)
                candidate="$row"
                break
                ;;
            *)
                ignored_detached=$((ignored_detached + 1))
                ;;
        esac
    done < <(detached_volume_rows)

    if [ -n "$candidate" ]; then
        read_volume_row "$candidate"
        warn "Menemukan volume detached '${VOLUME_NAME}' di /data; melampirkan ke service '${SERVICE_NAME}'..."
        if volume_cmd attach --volume "$VOLUME_ID" --yes >/tmp/railway-volume.log 2>&1; then
            VOLUME_CHANGED=1
            if wait_for_attached_volume && ensure_volume_mount_path; then
                info "Volume /data berhasil dilampirkan (${VOLUME_NAME})."
                return 0
            fi
            warn "Volume ter-lampir tetapi belum terverifikasi."
        else
            warn "Gagal melampirkan volume '${VOLUME_NAME}':"
            sed 's/^/    /' /tmp/railway-volume.log >&2 || true
            warn "Volume mungkin masih terpasang di service lain. Akan dibuat volume baru."
        fi
    fi

    if [ "$ignored_detached" -gt 0 ]; then
        warn "Ada ${ignored_detached} volume detached di /data yang namanya tidak cocok dengan service '${SERVICE_NAME}'; tidak dipakai otomatis."
        warn "Kalau itu volume lama service ini, attach manual: railway volume --service ${SERVICE_ID:-<service-id>} attach --volume <id> --yes"
    fi

    # Service ini belum punya volume. Preflight di atas sudah memberi tahu
    # kalau ada data ephemeral yang perlu dimigrasikan.
    info "Service '${SERVICE_NAME}' belum punya volume /data; membuat volume baru..."
    if ! volume_cmd add --mount-path /data --json >/tmp/railway-volume.log 2>&1; then
        # Kadang volume sudah terbentuk tetapi output perintah gagal.
        if refresh_attached_volume && ensure_volume_mount_path; then
            VOLUME_CHANGED=1
            VOLUME_CREATED=1
            info "Volume /data sudah terpasang (${VOLUME_NAME})."
            return 0
        fi
        warn "Gagal membuat volume /data:"
        sed 's/^/    /' /tmp/railway-volume.log >&2 || true
        warn "Tambahkan manual: Railway → service → Settings → Volumes → Add Volume → /data"
        return 1
    fi
    VOLUME_CHANGED=1
    VOLUME_CREATED=1

    if ! wait_for_attached_volume; then
        warn "Volume baru belum terlihat di service '${SERVICE_NAME}' setelah 30 detik."
        warn "Cek: railway volume list --json"
        return 1
    fi

    if ! ensure_volume_mount_path; then
        return 1
    fi

    info "Volume /data dibuat dan terpasang (${VOLUME_NAME})."
    return 0
}

# Resolve service ID setelah service di-link. Ini membuat operasi volume
# ter-scope ke service ini walau service lain punya volume /data.
if resolve_service_id; then
    info "Service ID: ${SERVICE_ID}"
else
    warn "Service ID tidak terbaca; perintah volume akan memakai service yang ter-link."
fi

info "Memastikan volume persisten..."
if ! ensure_volume; then
    die "Volume /data wajib terpasang agar session & workspace tidak hilang saat redeploy."
fi
if [ "$VOLUME_CHANGED" -eq 1 ]; then
    info "Volume berubah; deployment setelah ini akan me-mount /data."
fi
if [ -n "$MIGRATION_BACKUP_DIR" ]; then
    if ! restore_migration_backup; then
        die "Upload backup ke volume gagal. Data lama masih aman di ${MIGRATION_BACKUP_DIR}; redeploy dibatalkan. Perbaiki error lalu upload manual dengan 'railway volume files --volume <id> upload ... / --overwrite'."
    fi
fi

# ---------------------------------------------------------------------------
# Variables
#
# Diset setelah volume siap. Dengan begitu, kalau CLI lama memicu redeploy saat
# variable berubah, data ephemeral sudah sempat dimigrasikan/diamankan lebih
# dulu.
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
set_var OPENCODE_HOME "${OPENCODE_HOME:-}"
set_var OPENCODE_PASSWORD_FILE "${OPENCODE_PASSWORD_FILE:-}"
set_var OPENCODE_DB "${OPENCODE_DB:-}"
set_var ALLOW_EPHEMERAL_DATA "${ALLOW_EPHEMERAL_DATA:-}"

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
# Public networking (HTTP domain + TCP proxy)
# ---------------------------------------------------------------------------
HTTP_DOMAIN=""
TCP_ADDRESS=""

# Railway CLI 5.71 mengembalikan "domain": "https://..." untuk create,
# sedangkan list mengembalikan hostname. Normalisasi ke hostname saja supaya
# URL yang disimpan tidak menjadi "https://https://...".
normalize_domain() {
    sed -E 's#^[[:space:]]*https?://##; s#/+$##; s/[[:space:]]+$//'
}

# Ambil semua nilai field "domain" dari JSON Railway (aman untuk JSON
# multi-baris maupun satu baris).
domain_fields() {
    grep -oE '"domain"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/^"domain"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/' \
        | normalize_domain
}

# Ambil domain dari output teks biasa (fallback CLI lama / bukan --json).
domain_from_text() {
    grep -oE '([A-Za-z0-9-]+\.)+up\.railway\.app' | head -n1 | normalize_domain || true
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

    # Pastikan semua sumber (create/list/teks) menghasilkan hostname saja.
    HTTP_DOMAIN="$(printf '%s' "$HTTP_DOMAIN" | normalize_domain)"

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
