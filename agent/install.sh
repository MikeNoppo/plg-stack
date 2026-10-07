#!/usr/bin/env bash
# Installs the monitoring agent (Grafana Alloy) on a server to be monitored.
#
#   curl -fsSL https://INGEST_DOMAIN/agent/install.sh | sudo bash
#   curl -fsSL https://INGEST_DOMAIN/agent/install.sh | sudo bash -s -- \
#     --url https://INGEST_DOMAIN --user agent --password SECRET --name db-01 --env production --yes
#   sudo bash install.sh --uninstall
#
# Run `install.sh --help` for every option.
set -euo pipefail

ALLOY_VERSION="${ALLOY_VERSION:-v1.20.1}"
CONTAINER_NAME="monitoring-agent"
DOCKER_DIR="/opt/monitoring-agent"
NATIVE_DIR="/etc/alloy/monitoring"
NATIVE_ENV="/etc/alloy/monitoring.env"
NATIVE_DROPIN="/etc/systemd/system/alloy.service.d/monitoring.conf"
ALLOY_HTTP="127.0.0.1:12345"
DB_MODULES=(postgres mysql redis mongodb)

MONITORING_URL="${MONITORING_URL:-}"
MONITORING_USER="${MONITORING_USER:-}"
MONITORING_PASSWORD="${MONITORING_PASSWORD:-}"
MONITORING_HOST="${MONITORING_HOST:-}"
MONITORING_ENV="${MONITORING_ENV:-}"
MONITORING_SOURCE_URL="${MONITORING_SOURCE_URL:-}"
POSTGRES_DSN="${POSTGRES_DSN:-}"
MYSQL_DSN="${MYSQL_DSN:-}"
REDIS_ADDR="${REDIS_ADDR:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
MONGODB_URI="${MONGODB_URI:-}"
MODE=""
ASSUME_YES=0
UNINSTALL=0
DOCKER_MODULE=""

declare -A DB_NATIVE=() DB_CONTAINER=()
declare -a MODULES=()

if [[ -t 1 ]]; then
	BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' BLUE=$'\e[34m' RESET=$'\e[0m'
else
	BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" RESET=""
fi

info() { printf '%s\n' "${BLUE}==>${RESET} $*"; }
ok() { printf '%s\n' "${GREEN}  ✓${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}  !${RESET} $*" >&2; }
die() {
	printf '%s\n' "${RED}ERROR:${RESET} $*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Install agent monitoring (Grafana Alloy) di server ini.

Tanpa opsi, installer berjalan interaktif: memeriksa server, merekomendasikan
mode, lalu menanyakan yang perlu diisi.

Opsi:
  --url URL             Alamat ingest stack monitoring, mis. https://ingest.example.com
  --user USER           User basic auth ingest
  --password PASS       Password basic auth ingest
  --name NAME           Nama server di dashboard (default: hostname)
  --env ENV             Label environment: production, staging, development, ...
  --mode MODE           docker | native (default: rekomendasi installer)
  --no-docker-metrics   Jangan pantau container Docker walau Docker terdeteksi
  --postgres-dsn DSN    Aktifkan modul PostgreSQL
  --mysql-dsn DSN       Aktifkan modul MySQL/MariaDB
  --redis-addr ADDR     Aktifkan modul Redis (mis. 127.0.0.1:6379)
  --redis-password PW   Password Redis
  --mongodb-uri URI     Aktifkan modul MongoDB
  --source URL          Lokasi file modul (default: <url>/agent)
  --yes, -y             Non-interaktif: pakai nilai dari opsi/env dan default
  --uninstall           Hapus agent dari server ini
  --help, -h            Tampilkan bantuan ini

Setiap opsi juga bisa diisi lewat variabel lingkungan dengan nama yang sama
seperti di file env agent (MONITORING_URL, MONITORING_PASSWORD, POSTGRES_DSN, ...).
EOF
}

parse_args() {
	while (($#)); do
		case "$1" in
		--url) MONITORING_URL="${2:?--url butuh nilai}" && shift ;;
		--user) MONITORING_USER="${2:?--user butuh nilai}" && shift ;;
		--password) MONITORING_PASSWORD="${2:?--password butuh nilai}" && shift ;;
		--name) MONITORING_HOST="${2:?--name butuh nilai}" && shift ;;
		--env) MONITORING_ENV="${2:?--env butuh nilai}" && shift ;;
		--mode) MODE="${2:?--mode butuh nilai}" && shift ;;
		--no-docker-metrics) DOCKER_MODULE="no" ;;
		--postgres-dsn) POSTGRES_DSN="${2:?--postgres-dsn butuh nilai}" && shift ;;
		--mysql-dsn) MYSQL_DSN="${2:?--mysql-dsn butuh nilai}" && shift ;;
		--redis-addr) REDIS_ADDR="${2:?--redis-addr butuh nilai}" && shift ;;
		--redis-password) REDIS_PASSWORD="${2:?--redis-password butuh nilai}" && shift ;;
		--mongodb-uri) MONGODB_URI="${2:?--mongodb-uri butuh nilai}" && shift ;;
		--source) MONITORING_SOURCE_URL="${2:?--source butuh nilai}" && shift ;;
		--yes | -y) ASSUME_YES=1 ;;
		--uninstall) UNINSTALL=1 ;;
		--help | -h) usage && exit 0 ;;
		*) die "Opsi tidak dikenal: $1 (lihat --help)" ;;
		esac
		shift
	done
	[[ -z "$MODE" || "$MODE" == docker || "$MODE" == native ]] || die "--mode harus docker atau native"
}

