# OpenCode V2 di Railway

Menjalankan **OpenCode V2 terbaru** di [Railway](https://railway.com) sebagai
server selalu-aktif, lengkap dengan web UI, API, dan workspace persisten.

```
Internet ──HTTPS──> Railway edge ──> opencode serve 0.0.0.0:$PORT
                                          │
                                   volume /data
                                   ├── workspace/   (repo & hasil kerja)
                                   └── home/        (config, session, credential)
```

## Isi repo

| File | Fungsi |
| --- | --- |
| `Dockerfile` | Image Node 24 + `@opencode/cli@latest` + tini + git/curl/ssh/rg |
| `start.sh` | Entrypoint: siapkan `/data`, cek password, jalankan `opencode serve` |
| `railway.json` | Konfigurasi build & healthcheck Railway |
| `deploy.sh` | Deploy otomatis: project, service, variable, volume, domain |
| `push-github.sh` | Commit + buat repo GitHub + push (gh atau `GITHUB_TOKEN`) |
| `.env.example` | Contoh konfigurasi lokal |

## Prasyarat

- Akun Railway + akses CLI (`npm i -g @railway/cli`)
- Node 24 / Docker (untuk build lokal, opsional)
- GitHub CLI (`gh`) **atau** Personal Access Token dengan scope `repo`

## Deploy ke Railway

```bash
cp .env.example .env
# isi OPENCODE_SERVER_PASSWORD (wajib) dan API key provider (opsional)
./deploy.sh
```

Atau tanpa `.env`:

```bash
OPENCODE_SERVER_PASSWORD="$(openssl rand -hex 24)" ./deploy.sh
```

Login non-interaktif (CI):

```bash
RAILWAY_TOKEN=... OPENCODE_SERVER_PASSWORD=... ./deploy.sh
```

`deploy.sh` akan:

1. install Railway CLI bila belum ada,
2. `railway init` bila project belum ter-link,
3. membuat service, menyetel variable (`PORT`, password, API key provider),
4. memasang volume di `/data`,
5. membuat domain publik,
6. `railway up` dan menyimpan password ke `.deploy-credentials`.

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

Ganti `<URL>` dengan domain Railway dan `<PASSWORD>` dengan
`OPENCODE_SERVER_PASSWORD`.

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

`/api/info` mengembalikan versi, pid, dan URL server. Endpoint lain mengikuti
[referensi API V2](https://opencode.ai/v2/docs/api/).

## Environment variables

| Variable | Wajib | Default | Keterangan |
| --- | --- | --- | --- |
| `OPENCODE_SERVER_PASSWORD` | ya | digenerate | Password web UI/API |
| `PORT` | tidak | `8080` | Di-inject Railway |
| `OPENCODE_DISABLE_AUTOUPDATE` | tidak | `true` | Matikan updater internal OpenCode |
| `OPENCODE_AUTO_UPDATE` | tidak | `true` | Supervisor cek & pasang versi npm terbaru |
| `OPENCODE_AUTO_UPDATE_INTERVAL` | tidak | `21600` | Interval cek update (detik, min. 300) |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `OPENROUTER_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`, `GROQ_API_KEY`, `OPENCODE_API_KEY` | tidak | – | Kredensial provider model |
| `OPENAI_BASE_URL`, `DEEPSEEK_BASE_URL`, `OPENROUTER_BASE_URL` | tidak | – | Endpoint OpenAI-compatible |

`OPENCODE_SERVER_PASSWORD` **wajib** di-set di Railway. Kalau kosong, container
membuat password acak dan menuliskannya di log — artinya password berubah tiap
restart.

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

## Build & jalankan lokal

```bash
docker build -t opencode-railway .
docker run --rm -p 8080:8080 \
  -e OPENCODE_SERVER_PASSWORD=rahasia \
  -v "$PWD/data:/data" \
  opencode-railway
```

Buka <http://localhost:8080>.

## Troubleshooting

| Gejala | Penyebab / solusi |
| --- | --- |
| Build gagal saat `npm install -g @opencode/cli` | Cek koneksi registry/egress. Package V2 adalah `@opencode/cli`; `opencode-ai` adalah V1. |
| `401` di semua `/api/*` | Sertakan Basic Auth: `-u "opencode:<PASSWORD>"`. |
| Web UI minta login terus | Pastikan `OPENCODE_SERVER_PASSWORD` sama dengan yang di `.deploy-credentials`. |
| Session hilang setelah redeploy | Pastikan volume ter-mount di `/data`. |
| Healthcheck gagal | `GET /` harus 200. Cek `railway logs` untuk error startup. |
| Model tidak muncul | Set API key provider sebagai variable Railway, lalu redeploy. |

## Lisensi

MIT.
