#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -t 1 ]]; then
	BOLD=$'\e[1m' DIM=$'\e[2m' BLUE=$'\e[34m' RESET=$'\e[0m'
else
	BOLD="" DIM="" BLUE="" RESET=""
fi

info() { printf '\n%s\n' "${BLUE}==>${RESET} ${BOLD}$*${RESET}"; }
note() { printf '%s\n' "  ${DIM}$*${RESET}"; }
die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

ask() {
	local var="$1" prompt="$2" default="${3:-}" pattern="${4:-}" answer
	while :; do
		if [[ -n "$default" ]]; then
			read -r -p "  $prompt ${DIM}[$default]${RESET}: " answer
		else
			read -r -p "  $prompt: " answer
		fi
		answer="${answer:-$default}"
		if [[ "$answer" == *"'"* ]]; then
			echo "  Nilai tidak boleh mengandung tanda kutip tunggal."
			continue
		fi
		if [[ -n "$pattern" && ! "$answer" =~ $pattern ]]; then
			echo "  Format tidak valid."
			continue
		fi
		break
	done
	printf -v "$var" '%s' "$answer"
}

confirm() {
	local answer
	read -r -p "  $1 ${DIM}[$( [[ "${2:-y}" == y ]] && echo Y/n || echo y/N)]${RESET}: " answer
	answer="${answer:-${2:-y}}"
	[[ "${answer,,}" =~ ^(y|yes|ya)$ ]]
}

random_password() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

local_timezone() {
	timedatectl show -p Timezone --value 2>/dev/null ||
		readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p' | grep . ||
		echo UTC
}

DURATION='^[0-9]+(ms|s|m|h|d|w|y)$'
SIZE='^[0-9]+(B|KB|MB|GB|TB|PB)$'

declare -A OLD=()
declare -a OLD_ORDER=()

load_existing() {
	local line key value
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
		key="${BASH_REMATCH[1]}"
		value="${BASH_REMATCH[2]}"
		value="${value#\'}"
		value="${value%\'}"
		OLD[$key]="$value"
		OLD_ORDER+=("$key")
	done <.env
}

old() { printf '%s' "${OLD[$1]:-${2:-}}"; }

[[ -t 0 ]] || die "Script ini interaktif; jalankan langsung dari terminal."

if [[ -f .env ]]; then
	load_existing
	confirm ".env sudah ada. Nilai lama dipakai sebagai default dan file ditimpa. Lanjut?" y || exit 0
fi

MANAGED=()
set_value() {
	printf -v "$1" '%s' "$2"
	MANAGED+=("$1")
}

info "Mode deploy"
echo "  standalone : server biasa; Caddy memegang port 80/443 dan mengurus sertifikat TLS."
echo "  dokploy    : deploy sebagai Compose di Dokploy; Traefik Dokploy mengurus domain dan TLS."
default_mode=standalone
[[ "$(old GATEWAY_SCHEME)" == http ]] && default_mode=dokploy
ask MODE "Pilih mode (standalone/dokploy)" "$default_mode" '^(standalone|dokploy)$'
if [[ "$MODE" == standalone ]]; then
	set_value GATEWAY_SCHEME https
else
	set_value GATEWAY_SCHEME http
fi

info "Domain"
note "Agent mengirim data ke domain ingest. Saat stack pindah server, cukup ubah DNS-nya."
ask value "Domain Grafana" "$(old GRAFANA_DOMAIN grafana.example.com)" '^[A-Za-z0-9.-]+$'
set_value GRAFANA_DOMAIN "$value"
ask value "Domain ingest" "$(old INGEST_DOMAIN ingest.example.com)" '^[A-Za-z0-9.-]+$'
set_value INGEST_DOMAIN "$value"

info "Login Grafana"
ask value "User admin Grafana" "$(old GRAFANA_ADMIN_USER admin)"
set_value GRAFANA_ADMIN_USER "$value"
ask value "Password admin Grafana" "$(old GRAFANA_ADMIN_PASSWORD "$(random_password)")"
set_value GRAFANA_ADMIN_PASSWORD "$value"

