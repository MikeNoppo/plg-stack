# monitoring-stack

Boilerplate monitoring **Grafana + Prometheus + Loki** dengan agent **Grafana Alloy**.
Stack bisa dijalankan di **Dokploy** atau di **server biasa** dari repo yang sama, dan
dipindah antar server tanpa menyentuh agent di server-server yang dipantau.

```
 [server app]      [server DB]       [server Dokploy]   ...
    Alloy             Alloy               Alloy
      │ push (HTTPS + basic auth)          │
      └──────────────┬────────────────────┘
                     ▼
        ingest.example.com ──┐      grafana.example.com
                             ▼              ▼
   ┌──────────────── gateway (Caddy) ───────────────┐
   │  /api/v1/write    → Prometheus  (metrik)       │
   │  /loki/api/v1/push → Loki       (log)          │
   │  /agent/*         → installer agent (publik)   │
   │  grafana.*        → Grafana (dashboard, alert) │
   └────────────────────────────────────────────────┘
```

Prinsip yang membuat stack ini mudah dipindah:

- **Agent mengirim ke hostname, bukan IP.** Saat stack pindah, cukup ubah DNS
  `ingest.*` dan `grafana.*`. Agent mem-buffer data (WAL) selama DNS berpindah.
- **Semua konfigurasi ada di git.** Datasource, dashboard, dan alert di-provision
  dari file, jadi database Grafana tidak menyimpan apa pun yang penting.
- **Satu `compose.yaml` untuk dua mode.** TLS diurus Traefik di Dokploy, atau
  Caddy di server biasa (`compose.standalone.yaml` hanya menambah port 80/443).
- **Rahasia hanya di `.env`**, tidak pernah di-commit.

## Isi repo

| Path | Fungsi |
|---|---|
| `compose.yaml` | Stack: gateway (Caddy), Prometheus, Loki, Grafana |
| `compose.standalone.yaml` | Membuka port 80/443 untuk mode server biasa |
| `gateway/Caddyfile` | Routing domain, basic auth ingest, TLS otomatis |
| `prometheus/`, `loki/` | Konfigurasi server; `loki-s3.yaml` untuk log di S3 |
| `grafana/provisioning/` | Datasource, provider dashboard, alert rules |
| `grafana/dashboards/` | Dashboard JSON (folder *Monitoring*) |
| `grafana/alerting-examples/` | Contoh contact point Telegram / Slack / email |
| `agent/install.sh` | Installer agent satu perintah |
| `agent/alloy/*.alloy` | Modul konfigurasi Alloy (base, docker, postgres, mysql, redis, mongodb) |
| `scripts/setup.sh` | Membuat `.env` secara interaktif |
| `scripts/backup.sh`, `scripts/restore.sh` | Memindahkan data antar server |

## 1. Deploy stack

Siapkan dua subdomain, misalnya `grafana.example.com` dan `ingest.example.com`,
lalu buat `.env`:

```bash
./scripts/setup.sh
```

Script menanyakan mode (dokploy/standalone), domain, password (default acak),
retensi, dan penyimpanan log (disk lokal atau S3).

### A. Di Dokploy

1. Project **Monitoring** → *Create Service* → **Compose** (tipe *Docker Compose*).
2. Provider **GitHub** → repo ini, branch `main`, *Compose Path* `./compose.yaml`.
3. Tab **Environment**: tempel seluruh isi `.env` hasil `setup.sh` (mode dokploy).
4. Tab **Domains**: tambahkan `grafana.example.com` dan `ingest.example.com`.
   Keduanya diarahkan ke service **`gateway`**, port **80**, HTTPS aktif.
5. **Deploy**.

### B. Di server biasa (tanpa Dokploy)

```bash
git clone <repo> monitoring-stack && cd monitoring-stack
./scripts/setup.sh          # pilih mode standalone
docker compose up -d
```

Arahkan DNS kedua domain ke IP server, lalu buka port 80 dan 443. Caddy
mengambil sertifikat Let's Encrypt otomatis.

### Kebutuhan resource

Untuk sekitar 10 server: kurang lebih 2 GB RAM dan 1 vCPU. Disk bergantung pada
retensi. Prometheus dibatasi `PROMETHEUS_RETENTION_SIZE` (default 8 GB). Log Loki
paling boros, jadi untuk server dengan disk kecil sebaiknya pakai S3.

## 2. Install agent di server yang dipantau

Satu perintah, dijalankan di server target:

```bash
curl -fsSL https://ingest.example.com/agent/install.sh | sudo bash
```

Installer dilayani langsung oleh stack (tanpa auth karena tidak berisi rahasia),
jadi tetap bisa dipakai walau repo GitHub-nya private.

Yang dilakukan installer:

1. **Memeriksa server**: OS dan package manager, systemd, resource, pemakaian
   disk, Docker (termasuk apakah ini server Dokploy), database yang berjalan
   (PostgreSQL, MySQL/MariaDB, Redis, MongoDB), apakah native atau di dalam
   container, agent monitoring lain, dan instalasi sebelumnya.
2. **Merekomendasikan mode**:
   - **docker**: Alloy jalan sebagai container `monitoring-agent`. Dipakai untuk
     server Docker/Dokploy; semua container ikut terpantau.
   - **native**: paket `alloy` dari repo resmi Grafana + service systemd. Dipakai
     untuk server tanpa Docker, terutama server database.
3. **Menanyakan** URL ingest, kredensial (langsung dites ke `/ping`), nama server,
   dan environment.