# --- prompts -----------------------------------------------------------------
# `curl | bash` gives the script on stdin, so answers are read from the terminal.

interactive() { [[ $ASSUME_YES -eq 0 && -r /dev/tty ]]; }

ask() {
	local var="$1" prompt="$2" default="${3:-}" answer
	if ! interactive; then
		printf -v "$var" '%s' "$default"
		return
	fi
	if [[ -n "$default" ]]; then
		read -r -p "  $prompt ${DIM}[$default]${RESET}: " answer </dev/tty
	else
		read -r -p "  $prompt: " answer </dev/tty
	fi
	printf -v "$var" '%s' "${answer:-$default}"
}

ask_secret() {
	local var="$1" prompt="$2" default="${3:-}" answer hint=""
	if ! interactive; then
		printf -v "$var" '%s' "$default"
		return
	fi
	[[ -n "$default" ]] && hint=" ${DIM}[Enter = pakai yang lama]${RESET}"
	read -r -s -p "  $prompt$hint: " answer </dev/tty
	echo >/dev/tty
	printf -v "$var" '%s' "${answer:-$default}"
}

confirm() {
	local prompt="$1" default="${2:-y}" answer
	if ! interactive; then
		[[ "$default" == y ]]
		return
	fi
	if [[ "$default" == y ]]; then
		read -r -p "  $prompt ${DIM}[Y/n]${RESET}: " answer </dev/tty
	else
		read -r -p "  $prompt ${DIM}[y/N]${RESET}: " answer </dev/tty
	fi
	answer="${answer:-$default}"
	[[ "${answer,,}" == y || "${answer,,}" == yes || "${answer,,}" == ya ]]
}

random_password() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# --- detection ---------------------------------------------------------------