info "Self-monitoring"
note "Server tempat stack ini berjalan ikut dipantau seperti server lain (metrik, log, container)."
old_profiles=",$(old COMPOSE_PROFILES self-monitoring),"
PROFILES=()
if confirm "Pantau server stack ini sendiri?" "$([[ "$old_profiles" == *,self-monitoring,* ]] && echo y || echo n)"; then
	PROFILES+=(self-monitoring)
	ask value "Nama server ini di dashboard" "$(old SELF_MONITORING_NAME plg-stack)" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
	set_value SELF_MONITORING_NAME "$value"
	ask value "Environment" "$(old SELF_MONITORING_ENV production)" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
	set_value SELF_MONITORING_ENV "$value"
	set_value SELF_MONITORING_TOKEN "$(old SELF_MONITORING_TOKEN "$(random_password)")"
fi

info "Watchdog (heartbeat eksternal)"
note "Kalau server stack mati, Grafana ikut mati dan tidak bisa mengirim alert. Watchdog mengirim"
note "heartbeat tiap menit ke layanan luar (mis. healthchecks.io atau Uptime Kuma push monitor);"
note "layanan itu yang memberi tahu kalau heartbeat berhenti. Kosongkan untuk melewati."
ask value "URL heartbeat" "$(old WATCHDOG_URL)" '^(https?://.+)?$'
set_value WATCHDOG_URL "$value"

info "Resource"
note "Batas memori per service supaya stack tidak mengganggu aplikasi lain di server ini."
echo "  small  : server 2-4 GB RAM     medium : 8 GB RAM     large : 16 GB RAM atau lebih"
echo "  custom : isi sendiri per service"
ask PROFILE "Profil" "$(old RESOURCE_PROFILE medium)" '^(small|medium|large|custom)$'
set_value RESOURCE_PROFILE "$PROFILE"
case "$PROFILE" in
small) limits=(512m 512m 256m 128m 256m) ;;
medium) limits=(1g 1g 512m 256m 512m) ;;
large) limits=(4g 4g 1g 512m 512m) ;;
custom) limits=("$(old PROMETHEUS_MEMORY_LIMIT 1g)" "$(old LOKI_MEMORY_LIMIT 1g)" "$(old GRAFANA_MEMORY_LIMIT 512m)"
	"$(old GATEWAY_MEMORY_LIMIT 256m)" "$(old SELF_MONITORING_MEMORY_LIMIT 512m)") ;;
esac
i=0
for key in PROMETHEUS_MEMORY_LIMIT LOKI_MEMORY_LIMIT GRAFANA_MEMORY_LIMIT GATEWAY_MEMORY_LIMIT SELF_MONITORING_MEMORY_LIMIT; do
	value="${limits[$i]}"
	[[ "$PROFILE" == custom ]] && ask value "$key" "$value" '^[0-9]+[kmg]?$'
	set_value "$key" "$value"
	i=$((i + 1))
done

info "Retensi data"
ask value "Retensi metrik (Prometheus)" "$(old PROMETHEUS_RETENTION 15d)" "$DURATION"
set_value PROMETHEUS_RETENTION "$value"
ask value "Batas ukuran metrik" "$(old PROMETHEUS_RETENTION_SIZE 8GB)" "$SIZE"
set_value PROMETHEUS_RETENTION_SIZE "$value"
ask value "Retensi log (default semua log)" "$(old LOKI_RETENTION 14d)" "$DURATION"
set_value LOKI_RETENTION "$value"
note "Log bisa disimpan lebih singkat per jenis supaya disk lebih hemat."
ask value "Retensi log sistem (journald)" "$(old LOKI_RETENTION_JOURNAL "$LOKI_RETENTION")" "$DURATION"
set_value LOKI_RETENTION_JOURNAL "$value"
ask value "Environment dengan retensi singkat (regex)" "$(old LOKI_SHORT_RETENTION_ENVS 'development|dev|local.*|test.*')"
set_value LOKI_SHORT_RETENTION_ENVS "$value"
ask value "Retensi log environment tersebut" "$(old LOKI_SHORT_RETENTION "$LOKI_RETENTION")" "$DURATION"
set_value LOKI_SHORT_RETENTION "$value"

info "Mode offline agent"
note "Agent yang terputus mengirim ulang datanya setelah tersambung lagi. Stack menerima metrik"
note "selama jendela ini; samakan atau lebihkan dari --offline-buffer di installer agent (default 24h)."
ask value "Terima metrik terlambat hingga" "$(old PROMETHEUS_OOO_WINDOW 24h)" '^[0-9]+[hm]$'
set_value PROMETHEUS_OOO_WINDOW "$value"