4. **Memilih modul.** Untuk database native, installer bisa **membuat user
   `monitoring` otomatis** (PostgreSQL: role `pg_monitor`; MySQL: `PROCESS,
   REPLICATION CLIENT, SELECT`) dengan password acak.
5. **Memasang dan memverifikasi** bahwa agent siap dan semua komponen sehat.

Menjalankan ulang installer = update konfigurasi; nilai lama dipakai sebagai
default. Hapus agent dengan `--uninstall`.

### Non-interaktif (otomasi / banyak server)

```bash
curl -fsSL https://ingest.example.com/agent/install.sh | sudo bash -s -- \
  --url https://ingest.example.com --user agent --password 'RAHASIA' \
  --name db-01 --env production --mode native \
  --postgres-dsn 'postgresql://monitoring:pw@127.0.0.1:5432/postgres?sslmode=disable' \
  --yes
```

Opsi lengkap: `install.sh --help`.

### Yang dikumpulkan

| Modul | Metrik | Log |
|---|---|---|
| `base` (selalu) | CPU, RAM, disk, I/O, network, load, uptime | journald (`source="journal"`) |
| `docker` | CPU/RAM/network/IO per container (cAdvisor) | semua container (`source="docker"`) |
| `postgres` / `mysql` / `redis` / `mongodb` | exporter bawaan Alloy | file log di `/var/log/<db>/` |

Label yang selalu ada: `host` (nama server) dan `env`. Pada container, `service`
berisi nama service Swarm (aplikasi Dokploy), service compose, atau nama
container.

## 3. Dashboard dan alert

Dashboard di folder **Monitoring**:

- **Fleet Overview**: semua server dalam satu tabel (CPU, RAM, disk, uptime,
  versi agent) dan daftar server yang berhenti mengirim data.
- **Host Detail**: satu server lengkap dengan log journald.
- **Containers**: pemakaian per service/container dan log container.
- **Logs**: pencarian log lintas server.
- **Databases**: PostgreSQL, MySQL/MariaDB, Redis, MongoDB.

Alert rules (folder **Alerts**): server tidak mengirim data, disk >85% / >95%,
disk diprediksi penuh dalam 24 jam, RAM >90%, CPU >90%, container sering
restart, dan database tidak bisa diakses.

### Mengaktifkan notifikasi

Tujuan notifikasi belum ditentukan, jadi contoh disediakan terpisah:

1. Salin **satu** file dari `grafana/alerting-examples/` ke
   `grafana/provisioning/alerting/`. Setiap file mengganti seluruh notification
   policy, jadi jangan salin lebih dari satu.
2. Isi variabelnya di `.env`: `ALERT_TELEGRAM_*`, `ALERT_SLACK_WEBHOOK_URL`,
   atau `ALERT_EMAIL_ADDRESSES` + `GF_SMTP_*`.
3. Commit, lalu redeploy.

### Mengubah dashboard

Dashboard di-provision read-only. Edit di Grafana → *Save as* copy, atau
*Export → JSON*, simpan ke `grafana/dashboards/Monitoring/`, lalu commit.

## 4. Memindahkan stack ke server lain

1. Di server lama: `scripts/backup.sh` (menghentikan stack sebentar, lalu
   mengarsipkan volume ke `backups/<waktu>/`). Di Dokploy, project compose
   dideteksi otomatis.
2. Salin folder backup dan `.env` ke server baru, lalu clone repo ini.
3. Di server baru:
   - **Standalone**: ubah `.env` ke mode standalone (`./scripts/setup.sh`), lalu
     jalankan `scripts/restore.sh backups/<waktu>`. Stack langsung dinyalakan.
   - **Dokploy**: deploy sekali, *Stop*, lalu jalankan
     `scripts/restore.sh --project <app-name> --no-start backups/<waktu>` dan
     Deploy lagi.
4. Ubah DNS `grafana.*` dan `ingest.*` ke server baru.
5. Matikan stack di server lama.

Agent tidak perlu diubah. Kalau histori metrik tidak perlu ikut, langkah 1–3
cukup diganti deploy baru. Jika Loki memakai S3, log memang tidak ada di disk
lokal sehingga tidak perlu dipindah.

## Keamanan

- Yang terbuka ke luar hanya gateway (80/443). Prometheus dan Loki tidak
  di-expose; query lewat Grafana.
- Endpoint ingest memakai basic auth (`INGEST_USER` / `INGEST_PASSWORD`) di atas
  HTTPS. Ganti password = ubah `.env`, redeploy, lalu jalankan ulang installer di
  setiap server.
- Agent mode docker berjalan `--privileged` dengan akses read-only ke root
  filesystem dan socket Docker (dibutuhkan cAdvisor dan metrik host). UI Alloy
  hanya listen di `127.0.0.1:12345`.
- File kredensial agent: `/opt/monitoring-agent/agent.env` (docker) atau
  `/etc/alloy/monitoring.env` (native), keduanya mode `600`.

## Troubleshooting

| Gejala | Cek |
|---|---|
| Server tidak muncul di dashboard | `docker logs monitoring-agent` / `journalctl -u alloy`; `curl -u agent:PASS https://ingest.../ping` |
| Komponen agent tidak sehat | UI Alloy: `ssh -L 12345:127.0.0.1:12345 server`, lalu buka http://localhost:12345 |
| Database `DOWN` | Kredensial DSN salah, atau user belum punya grant yang dibutuhkan |
| Log file DB tidak masuk | Permission: agent native berjalan sebagai user `alloy` dengan grup `adm` dan `systemd-journal` |