detect_system() {
	OS_PRETTY="unknown"
	if [[ -r /etc/os-release ]]; then
		# shellcheck disable=SC1091
		OS_PRETTY="$(. /etc/os-release && echo "${PRETTY_NAME:-$ID}")"
	fi

	PKG=""
	if command -v apt-get >/dev/null; then
		PKG=apt
	elif command -v dnf >/dev/null; then
		PKG=dnf
	elif command -v yum >/dev/null; then
		PKG=yum
	fi

	HAS_SYSTEMD=0
	[[ -d /run/systemd/system ]] && HAS_SYSTEMD=1

	CPU_COUNT="$(nproc 2>/dev/null || echo "?")"
	MEM_GB="$(awk '/^MemTotal:/ {printf "%.1f", $2 / 1048576}' /proc/meminfo)"
	ROOT_DISK="$(df -P / | awk 'NR == 2 {print $5}')"

	HAS_DOCKER=0 DOCKER_VERSION="" CONTAINER_COUNT=0 DOKPLOY=""
	if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
		HAS_DOCKER=1
		DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
		CONTAINER_COUNT="$(docker ps -q | wc -l)"
		local names
		names="$(docker ps --format '{{.Names}}')"
		if grep -q '^dokploy\.' <<<"$names"; then
			DOKPLOY="server utama Dokploy"
		elif grep -q '^dokploy-traefik' <<<"$names"; then
			DOKPLOY="server yang dikelola Dokploy"
		fi
	fi

	OTHER_AGENTS=()
	local svc
	for svc in node_exporter prometheus-node-exporter promtail grafana-agent; do
		if systemctl is-active --quiet "$svc" 2>/dev/null; then
			OTHER_AGENTS+=("$svc")
		fi
	done
	if [[ $HAS_DOCKER -eq 1 ]]; then
		local image
		while read -r image; do
			case "$image" in
			*node-exporter* | *cadvisor* | *promtail* | *grafana/agent*) OTHER_AGENTS+=("container $image") ;;
			esac
		done < <(docker ps --format '{{.Image}}')
	fi
}

in_container() { grep -qE 'docker|containerd|kubepods|libpod' "/proc/$1/cgroup" 2>/dev/null; }

detect_databases() {
	local db pattern pid
	declare -A patterns=(
		[postgres]='postgres|postmaster'
		[mysql]='mysqld|mariadbd'
		[redis]='redis-server'
		[mongodb]='mongod'
	)
	for db in "${DB_MODULES[@]}"; do
		pattern="${patterns[$db]}"
		for pid in $(pgrep -x "$pattern" 2>/dev/null || true); do
			if in_container "$pid"; then
				DB_CONTAINER[$db]=1
			else
				DB_NATIVE[$db]=1
			fi
		done
	done
}

detect_existing() {
	EXISTING=""
	if [[ -f "$NATIVE_ENV" ]]; then
		EXISTING=native
		load_env_file "$NATIVE_ENV"
	elif [[ -f "$DOCKER_DIR/agent.env" ]]; then
		EXISTING=docker
		load_env_file "$DOCKER_DIR/agent.env"
	fi
}

