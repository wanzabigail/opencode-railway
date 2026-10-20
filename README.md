# OpenCode V2 di Railway

Menjalankan **OpenCode V2 terbaru** di [Railway](https://railway.com) sebagai
server selalu-aktif, lengkap dengan web UI, API, dan workspace persisten.

```
Internet ──HTTPS──> Railway edge ──> opencode serve 0.0.0.0:$PORT
                                          │
                                   volume /data (wajib ter-mount)
                                   ├── workspace/   (repo & hasil kerja)
                                   └── home/        (config, credential, password,
                                                     .local/share/opencode/opencode.db
                                                     → session & message)
```

**Otomatis:** password kuat (sekali generate, disimpan persisten), public
networking HTTP/TCP (domain Railway dan/atau TCP proxy), dan volume `/data`
yang benar-benar ter-mount agar session bertahan saat redeploy.

## Isi repo

| File | Fungsi |
| --- | --- |
| `Dockerfile` | Image Node 24 + `@opencode/cli@latest` + tini + git/curl/ssh/rg |
| `start.sh` | Entrypoint: verifikasi `/data` ter-mount, siapkan DB & password, jalankan `opencode serve` |
| `railway.json` | Konfigurasi build & healthcheck Railway |
| `deploy.sh` | Deploy otomatis: project, service, variable, volume, domain HTTP/TCP |
| `push-github.sh` | Commit + buat repo GitHub + push (gh atau `GITHUB_TOKEN`) |
| `.env.example` | Contoh konfigurasi lokal |

## Prasyarat

- Akun Railway + akses CLI (`npm i -g @railway/cli`)
- Node 24 / Docker (untuk build lokal, opsional)
- GitHub CLI (`gh`) **atau** Personal Access Token dengan scope `repo`

## Deploy ke Railway

```bash
cp .env.example .env
# OPENCODE_SERVER_PASSWORD boleh dikosongkan -> digenerate otomatis
# isi API key provider bila perlu
./deploy.sh
```

Tanpa `.env` (password digenerate otomatis):

```bash
./deploy.sh
```

Atau tentukan password sendiri:

```bash
OPENCODE_SERVER_PASSWORD="$(openssl rand -hex 24)" ./deploy.sh
```

> GitHub auto-deploy **tidak** menjalankan `deploy.sh`. Auto-deploy hanya
> build image; volume `/data`, password, dan domain harus dibuat sekali dengan
> `./deploy.sh` (atau lewat template Railway). Setelah volume terpasang,
> redeploy dari GitHub akan tetap memakai data yang sama.

> Saat `deploy.sh` dijalankan dari terminal container Railway, script
> mengabaikan metadata `RAILWAY_*` runtime (project/environment/service milik
> container itu) dan memakai project yang di-link. Kalau belum ada project
> yang di-link, jalankan `railway link` dulu. Dengan begitu deploy tidak
> nyasar ke service tempat script berjalan.

Login non-interaktif (CI):

```bash
RAILWAY_TOKEN=... ./deploy.sh
```

`deploy.sh` akan:

1. install Railway CLI bila belum ada,
2. `railway init` bila project belum ter-link,
3. membuat/link service,
4. memastikan volume `/data` ter-scope ke service ini: memakai ulang volume
   detached, memperbaiki mount path yang salah (termasuk `/data ` dengan spasi
   di akhir), atau membuat volume baru bila belum ada,
5. memverifikasi volume benar-benar ter-attach dan mount path-nya persis
   `/data`,
6. menyetel variable (`PORT`, password, API key) — setelah volume siap agar
   redeploy yang dipicu variable tidak mendahului migrasi data,
7. membuat public networking: domain HTTP dan/atau TCP proxy,
8. `railway up`, lalu mencoba ulang networking bila deployment baru siap,
9. menyimpan password + URL ke `.deploy-credentials`.

Kalau service sudah berjalan tanpa volume yang benar, `deploy.sh` berhenti
lebih dulu agar session/workspace lama tidak hilang. Jalankan dengan
`MIGRATE_EXISTING_DATA=true` untuk migrasi otomatis, atau `ALLOW_DATA_LOSS=true`
bila data lama memang tidak diperlukan.

## Password otomatis

- Kalau `OPENCODE_SERVER_PASSWORD` kosong, `deploy.sh` membuat password acak
  32 karakter, menyetelnya sebagai variable Railway, dan menulisnya ke
  `.deploy-credentials`. Password tidak berubah saat restart/redeploy.
- Kalau `.deploy-credentials` belum ada tetapi service sudah punya variable
  `OPENCODE_SERVER_PASSWORD`, `deploy.sh` memakai password yang ada dan tidak
  merotasinya.
- Kalau container dijalankan tanpa variable tersebut (mis. deploy langsung
  dari dashboard Railway), `start.sh` membuat password acak dan menyimpannya
  di volume:
  `/data/home/.opencode-server-password` (mode `0600`).
- Password yang sudah tersimpan dipakai lagi pada restart berikutnya. Hapus
  file tersebut jika ingin membuat password baru.
- Password juga ditulis ke log container saat startup. Lihat dengan:

```bash
railway logs | grep 'Login password'
```

> Jangan membagikan log container karena berisi password.

## Session & data persisten

OpenCode V2 menyimpan session, message, project, config, dan credential di
`$HOME` (`/data/home`). Supaya semuanya bertahan saat redeploy, `/data` **harus**
benar-benar volume Railway, bukan direktori biasa di filesystem container.

`deploy.sh` melakukan ini sebelum deploy:

1. Membaca service ID dan men-scope pengecekan volume ke service ini.
   `railway volume list` berlaku untuk seluruh environment, jadi volume milik
   service lain tidak boleh dianggap sebagai volume service ini.
2. Memakai ulang volume detached yang mount path-nya `/data` (mis. sisa
   deployment lama).
3. Memperbaiki mount path yang salah, termasuk kasus yang pernah terjadi di
   Railway: mount path tersimpan sebagai `/data ` (ada spasi di akhir).
   Volume seperti ini tidak ter-mount ke `/data`, sehingga data tetap ephemeral.
4. Membuat volume baru bila service belum punya volume.
5. Memverifikasi volume benar-benar ter-attach ke service dan mount path-nya
   persis `/data`.

`start.sh` memverifikasi `/proc/mounts` saat container start:

- Kalau `/data` ter-mount: log `Persistent data: /data ter-mount.`
- Di Railway, kalau `/data` bukan mount point, container **berhenti** dengan
  error. Ini disengaja agar session tidak hilang diam-diam. Untuk uji
  sementara, set `ALLOW_EPHEMERAL_DATA=true` (data akan hilang saat redeploy).
- Lokasi DB dibuat eksplisit lewat `OPENCODE_DB`, default
  `/data/home/.local/share/opencode/opencode.db`, dan dicatat di log
  (`Session DB: ...`).

> Kalau service terhubung ke **auto-deploy GitHub**, tunda push/merge sampai
> volume `/data` sudah dibuat dan migrasi selesai. Kalau tidak, deploy otomatis
> akan menjalankan `start.sh` baru tanpa volume dan service sengaja berhenti.

### Volume pertama kali & data lama

Kalau service sudah pernah berjalan **tanpa volume** (atau volume ter-mount di
path yang salah), isi `/data` lama berada di filesystem ephemeral. Saat volume
dipasang/diperbaiki, isi tersebut akan tertutup. `deploy.sh` mendeteksi kondisi
ini dan **berhenti** sebelum mengubah volume, kecuali Anda memilih salah satu:

**Opsi 1 — migrasi otomatis (disarankan):**

```bash
MIGRATE_EXISTING_DATA=true ./deploy.sh
```

> `.env` dimuat setelah environment shell. Kalau `.env` Anda memuat
> `MIGRATE_EXISTING_DATA=false` (atau `ALLOW_DATA_LOSS=false`), hapus/ubah baris
> itu dulu karena nilainya akan menimpa flag di command line.

`deploy.sh` akan:

1. download `/data/home` dari deployment yang sedang berjalan ke
   `./.deploy-backup/recovery-<timestamp>/home`,
2. (opsional) download `/data/workspace` bila `MIGRATE_WORKSPACE=true`,
3. membuat/melampirkan/memperbaiki volume `/data`,
4. upload backup ke volume:
   - volume baru/kosong → `home` menjadi `/data/home` dan `workspace` menjadi
     `/data/workspace`;
   - volume yang sudah berisi data → backup disimpan di
     `/recovery-<timestamp>/home` agar session lama di volume tidak tertimpa,
5. baru melakukan redeploy.

Kalau salah satu langkah gagal, redeploy dibatalkan dan data lama tetap aman
(baik di service maupun di `.deploy-backup/`).

> Untuk volume yang sudah berisi data, server akan memakai database lama di
> volume. Session dari `/data` ephemeral tidak otomatis dimuat; salinannya ada
> di `/recovery-<timestamp>/home` di volume dan di `.deploy-backup/` lokal untuk
> digabung manual.

**Opsi 2 — backup manual:**

Untuk volume **baru/kosong**:

```bash
railway service files --service opencode-railway download /data/home ./.deploy-backup/home --overwrite
railway service files --service opencode-railway download /data/workspace ./.deploy-backup/workspace --overwrite

# setelah volume terpasang
railway volume files --volume <volume-id> upload ./.deploy-backup/home / --overwrite
railway volume files --volume <volume-id> upload ./.deploy-backup/workspace / --overwrite
```

`/` di sini adalah root volume, jadi `home` masuk ke `/data/home` dan
`workspace` masuk ke `/data/workspace`.

Kalau volume **sudah berisi data**, bungkus backup dalam folder recovery agar
database lama tidak tertimpa:

```bash
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p ".deploy-backup/recovery-$stamp"
railway service files --service opencode-railway download /data/home ".deploy-backup/recovery-$stamp/home" --overwrite
railway service files --service opencode-railway download /data/workspace ".deploy-backup/recovery-$stamp/workspace" --overwrite

railway volume files --volume <volume-id> upload ".deploy-backup/recovery-$stamp" / --overwrite
```

Hasilnya ada di `/recovery-<timestamp>/home` di volume. Command `service files`
dan `volume files` memerlukan Railway CLI terbaru.

**Opsi 3 — data lama tidak diperlukan:**

```bash
ALLOW_DATA_LOSS=true ./deploy.sh
```

> Backup DB yang sedang dipakai server bersifat best-effort. Hentikan aktivitas
> agent dulu agar konsisten. `.deploy-backup/` di-ignore git.

## Public networking otomatis

`deploy.sh` menyalakan public networking untuk service ini secara otomatis.
Pilih mode lewat `.env`:

```bash
PUBLIC_NETWORKING=http   # domain HTTPS Railway (*.up.railway.app) — default
PUBLIC_NETWORKING=tcp    # TCP proxy mentah (tanpa TLS)
PUBLIC_NETWORKING=both   # HTTP domain + TCP proxy
PUBLIC_NETWORKING=none   # tidak membuat public networking baru
```

Port TCP mengikuti `APP_PORT`, atau set `TCP_PROXY_PORT` bila berbeda:

```bash
PUBLIC_NETWORKING=both
TCP_PROXY_PORT=8080
```

Cek hasilnya:

```bash
railway domain list --service opencode-railway
railway tcp-proxy list --service opencode-railway
```

Kalau ingin membuat manual:

```bash
railway domain --port 8080 --service opencode-railway
railway tcp-proxy create --port 8080 --service opencode-railway
```

> TCP proxy meneruskan koneksi mentah **tanpa TLS**. Untuk browser dan
> kredensial Basic Auth, gunakan domain HTTP (HTTPS). Gunakan TCP hanya untuk
> klien/API yang memang membutuhkan koneksi TCP langsung.

## Push ke GitHub

```bash
./push-github.sh
```

Default: repo **public** bernama `opencode-railway`.

```bash
REPO_NAME=opencode-railway VISIBILITY=private ./push-github.sh
GITHUB_TOKEN=ghp_xxx ./push-github.sh        # non-interaktif
```

> SSH (`github.com:22`) sering diblokir di lingkungan container, jadi script
> selalu memakai HTTPS. `.env` dan `.deploy-credentials` di-ignore git.

## Connect ke server

Ganti `<URL>` dengan domain Railway (atau `http://<host>:<port>` dari TCP
proxy) dan `<PASSWORD>` dengan `OPENCODE_SERVER_PASSWORD`.

**Browser**

Buka `<URL>`, masukkan password. Jika browser meminta HTTP Basic Auth:
username `opencode`, password sama.

**CLI**

```bash
opencode --server <URL>
```

**API**

```bash
curl -u "opencode:<PASSWORD>" <URL>/api/info
```

**TCP proxy** (bila `PUBLIC_NETWORKING=tcp` atau `both`)

```bash
# contoh: shuttle.proxy.rlwy.net:15140
curl -u "opencode:<PASSWORD>" http://<tcp-host>:<tcp-port>/api/info
```

TCP proxy tidak memakai TLS, jadi password terkirim tanpa enkripsi. Untuk
pemakaian normal, gunakan domain HTTP.

`/api/info` mengembalikan versi, pid, dan URL server. Endpoint lain mengikuti
[referensi API V2](https://opencode.ai/v2/docs/api/).

## Environment variables

| Variable | Wajib | Default | Keterangan |
| --- | --- | --- | --- |
| `OPENCODE_SERVER_PASSWORD` | tidak | digenerate | Password web UI/API (dibuat & disimpan otomatis) |
| `OPENCODE_PASSWORD_FILE` | tidak | `$HOME/.opencode-server-password` | Lokasi password auto-generate di volume |
| `PUBLIC_NETWORKING` | tidak | `http` | `http`, `tcp`, `both`, atau `none` |
| `TCP_PROXY_PORT` | tidak | `APP_PORT` | Port aplikasi untuk TCP proxy |
| `PORT` | tidak | `8080` | Di-inject Railway |
| `OPENCODE_DISABLE_AUTOUPDATE` | tidak | `true` | Matikan updater internal OpenCode |
| `OPENCODE_AUTO_UPDATE` | tidak | `true` | Supervisor cek & pasang versi npm terbaru |
| `OPENCODE_AUTO_UPDATE_INTERVAL` | tidak | `21600` | Interval cek update (detik, min. 300) |
| `OPENCODE_LOW_RESOURCE` | tidak | `true` | Profil hemat RAM/CPU |
| `OPENCODE_HOME` | tidak | `/data/home` | Lokasi state/config (harus di volume) |
| `OPENCODE_DB` | tidak | `/data/home/.local/share/opencode/opencode.db` | Lokasi database session/message |
| `ALLOW_EPHEMERAL_DATA` | tidak | `false` | Izinkan start di Railway tanpa volume `/data` (data tidak persisten; hanya untuk uji) |
| `MIGRATE_EXISTING_DATA` | tidak | `false` | Khusus `deploy.sh`: backup `/data/home` dari deployment lama lalu upload ke volume (volume baru) atau folder recovery (volume yang sudah berisi data) |
| `MIGRATE_WORKSPACE` | tidak | `false` | Khusus `deploy.sh`: ikut migrasikan `/data/workspace` |
| `ALLOW_DATA_LOSS` | tidak | `false` | Khusus `deploy.sh`: lanjutkan tanpa migrasi walau data ephemeral lama akan hilang |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `OPENROUTER_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`, `GROQ_API_KEY`, `OPENCODE_API_KEY` | tidak | – | Kredensial provider model |
| `OPENAI_BASE_URL`, `DEEPSEEK_BASE_URL`, `OPENROUTER_BASE_URL` | tidak | – | Endpoint OpenAI-compatible |

`OPENCODE_SERVER_PASSWORD` tidak wajib diisi. Kalau kosong, `deploy.sh`
membuat password acak dan menyetelnya sebagai variable Railway. Kalau
container berjalan tanpa variable itu (mis. deploy dari dashboard), `start.sh`
membuat password dan menyimpannya di volume, sehingga tetap sama setelah
restart/redeploy.

## Auto-update

Container menjalankan supervisor di `start.sh`:

1. Setiap `OPENCODE_AUTO_UPDATE_INTERVAL` detik, cek versi stabil terbaru
   `@opencode/cli` di npm.
2. Kalau versi npm lebih baru, jalankan `npm install -g` versi tersebut.
3. Hentikan `opencode serve`, lalu jalankan ulang dengan binary baru.

Supervisor juga me-restart server yang crash, dan keluar setelah 5 crash
berturut-turut (< 10 detik) agar Railway me-restart container.

```bash
# matikan auto-update
OPENCODE_AUTO_UPDATE=false

# cek tiap 1 jam
OPENCODE_AUTO_UPDATE_INTERVAL=3600
```

> Update yang dipasang saat runtime hanya bertahan sampai container
> di-redeploy. Setelah redeploy, image tetap dibangun dengan
> `@opencode/cli@latest` dari Dockerfile, jadi tetap versi terbaru.

## Hemat RAM & CPU

Default container memakai **profil hemat** (`OPENCODE_LOW_RESOURCE=true`).

**Level OpenCode** — `start.sh` menulis `low-resource.json` ke
`$HOME/.config/opencode/opencode.json` dan menyalakan env berikut:

| Item | Efek | Trade-off |
| --- | --- | --- |
| `lsp: false` | Tidak menjalankan language server | Tanpa diagnostic/hover |
| `formatter: false` | Tidak format otomatis setelah edit | Format manual |
| `snapshots: false` | Tidak capture snapshot git tiap step | `/undo` tidak memulihkan file |
| `warming: false` | Tidak ada request keep-alive berkala | – |
| `plugins: []` | Tidak memuat plugin | Tidak ada plugin |
| `update: "disable"` | Tidak cek update dari UI | Update lewat supervisor |
| `OPENCODE_DISABLE_FILEWATCHER` | Matikan watcher filesystem | File tree tidak auto-refresh |
| `OPENCODE_DISABLE_MODELS_FETCH` | Tidak fetch daftar model berkala | – |
| `OPENCODE_DISABLE_CLAUDE_CODE(_SKILLS)` | Tidak memindai `.claude/` | Tanpa skill Claude Code |

> Config hanya ditulis kalau belum ada. Kalau Anda sudah punya config kustom di
> volume, file itu **tidak** ditimpa.

**Level Railway:**
- `overlapSeconds: 0` + `drainingSeconds: 10` — saat deploy, container lama
  langsung dimatikan (tidak ada dua container jalan bersamaan).
- `restartPolicyType: ON_FAILURE`, `restartPolicyMaxRetries: 10`.
- **App Sleeping** (opsional, diset di dashboard/API): service tidur saat tidak
  ada traffic → paling menghemat, tapi request pertama jadi lambat (cold start).
  Aktifkan di dashboard Railway → service → Settings → *App Sleeping*.

Matikan profil hemat bila butuh fitur penuh:

```bash
OPENCODE_LOW_RESOURCE=false
```

## Build & jalankan lokal

```bash
docker build -t opencode-railway .
docker run --rm -p 8080:8080 \
  -e OPENCODE_SERVER_PASSWORD=rahasia \
  -v "$PWD/data:/data" \
  opencode-railway
```

Buka <http://localhost:8080>.

Kalau `-e OPENCODE_SERVER_PASSWORD` dihilangkan, container membuat password
otomatis dan menyimpannya di `data/home/.opencode-server-password`; lihat
log container untuk password tersebut.

## Troubleshooting

| Gejala | Penyebab / solusi |
| --- | --- |
| Build gagal saat `npm install -g @opencode/cli` | Cek koneksi registry/egress. Package V2 adalah `@opencode/cli`; `opencode-ai` adalah V1. |
| `401` di semua `/api/*` | Sertakan Basic Auth: `-u "opencode:<PASSWORD>"`. |
| Web UI minta login terus | Pastikan `OPENCODE_SERVER_PASSWORD` sama dengan yang di `.deploy-credentials`, atau lihat password auto-generate di `/data/home/.opencode-server-password`. |
| Lupa password auto-generate | `railway logs \| grep 'Login password'`, atau baca file di volume. Hapus file untuk generate ulang. |
| Domain HTTP tidak terbentuk | `railway domain --port 8080 --service opencode-railway`, lalu cek `railway domain list`. |
| TCP proxy gagal dibuat | Pastikan Railway CLI terbaru (`railway upgrade --yes`). Satu service hanya boleh punya satu TCP proxy: `railway tcp-proxy list --service opencode-railway`. |
| Session hilang setelah redeploy | Cek `railway volume list --json` dan `railway service list --json`. Pastikan volume ter-attach ke service **ini** dan `mountPath` persis `/data` (tanpa spasi). Perbaiki dengan `railway volume update --volume <nama> --mount-path /data`, lalu redeploy. Cek log: `railway logs \| grep -E 'Persistent data\|Session DB'`. Kalau ada peringatan `/data BUKAN mount point`, volume belum terpasang. |
| Deploy berhenti dengan `Dibatalkan agar data lama tidak hilang` | `deploy.sh` menemukan service berjalan tanpa volume `/data` yang benar. Jalankan `MIGRATE_EXISTING_DATA=true ./deploy.sh` (tambahkan `MIGRATE_WORKSPACE=true` bila workspace ikut), atau `ALLOW_DATA_LOSS=true ./deploy.sh` bila data lama tidak diperlukan. |
| Deploy mengubah service yang salah | `deploy.sh` versi lama mengikuti `RAILWAY_PROJECT_ID` runtime saat dijalankan dari dalam container. Versi terbaru mengabaikan metadata itu. Pastikan project benar dengan `railway link`, lalu jalankan ulang. |
| Deploy gagal dengan `Pasang volume Railway di /data` | Ini disengaja: `start.sh` menolak berjalan tanpa volume agar data tidak hilang diam-diam. Jalankan `./deploy.sh` (yang memasang volume) atau tambahkan volume manual di dashboard Railway → service → **Volumes** → mount path `/data`, lalu redeploy. |
| Volume ada tetapi data tetap hilang | Cek mount path di `railway volume list --json`. Mount path `/data ` (spasi di akhir) tidak sama dengan `/data`. Perbaiki: `railway volume update --volume <nama> --mount-path /data`, lalu redeploy. |
| Healthcheck gagal | `GET /` harus 200. Cek `railway logs` untuk error startup. |
| Model tidak muncul | Set API key provider sebagai variable Railway, lalu redeploy. |

## Lisensi

MIT.
