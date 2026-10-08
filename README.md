# PLG Stack

**P**rometheus + **L**oki + **G**rafana: boilerplate monitoring dengan agent **Grafana Alloy**.
Stack bisa dijalankan di **Dokploy** atau di **server biasa** dari repo yang sama, dan
dipindah antar server tanpa menyentuh agent di server-server yang dipantau.

```
 [server app]      [server DB]       [server stack]   ...
    Alloy             Alloy           Alloy (bawaan)
      │ push (HTTPS + token per server)    │
      └──────────────┬────────────────────┘
                     ▼
        ingest.example.com ──┐      grafana.example.com
                             ▼              ▼
   ┌──────────────── gateway (Caddy) ───────────────┐
   │  /api/v1/write    → Prometheus  (metrik)       │
   │  /loki/api/v1/push → Loki       (log)          │
   │  /agent/*         → installer + modul (publik) │
   │  grafana.*        → Grafana (dashboard, alert) │
   └────────────────────────────────────────────────┘
        watchdog ──heartbeat──▶ layanan eksternal (opsional)
```

Prinsip yang membuat stack ini mudah dipindah dan diatur:

- **Agent mengirim ke hostname, bukan IP.** Saat stack pindah, cukup ubah DNS
  `ingest.*` dan `grafana.*`. Agent menahan data selama terputus (lihat
  [Mode offline](#mode-offline)).
- **Semua konfigurasi ada di git.** Datasource, dashboard, dan alert di-provision
  dari file, jadi database Grafana tidak menyimpan apa pun yang penting.
- **Satu `compose.yaml` untuk dua mode.** TLS diurus Traefik di Dokploy, atau
  Caddy di server biasa (`compose.standalone.yaml` hanya menambah port 80/443).
- **Kustomisasi di tiga lapis:** `.env` (per deployment stack), opsi installer
  (per server), dan label Docker (per container).

## Isi repo

| Path | Fungsi |
|---|---|
| `compose.yaml` | Stack: gateway (Caddy), Prometheus, Loki, Grafana, watchdog, agent self-monitoring, backup |
| `compose.standalone.yaml` | Membuka port 80/443 untuk mode server biasa |
| `gateway/` | Routing domain, token agent (`entrypoint.sh`), TLS otomatis |
| `prometheus/`, `loki/` | Konfigurasi server; nilai dinamis diambil dari `.env` |
| `grafana/generator/` | Generator dashboard dan alert rules: `config.toml` (threshold, durasi, bahasa) dan `lang/` (teks) |
| `grafana/provisioning/`, `grafana/dashboards/` | Datasource, alert rules, dashboard (dashboard dan alert hasil generator) |
| `grafana/alerting-examples/` | Contoh contact point Telegram / Slack / email |
| `watchdog/` | Heartbeat ke layanan eksternal |
| `backup/` | Script yang berjalan di container `backup`: jadwal, backup restic, restore |
| `agent/install.sh` | Installer agent satu perintah |
| `agent/modules/` | Modul Alloy + `catalog.conf` (daftar modul untuk installer) |
| `scripts/` | `setup.sh` (buat `.env`), `agent-token.sh` (token per server), `doctor.sh` (diagnosa), `restore.sh` (pulihkan backup) |
| `tests/` | Unit test script (`tests/run.sh`) |

## 1. Deploy stack

Siapkan dua subdomain, misalnya `grafana.example.com` dan `ingest.example.com`,
lalu buat `.env`:

```bash
./scripts/setup.sh
```

Script menanyakan, masing-masing dengan penjelasan: mode (dokploy/standalone),
domain, login Grafana, self-monitoring, URL watchdog, profil resource
(small/medium/large/custom), retensi metrik dan log (termasuk retensi singkat
untuk journald dan environment development), jendela data offline, penyimpanan
log (disk lokal atau S3), rotasi log container, dan backup terjadwal (S3 atau
disk lokal). Menjalankan ulang `setup.sh` memakai nilai lama sebagai default dan
tidak menghapus pengaturan lain di `.env`.

Setelah deploy, cek semuanya dengan `scripts/doctor.sh` (lihat
[Troubleshooting](#troubleshooting)).

### A. Di Dokploy

1. *Create Service* → **Compose** (tipe *Docker Compose*), sumber repo ini,
   *Compose Path* `./compose.yaml`.
2. Tab **Environment**: tempel seluruh isi `.env` hasil `setup.sh` (mode dokploy).
3. Tab **Domains**: tambahkan `grafana.example.com` dan `ingest.example.com`.
   Keduanya diarahkan ke service **`gateway`**, port **80**, HTTPS aktif.
4. **Deploy**.

Agent self-monitoring memakai `network_mode: host`, jadi jangan aktifkan
*Isolated Deployment* untuk service ini.

### B. Di server biasa (tanpa Dokploy)

```bash
git clone https://github.com/MikeNoppo/plg-stack.git && cd plg-stack
./scripts/setup.sh          # pilih mode standalone
docker compose up -d
```

Arahkan DNS kedua domain ke IP server, lalu buka port 80 dan 443. Caddy
mengambil sertifikat Let's Encrypt otomatis.

### Kustomisasi lewat `.env`

Semua nilai di bawah punya default dan bisa diubah tanpa menyentuh file lain
(daftar lengkap di `.env.example`):

| Area | Variabel |
|---|---|
| Resource | `*_MEMORY_LIMIT`, `*_CPUS` per service (`0` = tanpa batas) |
| Rotasi log container stack | `LOG_MAX_SIZE`, `LOG_MAX_FILE` |
| Metrik | `PROMETHEUS_RETENTION`, `PROMETHEUS_RETENTION_SIZE`, `PROMETHEUS_OOO_WINDOW` |
| Retensi log per jenis | `LOKI_RETENTION`, `LOKI_RETENTION_JOURNAL`, `LOKI_SHORT_RETENTION_ENVS`, `LOKI_SHORT_RETENTION` |
| Limit Loki | `LOKI_INGESTION_RATE_MB`, `LOKI_PER_STREAM_RATE_MB`, `LOKI_MAX_LINE_SIZE`, `LOKI_MAX_QUERY_SERIES`, `LOKI_QUERY_TIMEOUT`, ... |
| Grafana | `GRAFANA_PLUGINS`, `GRAFANA_DB_*` (PostgreSQL/MySQL sebagai pengganti SQLite) |
| Self-monitoring | `COMPOSE_PROFILES=self-monitoring`, `SELF_MONITORING_*` |
| Watchdog | `WATCHDOG_URL`, `WATCHDOG_FAIL_URL`, `WATCHDOG_INTERVAL` |
| Backup | `COMPOSE_PROFILES=backup`, `BACKUP_*`, `TZ` (lihat [Backup dan restore](#4-backup-dan-restore)) |

Loki hanya membatasi umur log, bukan ukurannya. Pertumbuhan disk dikendalikan
lewat retensi per jenis dan limit ingest; pantau ukurannya di dashboard
**PLG Stack Health**.

## 2. Pasang agent di server yang dipantau

Setiap server punya token sendiri, jadi satu server bisa dicabut aksesnya tanpa
mengganggu yang lain. Di server stack (atau di laptop untuk mode Dokploy):

```bash
scripts/agent-token.sh add db-01
```

Perintah itu membuat token dan menampilkan satu baris perintah install untuk
server `db-01`:

```bash
curl -fsSL https://ingest.example.com/agent/install.sh | sudo bash -s -- \
  --url https://ingest.example.com --name db-01 --token TOKEN
```

Di mode standalone gateway langsung dimuat ulang. Di mode Dokploy, script
menampilkan nilai `AGENT_TOKENS` baru untuk ditempel di tab Environment, lalu
Deploy. Token lain: `agent-token.sh rotate NAMA`, `revoke NAMA`, `list`.

### Yang dilakukan installer

1. **Memeriksa server**: OS dan package manager, systemd, resource, disk,
   Docker, journald (disimpan di disk atau hanya di RAM), agent monitoring lain,
   dan instalasi sebelumnya.
2. **Koneksi**: URL, nama server (sama dengan nama token), token (langsung dites),
   environment.
3. **Mode**, dengan rekomendasi:
   - **docker**: Alloy jalan sebagai container `plg-agent`.
   - **native**: paket `alloy` dari repo resmi Grafana + service systemd. Cocok
     untuk server tanpa Docker, terutama server database.
4. **Modul**: setiap modul di `agent/modules/catalog.conf` dideteksi otomatis;
   yang terdeteksi sudah tercentang. Untuk PostgreSQL/MySQL native, installer
   bisa membuat user `monitoring` dengan password acak.
5. **Akses privileged** hanya diminta bila modul yang dipilih membutuhkannya
   (`docker-metrics`, `process`), dengan penjelasan alasannya. Jika ditolak,
   modul itu dilewati.
6. **Pengaturan agent**, masing-masing dengan penjelasan: batas memori (agent
   di-restart otomatis bila melewatinya), lama data offline disimpan,
   penyimpanan journald di disk, dan sensor rahasia di log.
7. **Memasang dan memverifikasi**: agent siap, semua komponen sehat, dan data
   pertama sudah terkirim.

Menjalankan ulang installer = mengubah pilihan; nilai lama dipakai sebagai
default. Hapus agent dengan `--uninstall`.

### Non-interaktif (otomasi / banyak server)

```bash
curl -fsSL https://ingest.example.com/agent/install.sh | sudo bash -s -- \
  --url https://ingest.example.com --name db-01 --token TOKEN --env production \
  --mode native --modules base,postgres,files,process \
  --set POSTGRES_DSN='postgresql://monitoring:pw@127.0.0.1:5432/postgres?sslmode=disable' \
  --memory 512M --offline-buffer 24h --privileged yes --yes
```

Opsi lengkap: `install.sh --help`.

### Modul

| Modul | Deteksi | Isi |
|---|---|---|
| `base` | selalu | CPU, RAM, disk, I/O, network, load, uptime, log journald, metrik custom |
| `docker-logs` | Docker | Log semua container |
| `docker-metrics` | Docker | CPU/RAM/network/IO per container (cAdvisor), butuh privileged |
| `docker-apps` | container berlabel `plg.scrape=true` | `/metrics` aplikasi di container |
| `files` | nginx, Apache, PHP-FPM, Laravel, Tomcat, PM2, Supervisor | File log aplikasi native |
| `app-metrics` | ada file di `metrics.d/` | `/metrics` aplikasi native |
| `process` | java, node, python, php-fpm, nginx, ... | CPU/RAM/IO per proses, butuh privileged |
| `postgres`, `mysql`, `redis`, `mongodb` | proses database | Metrik dan file log database |

Label yang selalu ada: `host` (nama server) dan `env`. Log aplikasi mendapat
label `level` (debug/info/warning/error/crit) yang dideteksi dari log JSON,
logfmt, pino, atau kata level di awal baris.

**Menambah modul baru** cukup dua langkah, tanpa mengubah `install.sh`: buat
`agent/modules/NAMA.alloy`, lalu tambahkan blok `[NAMA]` di `catalog.conf`
(judul, deskripsi, cara deteksi, variabel yang perlu ditanyakan). Format
lengkapnya ada di bagian atas `catalog.conf`.

### Pengaturan per server tanpa install ulang

Agent memantau folder ini dan memuat perubahan dalam ±1 menit:

| Path | Isi |
|---|---|
| `/etc/plg-agent/logs.d/*.yaml` | File log tambahan (`auto.yaml` dibuat installer, sisanya bebas) |
| `/etc/plg-agent/metrics.d/*.yaml` | Target `/metrics` aplikasi native |
| `/var/lib/plg-agent/textfile/*.prom` | Metrik custom dari script, mis. waktu backup terakhir |

Contoh `logs.d/myapp.yaml` dan `metrics.d/myapp.yaml`:

```yaml
- targets: [localhost]
  labels:
    __path__: /var/www/myapp/storage/logs/*.log
    service: myapp
```

```yaml
- targets: ["127.0.0.1:9100"]
  labels:
    job: myapp
```

### Pengaturan per container (label Docker)

| Label | Fungsi |
|---|---|
| `plg.logs=false` | Log container ini tidak dikirim |
| `plg.metrics=false` | Metrik container ini tidak dikumpulkan |
| `plg.service=NAMA` | Nama service di dashboard |
| `plg.scrape=true` | Ambil `/metrics` container ini (modul `docker-apps`) |
| `plg.port`, `plg.path`, `plg.scheme`, `plg.job` | Detail scrape |
| `plg.address=IP:PORT` | Alamat scrape eksplisit, mis. port yang di-publish bila jaringan container tidak terjangkau dari host (overlay Swarm) |

Container yang tidak bisa diberi label bisa dikecualikan dengan
`--exclude-containers REGEX`.

### Mode offline

Saat PLG Stack tidak bisa dihubungi (jaringan putus, stack sedang pindah, dll.),
agent tetap mengumpulkan data:

- **Metrik** disimpan di disk agent hingga `--offline-buffer` (default 24 jam).
  Stack menerimanya selama `PROMETHEUS_OOO_WINDOW` (samakan atau lebihkan).
- **Log** ditahan di sumbernya: journald, file log, dan log container. Agent
  berhenti membaca saat antrean kirim penuh, lalu melanjutkan dari posisi
  terakhir begitu terhubung. Batasnya rotasi log di server itu sendiri. Jika
  agent di-restart saat offline, maksimal ±10 MB log terakhir di antrean memori
  bisa hilang.
- **Journald di disk** (ditawarkan installer) membuat log sebelum server mati
  atau reboot tetap ada dan terkirim setelah server hidup lagi.

Di Host Detail, panel **Keterlambatan kirim agent** menunjukkan periode
terputus: saat jaringan putus, grafiknya naik lalu turun setelah backlog
terkirim. Jika server mati, grafik kosong karena memang tidak ada data yang
dikumpulkan.

### Log pipeline

Semua log melewati pipeline yang sama sebelum dikirim:

- `--log-drop REGEX`: buang baris yang cocok (mis. log health check).
- Multi-baris: stack trace digabung menjadi satu entri. Baris yang diawali spasi
  dianggap lanjutan; ubah dengan `--multiline REGEX`.
- Sensor rahasia: nilai password, token, secret, api key, header Authorization,
  dan password di URL diganti `***`. Matikan dengan `--no-redact`.

## 3. Dashboard dan alert

Dashboard di folder **PLG Stack**:

- **Fleet Overview**: semua server dalam satu tabel, server yang berhenti
  mengirim data, dan nama server yang dipakai lebih dari satu mesin.
- **Host Detail**: satu server lengkap, termasuk proses teratas, status koneksi
  agent, dan log journald.
- **Containers**: pemakaian per service/container dan log container per level.
- **Logs**: pencarian log lintas server, filter per level.
- **Databases**: PostgreSQL, MySQL/MariaDB, Redis, MongoDB.
- **Uptime**: persentase waktu tiap server mengirim data, total waktu tidak
  melapor, reboot, timeline status, serta ketersediaan database dan komponen
  stack.
- **Riwayat Alert**: alert yang sedang aktif, seberapa sering tiap alert
  berbunyi, evaluasi rule yang gagal, serta daftar perubahan status. Riwayatnya
  disimpan Grafana di Loki.
- **PLG Stack Health**: kesehatan komponen, ingest metrik dan log (termasuk
  data yang ditolak), disk metrik vs batas, volume per server, status agent,
  dan status backup.

**Navigasi**: klik nama host di tabel mana pun untuk membuka Host Detail,
Containers, Logs, atau Uptime yang sudah terfilter ke server itu, dengan
rentang waktu yang sama. Klik garis pada grafik per server untuk membuka
detail server tersebut; di Containers, untuk membuka log service-nya. Host
Detail punya link ke container, log, dan uptime server yang sama di kanan atas.

Alert rules (folder **Alerts**): server tidak mengirim data, disk >85% / >95%,
disk diprediksi penuh dalam 24 jam, RAM >90%, CPU >90%, container sering
restart, dan database tidak bisa diakses. Angka-angka itu default dari
`grafana/generator/config.toml`.

### Mengaktifkan notifikasi

Tujuan notifikasi belum ditentukan, jadi contoh disediakan terpisah:

1. Salin **satu** file dari `grafana/alerting-examples/` ke
   `grafana/provisioning/alerting/`. Setiap file mengganti seluruh notification
   policy, jadi jangan salin lebih dari satu.
2. Isi variabelnya di `.env`: `ALERT_TELEGRAM_*`, `ALERT_SLACK_WEBHOOK_URL`,
   atau `ALERT_EMAIL_ADDRESSES` + `GF_SMTP_*`.
3. Commit, lalu redeploy.

### Threshold, teks, dan bahasa

Dashboard dan alert rules dibuat oleh generator dari satu config,
`grafana/generator/config.toml`:

- **Threshold**: warna panel (oranye dan merah) dan alert memakai angka yang
  sama. Misalnya `memory = { warning = 85, critical = 95 }` mengubah warna
  panel RAM di semua dashboard sekaligus alert "RAM hampir habis".
- **Durasi**: kapan server dianggap tidak melapor, prediksi disk penuh, batas
  restart container, dan berapa lama kondisi bertahan sebelum alert berbunyi.
- **Bahasa**: `language = "id"` atau `"en"`. Teksnya ada di
  `grafana/generator/lang/`; teks tertentu bisa diganti lewat bagian `[text]`.

Setelah mengubah config (butuh Python 3.11+):

```bash
python3 grafana/generator/generate.py
tests/run.sh
```

Commit config beserta file hasilnya, lalu redeploy. Dashboard di-provision
read-only. Simpan dashboard buatan sendiri di folder lain, misalnya
`grafana/dashboards/Custom/`: folder **PLG Stack** milik generator, dan test
menolak file lain di sana.

## 4. Backup dan restore

Aktifkan lewat `scripts/setup.sh` (bagian Backup), atau isi `BACKUP_*` di
`.env` lalu tambahkan `backup` ke `COMPOSE_PROFILES`. Service `backup` membuat
backup setiap hari pada jam `BACKUP_SCHEDULE` (zona waktu `TZ`):

- **Tanpa downtime.** Data Prometheus dan Loki di-snapshot dengan hard link
  (instan, tanpa menyalin data), Loki diminta menulis log yang masih di memori
  ke disk lebih dulu, dan `grafana.db` hanya disalin saat tidak ada transaksi
  yang sedang berjalan.
- **Terenkripsi dan bertahap.** Memakai [restic](https://restic.net): semua
  data dienkripsi dengan `BACKUP_PASSWORD`, dan setelah backup pertama hanya
  data yang berubah yang diunggah.
- **Tujuan**: bucket S3 / S3-compatible (AWS, MinIO, Cloudflare R2, Wasabi),
  atau `/local` (folder `BACKUP_LOCAL_DIR` di server ini).
- **Retensi**: `BACKUP_KEEP_DAILY`, `BACKUP_KEEP_WEEKLY`, `BACKUP_KEEP_MONTHLY`;
  backup yang lebih lama dihapus otomatis.
- **Isi**: metrik, log (bila Loki menyimpan di disk lokal; di mode S3 log sudah
  ada di bucket), database Grafana (bila SQLite), dan sertifikat TLS. Bisa
  dipilih lewat `BACKUP_TARGETS`.

Status backup terakhir tampil di **PLG Stack Health**. Arahkan
`BACKUP_PING_URL` dan `BACKUP_FAIL_URL` ke layanan seperti healthchecks.io
supaya ada peringatan saat backup gagal atau berhenti berjalan.

Perintah manual, dari folder repo di server stack:

```bash
docker compose exec backup sh /backup/backup.sh run         # backup sekarang
docker compose exec backup sh /backup/backup.sh snapshots   # daftar backup
docker compose exec backup sh /backup/backup.sh check       # verifikasi repository (membaca 5% data)
scripts/restore.sh                                          # pulihkan backup terbaru (stack dihentikan dulu)
scripts/restore.sh 20261008-020000                          # pulihkan backup tertentu
```

Di Dokploy, project compose diberi nama sesuai aplikasinya, jadi panggil
container-nya langsung (ganti `<app-name>`):

```bash
docker exec $(docker ps -q -f label=com.docker.compose.project=<app-name> -f label=com.docker.compose.service=backup) \
  sh /backup/backup.sh run
```

**Simpan `BACKUP_PASSWORD` di luar server** (misalnya di password manager):
tanpa password itu backup tidak bisa dibuka.

## 5. Memindahkan stack ke server lain

1. Di server lama, buat backup terakhir dengan `backup.sh run` (lihat perintah di
   [Backup dan restore](#4-backup-dan-restore)).
2. Di server baru: clone repo ini dan salin `.env` (dengan `BACKUP_*` yang sama).
   Untuk tujuan `/local`, salin juga isi folder `BACKUP_LOCAL_DIR`.
3. Pulihkan datanya:
   - **Standalone**: ubah `.env` ke mode standalone bila perlu
     (`./scripts/setup.sh`), lalu `scripts/restore.sh`. Stack langsung
     dinyalakan.
   - **Dokploy**: deploy sekali, *Stop*, lalu dari folder kode aplikasi itu
     jalankan `scripts/restore.sh --project <app-name> --no-start`, dan Deploy
     lagi.
4. Ubah DNS `grafana.*` dan `ingest.*` ke server baru.
5. Matikan stack di server lama.

Agent tidak perlu diubah; selama DNS berpindah, data ditahan oleh mode offline.
Kalau histori metrik tidak perlu ikut, langkah 1–3 cukup diganti deploy baru.

## Keamanan

- Yang terbuka ke luar hanya gateway (80/443). Prometheus dan Loki tidak
  di-expose; query lewat Grafana.
- Setiap server punya token sendiri (`AGENT_TOKENS`). Token yang dicabut langsung
  ditolak setelah gateway dimuat ulang.
- Fitur snapshot eksternal Grafana (publikasi dashboard ke snapshots.raintank.io)
  dimatikan.
- Agent mode docker hanya berjalan `--privileged` bila modul yang dipilih
  membutuhkannya; filesystem host selalu di-mount read-only. UI Alloy hanya
  listen di `127.0.0.1:12345`.
- File kredensial agent: `/etc/plg-agent/agent.env`, mode `600`.
- Backup dienkripsi sebelum meninggalkan server (`BACKUP_PASSWORD`).

## Pengembangan

```bash
tests/run.sh
```

Test berjalan tanpa root, Docker, atau jaringan: parser katalog modul,
penyimpanan konfigurasi agent, pemilihan modul, batas memori, token gateway,
`agent-token.sh`, generator dashboard (hasilnya sesuai config, struktur
dashboard, threshold panel sama dengan alert), backup dan restore (dengan
restic tiruan), dan `doctor.sh`. Test generator butuh Python 3.11+.

## Troubleshooting

Mulai dari `scripts/doctor.sh`. Script ini memeriksa konfigurasi, DNS,
sertifikat TLS, endpoint ingest, container, data yang ditolak Prometheus atau
Loki, server yang berhenti melapor, token tanpa data, backup, dan disk, lalu
menyarankan perbaikannya. Di laptop, yang dicek hanya konfigurasi dan endpoint
publik; di server stack, semuanya.

```bash
scripts/doctor.sh                # seluruh stack
scripts/doctor.sh --host db-01   # detail satu server yang dipantau
```

| Gejala | Cek |
|---|---|
| Server tidak muncul di dashboard | `docker logs plg-agent` / `journalctl -u alloy`; `curl -u NAMA:TOKEN https://ingest.../ping` |
| Installer: token ditolak (401) | Nama server harus sama dengan nama token; cek `scripts/agent-token.sh list` |
| Komponen agent tidak sehat | UI Alloy: `ssh -L 12345:127.0.0.1:12345 server`, lalu buka http://localhost:12345 |
| Database `DOWN` | Kredensial DSN salah, atau user belum punya grant yang dibutuhkan |
| File log tidak masuk (native) | Agent berjalan sebagai user `alloy` (grup `adm`, `systemd-journal`); beri izin baca, atau pilih modul `process` yang memberi akses baca penuh |
| Log ditolak / `rate_limited` | Lihat PLG Stack Health → *Log ditolak Loki*; naikkan `LOKI_INGESTION_RATE_MB` atau kurangi log dengan `--log-drop` |