# Values given on the command line win over the ones from a previous install.
load_env_file() {
	local line key value
	while IFS= read -r line; do
		[[ "$line" == *=* ]] || continue
		key="${line%%=*}"
		value="${line#*=}"
		[[ "$key" =~ ^(MONITORING_(URL|USER|PASSWORD|HOST|ENV)|POSTGRES_DSN|MYSQL_DSN|REDIS_ADDR|REDIS_PASSWORD|MONGODB_URI)$ ]] || continue
		if [[ "$value" == \"*\" ]]; then
			value="${value:1:${#value}-2}"
			value="${value//\\\"/\"}"
			value="${value//\\\\/\\}"
		fi
		[[ -n "${!key}" ]] || printf -v "$key" '%s' "$value"
	done <"$1"
}

print_report() {
	echo
	info "${BOLD}Hasil pemeriksaan server${RESET}"
	printf '  %-13s %s\n' "Hostname" "$(hostname)"
	printf '  %-13s %s\n' "OS" "$OS_PRETTY${PKG:+ ($PKG)}"
	printf '  %-13s %s\n' "Resource" "$CPU_COUNT vCPU, ${MEM_GB} GB RAM, disk / terpakai $ROOT_DISK"
	printf '  %-13s %s\n' "systemd" "$([[ $HAS_SYSTEMD -eq 1 ]] && echo ya || echo tidak)"
	if [[ $HAS_DOCKER -eq 1 ]]; then
		printf '  %-13s %s\n' "Docker" "ya ($DOCKER_VERSION), $CONTAINER_COUNT container berjalan${DOKPLOY:+, $DOKPLOY}"
	else
		printf '  %-13s %s\n' "Docker" "tidak"
	fi
	local db list=()
	for db in "${DB_MODULES[@]}"; do
		[[ -n "${DB_NATIVE[$db]:-}" ]] && list+=("$db (native)")
		[[ -n "${DB_CONTAINER[$db]:-}" ]] && list+=("$db (container)")
	done
	printf '  %-13s %s\n' "Database" "${list[*]:-tidak ada}"
	printf '  %-13s %s\n' "Agent lain" "${OTHER_AGENTS[*]:-tidak ada}"
	[[ -n "$EXISTING" ]] && printf '  %-13s %s\n' "Agent ini" "sudah terpasang (mode $EXISTING), akan di-update"
	local usage="${ROOT_DISK%\%}"
	if [[ "$usage" =~ ^[0-9]+$ ]] && ((usage >= 85)); then
		warn "Disk / sudah $ROOT_DISK terpakai."
	fi
	if ((${#OTHER_AGENTS[@]})); then
		warn "Ada agent monitoring lain. Tidak masalah, tapi bisa jadi data dobel jika dikirim ke stack yang sama."
	fi
	echo
}

# --- decisions ---------------------------------------------------------------

native_supported() { [[ $HAS_SYSTEMD -eq 1 && -n "$PKG" ]]; }

choose_mode() {
	local recommended reason has_native_db=0 db
	for db in "${DB_MODULES[@]}"; do
		[[ -n "${DB_NATIVE[$db]:-}" ]] && has_native_db=1
	done

	if [[ $has_native_db -eq 1 ]] && native_supported; then
		recommended=native reason="database berjalan langsung di mesin"
	elif [[ $HAS_DOCKER -eq 1 ]]; then
		recommended=docker reason="Docker tersedia; semua container ikut terpantau"
	elif native_supported; then
		recommended=native reason="Docker tidak ada"
	else
		die "Server ini tidak punya Docker, dan mode native butuh systemd + apt/dnf/yum."
	fi
	[[ -n "$EXISTING" && -z "$MODE" ]] && recommended="$EXISTING" reason="mengikuti instalasi sebelumnya"

	if [[ -z "$MODE" ]]; then
		info "Mode instalasi"
		echo "  ${BOLD}docker${RESET} : Alloy jalan sebagai container (butuh Docker)."
		echo "  ${BOLD}native${RESET} : Alloy jalan sebagai service systemd dari repo resmi Grafana."
		echo "  Rekomendasi: ${BOLD}$recommended${RESET} ($reason)"
		while :; do
			ask MODE "Pilih mode (docker/native)" "$recommended"
			[[ "$MODE" == docker || "$MODE" == native ]] && break
			warn "Jawab docker atau native."
		done
	fi
	[[ "$MODE" == docker && $HAS_DOCKER -eq 0 ]] && die "Mode docker dipilih, tapi Docker tidak tersedia."
	[[ "$MODE" == native ]] && ! native_supported && die "Mode native butuh systemd dan apt/dnf/yum."
	if [[ -n "$EXISTING" && "$EXISTING" != "$MODE" ]]; then
		warn "Instalasi lama (mode $EXISTING) akan dihapus dulu."
	fi
	return 0
}

valid_label() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

ask_connection() {
	info "Koneksi ke stack monitoring"
	while :; do
		ask MONITORING_URL "URL ingest (mis. https://ingest.example.com)" "$MONITORING_URL"
		MONITORING_URL="${MONITORING_URL%/}"
		[[ "$MONITORING_URL" =~ ^https?://[^/]+$ ]] && break
		interactive || die "URL ingest wajib diisi, format https://host (tanpa path)."
		warn "Format: https://host tanpa path."
	done
	ask MONITORING_USER "User ingest" "${MONITORING_USER:-agent}"
	ask_secret MONITORING_PASSWORD "Password ingest" "$MONITORING_PASSWORD"
	[[ -n "$MONITORING_PASSWORD" ]] || die "Password ingest wajib diisi."

	local code
	code="$(curl -sS -o /dev/null -w '%{http_code}' -u "$MONITORING_USER:$MONITORING_PASSWORD" \
		--max-time 10 "$MONITORING_URL/ping" 2>/dev/null || true)"
	case "$code" in
	200) ok "Stack monitoring bisa dihubungi dan kredensial benar." ;;
	401) die "Kredensial ingest ditolak (HTTP 401)." ;;
	*)
		warn "Tidak bisa memverifikasi $MONITORING_URL/ping (HTTP ${code:-gagal})."
		confirm "Tetap lanjutkan? Agent akan terus mencoba mengirim" n || exit 1
		;;
	esac

	echo
	info "Identitas server di dashboard"
	while :; do
		ask MONITORING_HOST "Nama server (huruf, angka, . _ -)" "${MONITORING_HOST:-$(hostname -s)}"
		valid_label "$MONITORING_HOST" && break
		interactive || die "Nama server tidak valid: $MONITORING_HOST"
		warn "Hanya huruf, angka, titik, garis bawah, dan strip."
	done
	while :; do
		ask MONITORING_ENV "Environment (production/staging/development)" "${MONITORING_ENV:-production}"
		valid_label "$MONITORING_ENV" && break
		interactive || die "Environment tidak valid: $MONITORING_ENV"
		warn "Hanya huruf, angka, titik, garis bawah, dan strip."
	done
}

choose_modules() {
	MODULES=(base)
	echo
	info "Modul yang dipasang"
	ok "base: metrik host (CPU, RAM, disk, network) + log journald"

	if [[ $HAS_DOCKER -eq 1 && "$DOCKER_MODULE" != no ]]; then
		if [[ "$MODE" == native ]]; then
			warn "Pada mode native, metrik container butuh akses ke socket Docker (setara root)."
		fi
		if confirm "Pantau container Docker (metrik + log semua container)?" y; then
			MODULES+=(docker)
		fi
	fi

	setup_postgres
	setup_mysql
	setup_redis
	setup_mongodb
	ok "Modul: ${MODULES[*]}"
}

db_wanted() {
	local db="$1" given="$2"
	if [[ -n "$given" ]]; then
		return 0
	fi
	if [[ -n "${DB_NATIVE[$db]:-}" ]]; then
		interactive && confirm "$db terdeteksi berjalan di mesin ini. Pantau?" y
	elif [[ -n "${DB_CONTAINER[$db]:-}" ]]; then
		interactive && confirm "$db terdeteksi di dalam container. Pantau lewat port yang terbuka ke host?" n
	else
		return 1
	fi
}

as_user() {
	local user="$1"
	shift
	(cd /tmp && if command -v runuser >/dev/null; then runuser -u "$user" -- "$@"; else su "$user" -s /bin/sh -c "$*"; fi)
}

setup_postgres() {
	db_wanted postgres "$POSTGRES_DSN" || return 0
	if [[ -z "$POSTGRES_DSN" && -n "${DB_NATIVE[postgres]:-}" ]] && id postgres >/dev/null 2>&1 &&
		confirm "Buat user database 'monitoring' (role pg_monitor) otomatis?" y; then
		local pw port
		pw="$(random_password)"
		port="$(as_user postgres psql -tAc 'SHOW port' 2>/dev/null || echo 5432)"
		if as_user postgres psql -v ON_ERROR_STOP=1 -q -d postgres <<SQL; then
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'monitoring') THEN
    CREATE ROLE monitoring LOGIN;
  END IF;
END
\$\$;
ALTER ROLE monitoring WITH LOGIN PASSWORD '$pw' CONNECTION LIMIT 5;
GRANT pg_monitor TO monitoring;
SQL
			POSTGRES_DSN="postgresql://monitoring:$pw@127.0.0.1:${port:-5432}/postgres?sslmode=disable"
			ok "User PostgreSQL 'monitoring' siap."
		else
			warn "Gagal membuat user PostgreSQL, isi DSN manual."
		fi
	fi
	if [[ -z "$POSTGRES_DSN" ]]; then
		ask_secret POSTGRES_DSN "DSN PostgreSQL (postgresql://user:pass@127.0.0.1:5432/postgres?sslmode=disable)" ""
	fi
	[[ -n "$POSTGRES_DSN" ]] && MODULES+=(postgres)
	return 0
}

setup_mysql() {
	db_wanted mysql "$MYSQL_DSN" || return 0
	if [[ -z "$MYSQL_DSN" && -n "${DB_NATIVE[mysql]:-}" ]] && command -v mysql >/dev/null &&
		confirm "Buat user database 'monitoring' (PROCESS, REPLICATION CLIENT, SELECT) otomatis?" y; then
		local pw port
		pw="$(random_password)"
		port="$(mysql --protocol=socket -uroot -Nse 'SELECT @@port' 2>/dev/null || echo 3306)"
		if mysql --protocol=socket -uroot <<SQL; then
CREATE USER IF NOT EXISTS 'monitoring'@'127.0.0.1' IDENTIFIED BY '$pw' WITH MAX_USER_CONNECTIONS 3;
ALTER USER 'monitoring'@'127.0.0.1' IDENTIFIED BY '$pw';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'monitoring'@'127.0.0.1';
SQL
			MYSQL_DSN="monitoring:$pw@(127.0.0.1:${port:-3306})/"
			ok "User MySQL 'monitoring' siap."
		else
			warn "Gagal login sebagai root lewat socket, isi DSN manual."
		fi
	fi
	if [[ -z "$MYSQL_DSN" ]]; then
		ask_secret MYSQL_DSN "DSN MySQL (user:pass@(127.0.0.1:3306)/)" ""
	fi
	[[ -n "$MYSQL_DSN" ]] && MODULES+=(mysql)
	return 0
}

setup_redis() {
	db_wanted redis "$REDIS_ADDR" || return 0
	if [[ -z "$REDIS_PASSWORD" ]]; then
		local conf
		for conf in /etc/redis/redis.conf /etc/redis.conf /etc/redis/*.conf; do
			[[ -r "$conf" ]] || continue
			REDIS_PASSWORD="$(awk '$1 == "requirepass" {gsub(/^"|"$/, "", $2); print $2; exit}' "$conf")"
			[[ -n "$REDIS_PASSWORD" ]] && ok "Password Redis diambil dari $conf" && break
		done
	fi
	ask REDIS_ADDR "Alamat Redis" "${REDIS_ADDR:-127.0.0.1:6379}"
	[[ -n "$REDIS_PASSWORD" ]] || ask_secret REDIS_PASSWORD "Password Redis (kosongkan jika tidak ada)" ""
	MODULES+=(redis)
}

setup_mongodb() {
	db_wanted mongodb "$MONGODB_URI" || return 0
	if [[ -z "$MONGODB_URI" ]]; then
		echo "  ${DIM}User butuh role clusterMonitor. Tanpa auth: mongodb://127.0.0.1:27017${RESET}"
		ask_secret MONGODB_URI "URI MongoDB (mongodb://user:pass@127.0.0.1:27017/admin)" ""
	fi
	[[ -n "$MONGODB_URI" ]] && MODULES+=(mongodb)
	return 0
}

# --- install -----------------------------------------------------------------

fetch_modules() {
	local dest="$1" module src_dir=""
	if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
		src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/alloy"
	fi
	local source_url="${MONITORING_SOURCE_URL:-$MONITORING_URL/agent}"
	install -d -m 0755 "$dest"
	rm -f "$dest"/*.alloy
	for module in "${MODULES[@]}"; do
		if [[ -n "$src_dir" && -f "$src_dir/$module.alloy" ]]; then
			install -m 0644 "$src_dir/$module.alloy" "$dest/$module.alloy"
		else
			curl -fsSL --max-time 30 "$source_url/alloy/$module.alloy" -o "$dest/$module.alloy" ||
				die "Gagal mengunduh modul $module dari $source_url/alloy/$module.alloy"
		fi
	done
	ok "Modul ditulis ke $dest"
}

# docker --env-file takes values literally; systemd needs quoting.
write_env_file() {
	local path="$1" style="$2" key value
	local keys=(MONITORING_URL MONITORING_USER MONITORING_PASSWORD MONITORING_HOST MONITORING_ENV
		POSTGRES_DSN MYSQL_DSN REDIS_ADDR REDIS_PASSWORD MONGODB_URI)
	(
		umask 077
		: >"$path"
		for key in "${keys[@]}"; do
			value="${!key}"
			[[ -z "$value" && "$key" != MONITORING_* ]] && continue
			[[ "$value" == *$'\n'* ]] && die "$key tidak boleh berisi baris baru."
			if [[ "$style" == systemd ]]; then
				value="${value//\\/\\\\}"
				value="${value//\"/\\\"}"
				printf '%s="%s"\n' "$key" "$value"
			else
				printf '%s=%s\n' "$key" "$value"
			fi
		done >>"$path"
		if [[ "$style" == docker ]]; then
			printf '%s\n' HOST_PROC=/host/proc HOST_SYS=/host/sys HOST_ROOT=/host/root >>"$path"
		fi
	)
}

install_docker() {
	info "Memasang agent (mode docker, Alloy $ALLOY_VERSION)"
	install -d -m 0700 "$DOCKER_DIR"
	fetch_modules "$DOCKER_DIR/alloy"
	write_env_file "$DOCKER_DIR/agent.env" docker

	docker pull -q "grafana/alloy:$ALLOY_VERSION" >/dev/null || die "Gagal menarik image grafana/alloy:$ALLOY_VERSION."
	docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

	local mounts=(
		-v /:/host/root:ro,rslave
		-v /proc:/host/proc:ro
		-v /sys:/host/sys:ro
		-v "$DOCKER_DIR/alloy:/etc/alloy/monitoring:ro"
		-v monitoring-agent-data:/var/lib/alloy/data
	)
	local path
	# Bind-mounting a missing path makes Docker create it as an empty
	# directory on the host, which breaks /etc/machine-id in particular.
	for path in /var/run/docker.sock /var/lib/docker /dev/disk /var/log/journal /run/log/journal /etc/machine-id; do
		[[ -e "$path" ]] && mounts+=(-v "$path:$path:ro")
	done

	docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
		--network host --pid host --cgroupns host --privileged \
		--env-file "$DOCKER_DIR/agent.env" \
		--label com.monitoring-stack.agent=true \
		"${mounts[@]}" \
		"grafana/alloy:$ALLOY_VERSION" \
		run --server.http.listen-addr="$ALLOY_HTTP" --storage.path=/var/lib/alloy/data /etc/alloy/monitoring \
		>/dev/null
	ok "Container $CONTAINER_NAME berjalan."
}

install_alloy_package() {
	local version="${ALLOY_VERSION#v}"
	if [[ "$PKG" == apt ]]; then
		export DEBIAN_FRONTEND=noninteractive
		if ! command -v gpg >/dev/null; then
			apt-get update -qq </dev/null
			apt-get install -y -qq gnupg </dev/null >/dev/null
		fi
		install -d -m 0755 /etc/apt/keyrings
		curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
		echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
			>/etc/apt/sources.list.d/grafana.list
		apt-get update -qq </dev/null
		apt-get install -y -qq --allow-downgrades "alloy=$version" </dev/null >/dev/null ||
			{ warn "Versi $version tidak ada di repo, memasang versi terbaru."; apt-get install -y -qq alloy </dev/null >/dev/null; }
	else
		cat >/etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
EOF
		"$PKG" install -y -q "alloy-$version" </dev/null >/dev/null ||
			{ warn "Versi $version tidak ada di repo, memasang versi terbaru."; "$PKG" install -y -q alloy </dev/null >/dev/null; }
	fi
	ok "Paket alloy terpasang ($(alloy --version 2>/dev/null | head -1 || echo "?"))."
}

install_native() {
	info "Memasang agent (mode native)"
	install_alloy_package

	fetch_modules "$NATIVE_DIR"
	write_env_file "$NATIVE_ENV" systemd

	local groups=() group
	for group in adm systemd-journal; do
		getent group "$group" >/dev/null && groups+=("$group")
	done
	[[ " ${MODULES[*]} " == *" docker "* ]] && getent group docker >/dev/null && groups+=(docker)

	install -d -m 0755 "$(dirname "$NATIVE_DROPIN")"
	cat >"$NATIVE_DROPIN" <<EOF
[Service]
EnvironmentFile=$NATIVE_ENV
SupplementaryGroups=${groups[*]}
ExecStart=
ExecStart=/usr/bin/alloy run --server.http.listen-addr=$ALLOY_HTTP --storage.path=/var/lib/alloy/data $NATIVE_DIR
EOF
	systemctl daemon-reload
	systemctl enable alloy >/dev/null 2>&1
	systemctl restart alloy
	ok "Service alloy berjalan."
}

verify() {
	info "Memeriksa agent"
	local i
	for i in $(seq 1 30); do
		curl -fsS "http://$ALLOY_HTTP/-/ready" >/dev/null 2>&1 && break
		sleep 1
	done
	if ! curl -fsS "http://$ALLOY_HTTP/-/ready" >/dev/null 2>&1; then
		warn "Agent belum siap setelah 30 detik."
		print_logs_hint
		return 1
	fi
	ok "Agent siap."

	sleep 5
	local unhealthy
	unhealthy="$(curl -fsS "http://$ALLOY_HTTP/metrics" 2>/dev/null |
		awk '/^alloy_component_controller_running_components\{.*health_type="unhealthy"/ {sum += $2} END {print sum + 0}')"
	if [[ "${unhealthy:-0}" != 0 ]]; then
		warn "$unhealthy komponen tidak sehat. Biasanya kredensial database salah atau path log tidak ada."
		print_logs_hint
	else
		ok "Semua komponen sehat."
	fi
}

print_logs_hint() {
	if [[ "$MODE" == docker ]]; then
		echo "  Log agent: docker logs --tail 50 $CONTAINER_NAME"
	else
		echo "  Log agent: journalctl -u alloy -n 50 --no-pager"
	fi
}

# --- uninstall ---------------------------------------------------------------

remove_docker() {
	docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
	docker volume rm monitoring-agent-data >/dev/null 2>&1 || true
	rm -rf "$DOCKER_DIR"
	ok "Agent mode docker dihapus."
}

remove_native() {
	systemctl disable --now alloy >/dev/null 2>&1 || true
	rm -f "$NATIVE_DROPIN" "$NATIVE_ENV"
	rm -rf "$NATIVE_DIR"
	systemctl daemon-reload
	ok "Konfigurasi agent native dihapus, service alloy dimatikan."
}

uninstall() {
	detect_system
	detect_existing
	case "$EXISTING" in
	docker) remove_docker ;;
	native)
		remove_native
		if confirm "Hapus juga paket alloy?" n; then
			case "$PKG" in
			apt) apt-get remove -y -qq alloy </dev/null >/dev/null ;;
			dnf | yum) "$PKG" remove -y -q alloy </dev/null >/dev/null ;;
			esac
			ok "Paket alloy dihapus."
		fi
		;;
	*) warn "Agent tidak ditemukan di server ini." ;;
	esac
	echo "  User database 'monitoring' (jika pernah dibuat) tidak dihapus."
}

# --- main --------------------------------------------------------------------

main() {
	parse_args "$@"
	[[ $EUID -eq 0 ]] || die "Jalankan sebagai root, mis. dengan sudo."
	command -v curl >/dev/null || die "curl dibutuhkan."

	if [[ $UNINSTALL -eq 1 ]]; then
		uninstall
		return
	fi

	echo "${BOLD}Monitoring agent installer${RESET} (Grafana Alloy $ALLOY_VERSION)"
	detect_system
	detect_databases
	detect_existing
	print_report

	choose_mode
	echo
	ask_connection
	choose_modules

	echo
	info "Ringkasan"
	printf '  %-12s %s\n' Mode "$MODE" Tujuan "$MONITORING_URL" Nama "$MONITORING_HOST" Env "$MONITORING_ENV" Modul "${MODULES[*]}"
	confirm "Pasang sekarang?" y || exit 1
	echo

	if [[ -n "$EXISTING" && "$EXISTING" != "$MODE" ]]; then
		"remove_$EXISTING"
	fi
	"install_$MODE"
	verify || true

	echo
	ok "${BOLD}Selesai.${RESET} Server '$MONITORING_HOST' akan muncul di dashboard Fleet Overview dalam ±1 menit."
	echo "  Jalankan ulang installer ini untuk mengubah konfigurasi, atau dengan --uninstall untuk menghapus."
}

main "$@"