info "Penyimpanan log"
echo "  local : di volume Docker server ini (ikut dipindah lewat backup/restore)."
echo "  s3    : di bucket S3 / S3-compatible (tidak perlu dipindah, disk lokal aman)."
default_storage=local
[[ "$(old LOKI_CONFIG)" == loki-s3.yaml ]] && default_storage=s3
ask STORAGE "Pilih (local/s3)" "$default_storage" '^(local|s3)$'
if [[ "$STORAGE" == s3 ]]; then
	set_value LOKI_CONFIG loki-s3.yaml
	ask value "Nama bucket" "$(old LOKI_S3_BUCKET)"
	set_value LOKI_S3_BUCKET "$value"
	ask value "Region" "$(old LOKI_S3_REGION ap-southeast-1)"
	set_value LOKI_S3_REGION "$value"
	note "Kosongkan endpoint dan key jika memakai AWS S3 dengan IAM role."
	ask value "Endpoint (MinIO/R2/dll.)" "$(old LOKI_S3_ENDPOINT)"
	set_value LOKI_S3_ENDPOINT "$value"
	ask value "Access key ID" "$(old LOKI_S3_ACCESS_KEY_ID)"
	set_value LOKI_S3_ACCESS_KEY_ID "$value"
	ask value "Secret access key" "$(old LOKI_S3_SECRET_ACCESS_KEY)"
	set_value LOKI_S3_SECRET_ACCESS_KEY "$value"
	set_value LOKI_S3_FORCE_PATH_STYLE "$([[ -n "$LOKI_S3_ENDPOINT" ]] && echo true || echo false)"
else
	set_value LOKI_CONFIG loki.yaml
fi

info "Log container stack"
note "Docker menyimpan log container tanpa batas kecuali dirotasi."
ask value "Ukuran maksimum per file log" "$(old LOG_MAX_SIZE 10m)" '^[0-9]+[kmg]$'
set_value LOG_MAX_SIZE "$value"
ask value "Jumlah file log yang disimpan" "$(old LOG_MAX_FILE 3)" '^[0-9]+$'
set_value LOG_MAX_FILE "$value"

info "Backup"
note "Backup harian terenkripsi (restic) untuk metrik, log, Grafana, dan sertifikat TLS, dibuat tanpa"
note "menghentikan stack. Setelah backup pertama, hanya data yang berubah yang diunggah."
if confirm "Aktifkan backup terjadwal?" "$([[ "$old_profiles" == *,backup,* ]] && echo y || echo n)"; then
	PROFILES+=(backup)
	echo "  s3    : bucket S3 / S3-compatible (AWS, MinIO, Cloudflare R2, Wasabi); aman walau server ini rusak."
	echo "  local : folder di server ini; salin ke tempat lain secara berkala."
	old_repo="$(old BACKUP_REPOSITORY)"
	ask KIND "Tujuan (s3/local)" "$([[ "$old_repo" == /local ]] && echo local || echo s3)" '^(s3|local)$'
	if [[ "$KIND" == s3 ]]; then
		endpoint=s3.amazonaws.com bucket="" prefix=plg-stack
		if [[ "$old_repo" =~ ^s3:(https?://)?([^/]+)/([^/]+)/?(.*)$ ]]; then
			endpoint="${BASH_REMATCH[2]}" bucket="${BASH_REMATCH[3]}" prefix="${BASH_REMATCH[4]}"
		fi
		note "AWS: s3.<region>.amazonaws.com. MinIO, R2, Wasabi: endpoint dari penyedianya."
		ask endpoint "Endpoint S3" "$endpoint" '^[A-Za-z0-9.:-]+$'
		ask bucket "Bucket" "$bucket" '^[A-Za-z0-9][A-Za-z0-9.-]+$'
		ask prefix "Folder di dalam bucket" "$prefix" '^[A-Za-z0-9._/-]*$'
		set_value BACKUP_REPOSITORY "s3:https://$endpoint/$bucket${prefix:+/$prefix}"
		ask value "Access key ID" "$(old BACKUP_S3_ACCESS_KEY_ID)"
		set_value BACKUP_S3_ACCESS_KEY_ID "$value"
		ask value "Secret access key" "$(old BACKUP_S3_SECRET_ACCESS_KEY)"
		set_value BACKUP_S3_SECRET_ACCESS_KEY "$value"
		ask value "Region (kosongkan bila tidak tahu)" "$(old BACKUP_S3_REGION)"
		set_value BACKUP_S3_REGION "$value"
	else
		set_value BACKUP_REPOSITORY /local
		ask value "Folder backup di server ini" "$(old BACKUP_LOCAL_DIR /var/backups/plg-stack)" '^/.+'
		set_value BACKUP_LOCAL_DIR "$value"
	fi
	note "Password ini mengenkripsi backup. Simpan salinannya di luar server ini (mis. password manager);"
	note "tanpa password ini backup tidak bisa dibuka, termasuk saat memindahkan stack."
	ask value "Password backup" "$(old BACKUP_PASSWORD "$(random_password)")"
	set_value BACKUP_PASSWORD "$value"
	ask value "Jam backup harian (HH:MM, pisahkan koma untuk beberapa kali sehari)" "$(old BACKUP_SCHEDULE 02:00)" \
		'^([01][0-9]|2[0-3]):[0-5][0-9](,([01][0-9]|2[0-3]):[0-5][0-9])*$'
	set_value BACKUP_SCHEDULE "$value"
	ask value "Zona waktu jam backup" "$(old TZ "$(local_timezone)")" '^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$'
	set_value TZ "$value"
	note "Backup lama dihapus otomatis; yang disimpan:"
	ask value "Backup harian terakhir" "$(old BACKUP_KEEP_DAILY 7)" '^[0-9]+$'
	set_value BACKUP_KEEP_DAILY "$value"
	ask value "Backup mingguan terakhir" "$(old BACKUP_KEEP_WEEKLY 4)" '^[0-9]+$'
	set_value BACKUP_KEEP_WEEKLY "$value"
	ask value "Backup bulanan terakhir" "$(old BACKUP_KEEP_MONTHLY 6)" '^[0-9]+$'
	set_value BACKUP_KEEP_MONTHLY "$value"
	note "Opsional: URL yang dipanggil setiap backup berhasil (mis. healthchecks.io), supaya ada"
	note "peringatan bila backup berhenti berjalan."
	ask value "URL ping backup" "$(old BACKUP_PING_URL)" '^(https?://.+)?$'
	set_value BACKUP_PING_URL "$value"
	[[ " ${PROFILES[*]} " == *" self-monitoring "* ]] ||
		note "Status backup tampil di dashboard PLG Stack Health bila self-monitoring aktif."
fi
set_value COMPOSE_PROFILES "$(
	IFS=,
	echo "${PROFILES[*]}"
)"

if [[ "$MODE" == standalone ]]; then
	set_value COMPOSE_FILE compose.yaml:compose.standalone.yaml
else
	set_value COMPOSE_FILE ""
fi

{
	echo "# Generated by scripts/setup.sh; see .env.example for every option."
	for key in "${MANAGED[@]}"; do
		if [[ -n "${!key}" ]]; then
			printf "%s='%s'\n" "$key" "${!key}"
		fi
	done
	# Keep everything else (agent tokens, alerting, manual tweaks).
	for key in "${OLD_ORDER[@]}"; do
		if [[ " ${MANAGED[*]} " != *" $key "* ]]; then
			printf "%s='%s'\n" "$key" "${OLD[$key]}"
		fi
	done
} >.env.tmp
chmod 600 .env.tmp
mv .env.tmp .env

info "Selesai, .env ditulis"
if [[ "$MODE" == standalone ]]; then
	cat <<EOF
  1. Arahkan DNS A record $GRAFANA_DOMAIN dan $INGEST_DOMAIN ke IP server ini.
  2. Buka port 80 dan 443 (TCP, plus 443/UDP untuk HTTP/3).
  3. Jalankan: docker compose up -d
EOF
else
	cat <<EOF
  Di Dokploy:
  1. Create Service → Compose (tipe Docker Compose), sumber: repo ini, Compose Path ./compose.yaml
  2. Tab Environment → tempel seluruh isi .env (lihat: cat .env).
  3. Tab Domains → tambah dua domain, keduanya ke service "gateway" port 80, HTTPS aktif:
       $GRAFANA_DOMAIN
       $INGEST_DOMAIN
  4. Deploy.
EOF
fi
cat <<EOF

  Grafana : https://$GRAFANA_DOMAIN  (user: $GRAFANA_ADMIN_USER)
  Tambah server yang dipantau: scripts/agent-token.sh add NAMA-SERVER
  (membuat token untuk server itu dan menampilkan perintah install agent-nya)
EOF
if [[ " ${PROFILES[*]} " == *" backup "* ]]; then
	echo "  Simpan BACKUP_PASSWORD dari .env di luar server ini; tanpa itu backup tidak bisa dipulihkan."
fi
