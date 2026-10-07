#!/usr/bin/env bash
# Installs the PLG Stack agent (Grafana Alloy) on a server to be monitored.
#
#   curl -fsSL https://INGEST_DOMAIN/agent/install.sh | sudo bash
#   curl -fsSL https://INGEST_DOMAIN/agent/install.sh | sudo bash -s -- \
#     --url https://INGEST_DOMAIN --name db-01 --token TOKEN --env production --yes
#   sudo bash install.sh --uninstall
#
# Run `install.sh --help` for every option.
set -euo pipefail

ALLOY_VERSION="${ALLOY_VERSION:-v1.20.1}"
CONTAINER_NAME="plg-agent"
DATA_VOLUME="plg-agent-data"
CONF_DIR="${PLG_CONF_DIR:-/etc/plg-agent}"
ENV_FILE="$CONF_DIR/agent.env"
MODULE_DIR="$CONF_DIR/modules"
LOGS_D="$CONF_DIR/logs.d"
METRICS_D="$CONF_DIR/metrics.d"
TEXTFILE_DIR="/var/lib/plg-agent/textfile"
NATIVE_DROPIN="/etc/systemd/system/alloy.service.d/plg.conf"
ALLOY_HTTP="127.0.0.1:12345"
NEVER_MATCH='[^\s\S]'

CORE_KEYS=(AGENT_MODE MONITORING_URL MONITORING_USER MONITORING_PASSWORD MONITORING_HOST MONITORING_ENV
	MONITORING_MACHINE_ID MONITORING_MODULES AGENT_MEMORY_LIMIT AGENT_LOG_MAX_SIZE AGENT_OFFLINE_BUFFER
	GOMEMLIMIT LOG_DROP_REGEX LOG_REDACT_REGEX LOG_MULTILINE_FIRSTLINE LOG_EXCLUDE_CONTAINERS
	PROCESS_NAMES APP_METRICS_SAMPLE_LIMIT)
for key in "${CORE_KEYS[@]}"; do
	printf -v "$key" '%s' "${!key:-}"
done

MODE=""
MODULES_ARG=""
PRIVILEGED_ARG=""
JOURNAL_ARG=""
REDACT_ARG=""
SOURCE_URL="${MONITORING_SOURCE_URL:-}"
ASSUME_YES=0
UNINSTALL=0
PRIVILEGED=0
EXISTING=""

declare -a CUSTOM_LOG_FILES=() SELECTED=() MODULE_ORDER=() FILE_TARGETS=()
declare -A SET_VARS=() FROM_PREVIOUS=() DET=() PRESELECT=()
declare -A M_TITLE=() M_DESC=() M_DETECT=() M_HOOK=() M_PRIV=() M_WHY=() M_REQ=() M_MODES=() M_VARS=()
declare -A V_FLAGS=() V_PROMPT=() V_DEFAULT=()

if [[ -t 1 ]]; then
	BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' BLUE=$'\e[34m' RESET=$'\e[0m'
else
	BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" RESET=""
fi

info() { printf '%s\n' "${BLUE}==>${RESET} $*"; }
ok() { printf '%s\n' "${GREEN}  ✓${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}  !${RESET} $*" >&2; }
note() { printf '%s\n' "  ${DIM}$*${RESET}"; }
die() {
	printf '%s\n' "${RED}ERROR:${RESET} $*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Install agent PLG Stack (Grafana Alloy) di server ini.

Tanpa opsi, installer berjalan interaktif: memeriksa server, mendeteksi
aplikasi dan database, lalu menanyakan pilihan beserta penjelasannya.

Koneksi:
  --url URL               Alamat ingest PLG Stack, mis. https://ingest.example.com
  --name NAME             Nama server = nama token (dari scripts/agent-token.sh)
  --token TOKEN           Token server ini
  --env ENV               Label environment: production, staging, development, ...

Mode dan modul:
  --mode MODE             docker | native (default: rekomendasi installer)
  --modules A,B,...       Modul yang dipasang (lihat agent/modules/catalog.conf)
  --set KEY=VALUE         Isi variabel modul, mis. --set POSTGRES_DSN=postgresql://...
  --postgres-dsn, --mysql-dsn, --redis-addr, --redis-password, --mongodb-uri
                          Singkatan --set untuk modul database
  --log-file GLOB=SERVICE File log tambahan untuk modul files (boleh berulang)
  --process-names A,B     Nama proses untuk modul process
  --privileged yes|no     Izinkan modul yang butuh akses privileged

Pengaturan agent:
  --memory SIZE           Batas memori agent, mis. 512M (0 = tanpa batas)
  --offline-buffer DUR    Lama metrik disimpan saat stack tak terjangkau, mis. 24h
  --persistent-journal yes|no
                          Simpan journald di disk agar log sebelum mati/reboot tetap ada
  --log-max-size SIZE     Rotasi log container agent (mode docker), default 10m
  --no-redact             Jangan sensor password/token di log
  --log-drop REGEX        Buang baris log yang cocok dengan REGEX
  --multiline REGEX       Awal entri log multi-baris (default: baris tanpa spasi di depan)
  --exclude-containers REGEX
                          Jangan kirim log container yang namanya cocok

Lainnya:
  --source URL            Lokasi modul (default: <url>/agent)
  --yes, -y               Non-interaktif: pakai opsi, nilai lama, dan default
  --uninstall             Hapus agent dari server ini
  --help, -h              Tampilkan bantuan ini
EOF
}

parse_args() {
	while (($#)); do
		case "$1" in
		--url) MONITORING_URL="${2:?--url butuh nilai}" && shift ;;
		--name) MONITORING_HOST="${2:?--name butuh nilai}" && shift ;;
		--token) MONITORING_PASSWORD="${2:?--token butuh nilai}" && shift ;;
		--env) MONITORING_ENV="${2:?--env butuh nilai}" && shift ;;
		--mode) MODE="${2:?--mode butuh nilai}" && shift ;;
		--modules) MODULES_ARG="${2:?--modules butuh nilai}" && shift ;;
		--set)
			[[ "${2:-}" == *=* ]] || die "--set butuh KEY=VALUE"
			SET_VARS["${2%%=*}"]="${2#*=}"
			shift
			;;
		--postgres-dsn) SET_VARS[POSTGRES_DSN]="${2:?--postgres-dsn butuh nilai}" && shift ;;
		--mysql-dsn) SET_VARS[MYSQL_DSN]="${2:?--mysql-dsn butuh nilai}" && shift ;;
		--redis-addr) SET_VARS[REDIS_ADDR]="${2:?--redis-addr butuh nilai}" && shift ;;
		--redis-password) SET_VARS[REDIS_PASSWORD]="${2:?--redis-password butuh nilai}" && shift ;;
		--mongodb-uri) SET_VARS[MONGODB_URI]="${2:?--mongodb-uri butuh nilai}" && shift ;;
		--log-file)
			[[ "${2:-}" == *=* ]] || die "--log-file butuh GLOB=SERVICE"
			CUSTOM_LOG_FILES+=("$2")
			shift
			;;
		--process-names) PROCESS_NAMES="${2:?--process-names butuh nilai}" && shift ;;
		--privileged) PRIVILEGED_ARG="${2:?--privileged butuh yes atau no}" && shift ;;
		--memory) AGENT_MEMORY_LIMIT="${2:?--memory butuh nilai}" && shift ;;
		--offline-buffer) AGENT_OFFLINE_BUFFER="${2:?--offline-buffer butuh nilai}" && shift ;;
		--persistent-journal) JOURNAL_ARG="${2:?--persistent-journal butuh yes atau no}" && shift ;;
		--log-max-size) AGENT_LOG_MAX_SIZE="${2:?--log-max-size butuh nilai}" && shift ;;
		--no-redact) REDACT_ARG=no ;;
		--log-drop) LOG_DROP_REGEX="${2:?--log-drop butuh nilai}" && shift ;;
		--multiline) LOG_MULTILINE_FIRSTLINE="${2:?--multiline butuh nilai}" && shift ;;
		--exclude-containers) LOG_EXCLUDE_CONTAINERS="${2:?--exclude-containers butuh nilai}" && shift ;;
		--source) SOURCE_URL="${2:?--source butuh nilai}" && shift ;;
		--yes | -y) ASSUME_YES=1 ;;
		--uninstall) UNINSTALL=1 ;;
		--help | -h) usage && exit 0 ;;
		*) die "Opsi tidak dikenal: $1 (lihat --help)" ;;
		esac
		shift
	done
	[[ -z "$MODE" || "$MODE" == docker || "$MODE" == native ]] || die "--mode harus docker atau native"
	[[ -z "$PRIVILEGED_ARG" || "$PRIVILEGED_ARG" == yes || "$PRIVILEGED_ARG" == no ]] ||
		die "--privileged harus yes atau no"
	[[ -z "$JOURNAL_ARG" || "$JOURNAL_ARG" == yes || "$JOURNAL_ARG" == no ]] ||
		die "--persistent-journal harus yes atau no"
	return 0
}

# --- prompts -----------------------------------------------------------------
# `curl | bash` gives the script on stdin, so answers are read from the terminal.

interactive() { [[ $ASSUME_YES -eq 0 && -r /dev/tty ]]; }

# Locals use a _ask_ prefix: printf -v writes to the innermost variable with
# that name, so a local named like the caller's variable would swallow it.
ask() {
	local _ask_var="$1" _ask_prompt="$2" _ask_default="${3:-}" _ask_reply
	if ! interactive; then
		printf -v "$_ask_var" '%s' "$_ask_default"
		return
	fi
	if [[ -n "$_ask_default" ]]; then
		read -r -p "  $_ask_prompt ${DIM}[$_ask_default]${RESET}: " _ask_reply </dev/tty
	else
		read -r -p "  $_ask_prompt: " _ask_reply </dev/tty
	fi
	printf -v "$_ask_var" '%s' "${_ask_reply:-$_ask_default}"
}

ask_secret() {
	local _ask_var="$1" _ask_prompt="$2" _ask_default="${3:-}" _ask_reply _ask_hint=""
	if ! interactive; then
		printf -v "$_ask_var" '%s' "$_ask_default"
		return
	fi
	[[ -n "$_ask_default" ]] && _ask_hint=" ${DIM}[Enter = pakai yang lama]${RESET}"
	read -r -s -p "  $_ask_prompt$_ask_hint: " _ask_reply </dev/tty
	echo >/dev/tty
	printf -v "$_ask_var" '%s' "${_ask_reply:-$_ask_default}"
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

trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	printf '%s' "${s%"${s##*[![:space:]]}"}"
}

valid_label() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# --- env file ----------------------------------------------------------------

# Loads only the given keys, and only when they are still empty, so values
# from flags and the environment win over the previous install.
load_env_file() {
	local file="$1" line key value
	shift
	local -A wanted=()
	for key in "$@"; do
		wanted[$key]=1
	done
	[[ -r "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == *=* ]] || continue
		key="${line%%=*}"
		value="${line#*=}"
		[[ -n "${wanted[$key]:-}" ]] || continue
		if [[ "$value" == \"*\" ]]; then
			value="${value:1:${#value}-2}"
			value="${value//\\\"/\"}"
			value="${value//\\\\/\\}"
		fi
		if [[ -z "${!key:-}" ]]; then
			printf -v "$key" '%s' "$value"
			FROM_PREVIOUS[$key]=1
		fi
	done <"$file"
}

# docker --env-file takes values literally; systemd needs quoting.
write_env_file() {
	local path="$1" style="$2" key value
	shift 2
	(
		umask 077
		: >"$path"
		for key in "$@"; do
			value="${!key:-}"
			[[ -z "$value" ]] && continue
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

# --- catalog -----------------------------------------------------------------

parse_catalog() {
	local file="$1" line mod="" key value name flags prompt default
	MODULE_ORDER=()
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
		if [[ "$line" =~ ^\[([a-z0-9-]+)\][[:space:]]*$ ]]; then
			mod="${BASH_REMATCH[1]}"
			MODULE_ORDER+=("$mod")
			M_VARS[$mod]=""
			continue
		fi
		[[ -n "$mod" && "$line" == *=* ]] || continue
		key="$(trim "${line%%=*}")"
		value="$(trim "${line#*=}")"
		case "$key" in
		title) M_TITLE[$mod]="$value" ;;
		description) M_DESC[$mod]="$value" ;;
		detect) M_DETECT[$mod]="$value" ;;
		hook) M_HOOK[$mod]="$value" ;;
		requires) M_REQ[$mod]="$value" ;;
		modes) M_MODES[$mod]="$value" ;;
		privileged) M_PRIV[$mod]="$value" ;;
		why_privileged) M_WHY[$mod]="$value" ;;
		var.*)
			name="${key#var.}"
			[[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "Nama variabel tidak valid di katalog: $name"
			IFS='|' read -r flags prompt default <<<"$value"
			V_FLAGS[$name]="$(trim "$flags")"
			V_PROMPT[$name]="$(trim "$prompt")"
			V_DEFAULT[$name]="$(trim "${default:-}")"
			M_VARS[$mod]+=" $name"
			;;
		esac
	done <"$file"
	((${#MODULE_ORDER[@]})) || die "Katalog modul kosong atau tidak valid."
}

script_dir() {
	if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
		cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
	fi
}

module_source() { printf '%s' "${SOURCE_URL:-$MONITORING_URL/agent}"; }

fetch_file() {
	local name="$1" dest="$2" dir
	dir="$(script_dir)"
	if [[ -n "$dir" && -f "$dir/modules/$name" ]]; then
		install -m 0644 "$dir/modules/$name" "$dest"
	else
		curl -fsSL --max-time 30 "$(module_source)/modules/$name" -o "$dest" ||
			die "Gagal mengunduh $(module_source)/modules/$name"
	fi
}

load_catalog() {
	local tmp
	tmp="$(mktemp)"
	fetch_file catalog.conf "$tmp"
	parse_catalog "$tmp"
	rm -f "$tmp"
}

all_module_vars() {
	local mod var
	for mod in "${MODULE_ORDER[@]}"; do
		for var in ${M_VARS[$mod]}; do
			printf '%s\n' "$var"
		done
	done
}

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
	MEM_MB="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo)"
	ROOT_DISK="$(df -P / | awk 'NR == 2 {print $5}')"

	HAS_DOCKER=0 DOCKER_VERSION="" CONTAINER_COUNT=0
	if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
		HAS_DOCKER=1
		DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
		CONTAINER_COUNT="$(docker ps -q | wc -l)"
	fi

	JOURNAL_PERSISTENT=0
	if [[ -d /var/log/journal ]] && ! journald_storage_volatile; then
		JOURNAL_PERSISTENT=1
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

journald_storage_volatile() {
	grep -hsE '^[[:space:]]*Storage[[:space:]]*=[[:space:]]*(volatile|none)' \
		/etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf >/dev/null
}

# A containerized process has its own PID namespace; systemd services share
# the host's. The cgroup path is only a fallback: when the whole server is
# itself a container, every cgroup path mentions docker.
in_container() {
	local own theirs
	own="$(readlink /proc/self/ns/pid 2>/dev/null || true)"
	theirs="$(readlink "/proc/$1/ns/pid" 2>/dev/null || true)"
	if [[ -n "$own" && -n "$theirs" ]]; then
		[[ "$theirs" != "$own" ]]
		return
	fi
	grep -qE 'docker|containerd|kubepods|libpod' "/proc/$1/cgroup" 2>/dev/null
}

# Sets DET and PRESELECT for one module; returns 1 when nothing was found.
detect_module() {
	local mod="$1" spec="${M_DETECT[$1]:-manual}" pid native=0 container=0
	case "$spec" in
	always)
		DET[$mod]="wajib"
		PRESELECT[$mod]=1
		;;
	docker)
		[[ $HAS_DOCKER -eq 1 ]] || return 1
		DET[$mod]="Docker terdeteksi"
		PRESELECT[$mod]=1
		;;
	process\ *)
		for pid in $(pgrep -x "${spec#process }" 2>/dev/null || true); do
			if in_container "$pid"; then
				container=1
			else
				native=1
			fi
		done
		if ((native)); then
			DET[$mod]="berjalan di mesin"
			PRESELECT[$mod]=1
		elif ((container)); then
			DET[$mod]="di dalam container"
		else
			return 1
		fi
		;;
	hook)
		declare -F "detect_${M_HOOK[$mod]:-}" >/dev/null || return 1
		"detect_${M_HOOK[$mod]}" "$mod"
		;;
	*) return 1 ;;
	esac
}

module_available() {
	[[ "${M_REQ[$1]:-}" != docker || $HAS_DOCKER -eq 1 ]] || return 1
	[[ -z "$MODE" || -z "${M_MODES[$1]:-}" || ",${M_MODES[$1]// /}," == *",$MODE,"* ]]
}

detect_docker_apps() {
	[[ $HAS_DOCKER -eq 1 ]] || return 1
	local count
	count="$(docker ps -q --filter label=plg.scrape=true | wc -l)"
	((count > 0)) || return 1
	DET[$1]="$count container berlabel plg.scrape"
	PRESELECT[$1]=1
}

detect_app_metrics() {
	compgen -G "$METRICS_D/*.yaml" >/dev/null || return 1
	DET[$1]="ada target di $METRICS_D"
	PRESELECT[$1]=1
}

add_file_target() {
	local glob="$1" service="$2" entry
	compgen -G "$glob" >/dev/null || return 0
	for entry in "${FILE_TARGETS[@]}"; do
		[[ "$entry" == "$glob=$service" ]] && return 0
	done
	FILE_TARGETS+=("$glob=$service")
}

detect_files() {
	FILE_TARGETS=()
	add_file_target "/var/log/nginx/*.log" nginx
	add_file_target "/var/log/apache2/*.log" apache
	add_file_target "/var/log/httpd/*log" apache
	add_file_target "/var/log/php*-fpm.log" php-fpm
	add_file_target "/var/log/php-fpm/*.log" php-fpm
	add_file_target "/var/log/supervisor/*.log" supervisor
	add_file_target "/var/log/tomcat*/catalina.out" tomcat
	add_file_target "/var/log/tomcat*/*.log" tomcat
	add_file_target "/opt/tomcat*/logs/catalina.out" tomcat
	add_file_target "/opt/tomcat*/logs/*.log" tomcat
	add_file_target "/root/.pm2/logs/*.log" pm2
	add_file_target "/home/*/.pm2/logs/*.log" pm2

	local dir
	while IFS= read -r dir; do
		add_file_target "$dir/*.log" "laravel-$(basename "${dir%/storage/logs}")"
	done < <(timeout 15 find /var/www /srv /opt /home -maxdepth 5 -type d -path '*/storage/logs' 2>/dev/null | head -20 || true)

	((${#FILE_TARGETS[@]})) || return 1
	local services=() entry
	for entry in "${FILE_TARGETS[@]}"; do
		[[ " ${services[*]} " == *" ${entry##*=} "* ]] || services+=("${entry##*=}")
	done
	DET[$1]="terdeteksi: ${services[*]}"
	PRESELECT[$1]=1
}

KNOWN_PROCESSES='^(java|node|nodejs|bun|deno|python[0-9.]*|gunicorn|uwsgi|uvicorn|php-fpm[0-9.]*|php[0-9.]*|nginx|httpd|apache2|caddy|traefik|haproxy|puma|ruby|dotnet|beam\.smp|postgres|mysqld|mariadbd|redis-server|mongod|memcached|dockerd|containerd)$'

detect_process() {
	local names
	names="$(ps -eo comm= 2>/dev/null | sort -u | grep -E "$KNOWN_PROCESSES" | paste -sd, - || true)"
	[[ -n "$names" ]] || return 1
	DETECTED_PROCESSES="$names"
	DET[$1]="terdeteksi: ${names//,/, }"
	PRESELECT[$1]=1
}

detect_modules() {
	local mod
	for mod in "${MODULE_ORDER[@]}"; do
		module_available "$mod" || continue
		detect_module "$mod" || true
	done
}

detect_existing() {
	EXISTING=""
	load_env_file "$ENV_FILE" "${CORE_KEYS[@]}"
	if [[ -f "$ENV_FILE" ]]; then
		EXISTING="${AGENT_MODE:-}"
	fi
}

print_report() {
	echo
	info "${BOLD}Hasil pemeriksaan server${RESET}"
	printf '  %-13s %s\n' "Hostname" "$(hostname)"
	printf '  %-13s %s\n' "OS" "$OS_PRETTY${PKG:+ ($PKG)}"
	printf '  %-13s %s\n' "Resource" "$CPU_COUNT vCPU, $((MEM_MB / 1024)) GB RAM, disk / terpakai $ROOT_DISK"
	printf '  %-13s %s\n' "systemd" "$([[ $HAS_SYSTEMD -eq 1 ]] && echo ya || echo tidak)"
	if [[ $HAS_DOCKER -eq 1 ]]; then
		printf '  %-13s %s\n' "Docker" "ya ($DOCKER_VERSION), $CONTAINER_COUNT container berjalan"
	else
		printf '  %-13s %s\n' "Docker" "tidak"
	fi
	if [[ $HAS_SYSTEMD -eq 1 ]]; then
		printf '  %-13s %s\n' "Journald" "$([[ $JOURNAL_PERSISTENT -eq 1 ]] && echo "disimpan di disk" || echo "hanya di RAM (hilang saat reboot)")"
	fi
	printf '  %-13s %s\n' "Agent lain" "${OTHER_AGENTS[*]:-tidak ada}"
	[[ -n "$EXISTING" ]] && printf '  %-13s %s\n' "Agent ini" "sudah terpasang (mode $EXISTING), akan di-update"
	local usage="${ROOT_DISK%\%}"
	if [[ "$usage" =~ ^[0-9]+$ ]] && ((usage >= 85)); then
		warn "Disk / sudah $ROOT_DISK terpakai."
	fi
	if ((${#OTHER_AGENTS[@]})); then
		warn "Ada agent monitoring lain. Tidak masalah, tapi data bisa dobel jika dikirim ke stack yang sama."
	fi
	echo
}

# --- connection --------------------------------------------------------------

ask_connection() {
	info "Koneksi ke PLG Stack"
	while :; do
		ask MONITORING_URL "URL ingest (mis. https://ingest.example.com)" "$MONITORING_URL"
		MONITORING_URL="${MONITORING_URL%/}"
		[[ "$MONITORING_URL" =~ ^https?://[^/]+$ ]] && break
		interactive || die "URL ingest wajib diisi, format https://host (tanpa path)."
		warn "Format: https://host tanpa path."
	done
	note "Nama server tampil di dashboard dan harus sama dengan nama tokennya."
	while :; do
		ask MONITORING_HOST "Nama server" "${MONITORING_HOST:-$(hostname -s)}"
		valid_label "$MONITORING_HOST" && break
		interactive || die "Nama server tidak valid: $MONITORING_HOST"
		warn "Hanya huruf, angka, titik, garis bawah, dan strip."
	done
	MONITORING_USER="$MONITORING_HOST"
	ask_secret MONITORING_PASSWORD "Token server ini" "$MONITORING_PASSWORD"
	[[ -n "$MONITORING_PASSWORD" ]] || die "Token wajib diisi. Buat dengan scripts/agent-token.sh add $MONITORING_HOST di server stack."

	local code
	code="$(curl -sS -o /dev/null -w '%{http_code}' -u "$MONITORING_USER:$MONITORING_PASSWORD" \
		--max-time 10 "$MONITORING_URL/ping" 2>/dev/null || true)"
	case "$code" in
	200) ok "PLG Stack bisa dihubungi dan token valid." ;;
	401) die "Token ditolak (HTTP 401). Pastikan nama server sama dengan nama token." ;;
	*)
		warn "Tidak bisa memverifikasi $MONITORING_URL/ping (HTTP ${code:-gagal})."
		confirm "Tetap lanjutkan? Agent akan terus mencoba mengirim" n || exit 1
		;;
	esac

	while :; do
		ask MONITORING_ENV "Environment (production/staging/development)" "${MONITORING_ENV:-production}"
		valid_label "$MONITORING_ENV" && break
		interactive || die "Environment tidak valid: $MONITORING_ENV"
		warn "Hanya huruf, angka, titik, garis bawah, dan strip."
	done
	MONITORING_MACHINE_ID="$(head -c 12 /etc/machine-id 2>/dev/null || hostname)"
}

# --- mode --------------------------------------------------------------------

native_supported() { [[ $HAS_SYSTEMD -eq 1 && -n "$PKG" ]]; }

choose_mode() {
	local recommended reason has_native_db=0 mod
	for mod in "${MODULE_ORDER[@]}"; do
		[[ "${M_DETECT[$mod]:-}" == process\ * && "${DET[$mod]:-}" == "berjalan di mesin" ]] && has_native_db=1
	done

	if [[ $has_native_db -eq 1 ]] && native_supported; then
		recommended=native reason="ada database yang berjalan langsung di mesin"
	elif [[ $HAS_DOCKER -eq 1 ]]; then
		recommended=docker reason="Docker tersedia"
	elif native_supported; then
		recommended=native reason="Docker tidak ada"
	else
		die "Server ini tidak punya Docker, dan mode native butuh systemd + apt/dnf/yum."
	fi
	[[ -n "$EXISTING" && -z "$MODE" ]] && recommended="$EXISTING" reason="mengikuti instalasi sebelumnya"

	if [[ -z "$MODE" ]]; then
		echo
		info "Mode instalasi"
		echo "  ${BOLD}docker${RESET} : Alloy jalan sebagai container. Tidak memasang paket di sistem."
		echo "  ${BOLD}native${RESET} : Alloy jalan sebagai service systemd dari repo resmi Grafana."
		echo "           Cocok untuk server tanpa Docker, mis. server database."
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
	AGENT_MODE="$MODE"
}

# --- modules -----------------------------------------------------------------

available_modules() {
	local mod
	for mod in "${MODULE_ORDER[@]}"; do
		module_available "$mod" && printf '%s\n' "$mod"
	done
}

default_selection() {
	local mod list=() var
	if [[ -n "$MODULES_ARG" ]]; then
		printf '%s' "$MODULES_ARG"
		return
	fi
	if [[ -n "$MONITORING_MODULES" ]]; then
		# Modules from the previous install that are no longer available
		# (e.g. Docker was removed) are dropped instead of failing.
		for mod in ${MONITORING_MODULES//,/ }; do
			module_available "$mod" 2>/dev/null && [[ -n "${M_TITLE[$mod]:-}" ]] && list+=("$mod")
		done
		local IFS=,
		printf '%s' "${list[*]}"
		return
	fi
	for mod in $(available_modules); do
		if [[ -n "${PRESELECT[$mod]:-}" ]]; then
			list+=("$mod")
			continue
		fi
		for var in ${M_VARS[$mod]}; do
			if [[ -n "${SET_VARS[$var]:-}" ]]; then
				list+=("$mod")
				break
			fi
		done
	done
	local IFS=,
	printf '%s' "${list[*]}"
}

# Turns "1,3,postgres" into module names; returns 1 on an unknown entry.
resolve_selection() {
	local input="$1" item mod idx
	local -a mods
	mapfile -t mods < <(available_modules)
	SELECTED=(base)
	for item in ${input//,/ }; do
		mod=""
		if [[ "$item" =~ ^[0-9]+$ ]]; then
			idx=$((item - 1))
			((idx >= 0 && idx < ${#mods[@]})) && mod="${mods[$idx]}"
		else
			for idx in "${!mods[@]}"; do
				[[ "${mods[$idx]}" == "$item" ]] && mod="$item"
			done
		fi
		if [[ -z "$mod" ]]; then
			warn "Modul tidak dikenal: $item"
			return 1
		fi
		[[ " ${SELECTED[*]} " == *" $mod "* ]] || SELECTED+=("$mod")
	done
}

selection_numbers() {
	local -a mods
	local list=() i
	mapfile -t mods < <(available_modules)
	for i in "${!mods[@]}"; do
		[[ ",$1," == *",${mods[$i]},"* || "${mods[$i]}" == base ]] && list+=("$((i + 1))")
	done
	local IFS=,
	printf '%s' "${list[*]}"
}

choose_modules() {
	local -a mods
	local i mod status default answer
	mapfile -t mods < <(available_modules)
	default="$(default_selection)"

	echo
	info "Modul"
	for i in "${!mods[@]}"; do
		mod="${mods[$i]}"
		status="${DET[$mod]:--}"
		printf '  %2d  %-16s %s\n' "$((i + 1))" "$mod" "${M_TITLE[$mod]:-$mod} ${DIM}($status)${RESET}"
		note "      ${M_DESC[$mod]:-}"
	done

	if ! interactive; then
		resolve_selection "$default" || die "Daftar modul tidak valid: $default"
	else
		while :; do
			ask answer "Pilih modul (nomor atau nama, pisahkan koma)" "$(selection_numbers "$default")"
			resolve_selection "$answer" && break
		done
	fi
	confirm_privileged
}

confirm_privileged() {
	local mod need=() reasons=()
	for mod in "${SELECTED[@]}"; do
		if [[ "${M_PRIV[$mod]:-}" == yes ]]; then
			need+=("$mod")
			reasons+=("$mod: ${M_WHY[$mod]:-butuh akses penuh}")
		fi
	done
	PRIVILEGED=0
	((${#need[@]})) || return 0

	echo
	if [[ "$MODE" == docker ]]; then
		echo "  Modul ${BOLD}${need[*]}${RESET} butuh container ${BOLD}privileged${RESET}:"
		echo "  container agent mendapat akses penuh ke kernel host (filesystem host tetap read-only)."
	else
		echo "  Modul ${BOLD}${need[*]}${RESET} butuh agent bisa membaca semua file dan proses"
		echo "  (capability CAP_DAC_READ_SEARCH dan CAP_SYS_PTRACE untuk service alloy)."
	fi
	for mod in "${reasons[@]}"; do
		note "  - $mod"
	done

	local allowed=n
	if [[ -n "$PRIVILEGED_ARG" ]]; then
		allowed="${PRIVILEGED_ARG:0:1}"
	elif confirm "Izinkan? Jika tidak, modul tersebut dilewati" y; then
		allowed=y
	fi

	if [[ "$allowed" == y ]]; then
		PRIVILEGED=1
		return 0
	fi
	local kept=()
	for mod in "${SELECTED[@]}"; do
		[[ " ${need[*]} " == *" $mod "* ]] || kept+=("$mod")
	done
	SELECTED=("${kept[@]}")
	warn "Dilewati: ${need[*]}"
}

ask_var() {
	local var="$1" flags="${V_FLAGS[$1]:-plain}" prompt="${V_PROMPT[$1]:-$1}" current
	if [[ -n "${SET_VARS[$var]:-}" ]]; then
		printf -v "$var" '%s' "${SET_VARS[$var]}"
		return
	fi
	current="${!var:-}"
	if [[ "$flags" == *secret* ]]; then
		ask_secret "$var" "$prompt" "$current"
	else
		ask "$var" "$prompt" "${current:-${V_DEFAULT[$var]:-}}"
	fi
}

configure_modules() {
	local mod var hook kept=() missing
	for mod in "${SELECTED[@]}"; do
		hook="${M_HOOK[$mod]:-}"
		if [[ -n "$hook" ]] && declare -F "setup_$hook" >/dev/null; then
			"setup_$hook" "$mod"
		fi
		missing=""
		for var in ${M_VARS[$mod]}; do
			ask_var "$var"
			if [[ -z "${!var:-}" && "${V_FLAGS[$var]:-}" != *optional* ]]; then
				missing="$var"
			fi
		done
		if [[ -n "$missing" ]]; then
			warn "Modul $mod dilewati karena $missing kosong."
			continue
		fi
		kept+=("$mod")
	done
	SELECTED=("${kept[@]}")
	local IFS=,
	MONITORING_MODULES="${SELECTED[*]}"
}

as_user() {
	local user="$1"
	shift
	(cd /tmp && if command -v runuser >/dev/null; then runuser -u "$user" -- "$@"; else su "$user" -s /bin/sh -c "$*"; fi)
}

setup_postgres() {
	[[ -z "${POSTGRES_DSN:-}" && -z "${SET_VARS[POSTGRES_DSN]:-}" ]] || return 0
	[[ "${DET[$1]:-}" == "berjalan di mesin" ]] && id postgres >/dev/null 2>&1 || return 0
	confirm "Buat user database 'monitoring' (role pg_monitor) otomatis?" y || return 0
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
}

setup_mysql() {
	[[ -z "${MYSQL_DSN:-}" && -z "${SET_VARS[MYSQL_DSN]:-}" ]] || return 0
	[[ "${DET[$1]:-}" == "berjalan di mesin" ]] && command -v mysql >/dev/null || return 0
	confirm "Buat user database 'monitoring' (PROCESS, REPLICATION CLIENT, SELECT) otomatis?" y || return 0
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
}

setup_redis() {
	[[ -z "${REDIS_PASSWORD:-}" && -z "${SET_VARS[REDIS_PASSWORD]:-}" ]] || return 0
	local conf
	for conf in /etc/redis/redis.conf /etc/redis.conf /etc/redis/*.conf; do
		[[ -r "$conf" ]] || continue
		REDIS_PASSWORD="$(awk '$1 == "requirepass" {gsub(/^"|"$/, "", $2); print $2; exit}' "$conf")"
		if [[ -n "$REDIS_PASSWORD" ]]; then
			ok "Password Redis diambil dari $conf"
			return 0
		fi
	done
}

yaml_quote() {
	local s="${1//\\/\\\\}"
	printf '"%s"' "${s//\"/\\\"}"
}

write_log_targets() {
	local file="$1" entry
	shift
	{
		echo "# Dikelola oleh install.sh."
		(($#)) || echo "[]"
		for entry in "$@"; do
			printf -- '- targets: [localhost]\n  labels:\n    __path__: %s\n    service: %s\n' \
				"$(yaml_quote "${entry%=*}")" "$(yaml_quote "${entry##*=}")"
		done
	} >"$file"
}

setup_files() {
	local entry answer
	if ((${#FILE_TARGETS[@]})); then
		echo "  File log yang terdeteksi:"
		for entry in "${FILE_TARGETS[@]}"; do
			note "  ${entry%=*}  →  service=${entry##*=}"
		done
	fi
	if interactive; then
		note "Tambah file log lain dengan format /path/ke/*.log=nama-service. Enter kosong untuk selesai."
		while :; do
			read -r -p "  File log tambahan: " answer </dev/tty
			[[ -n "$answer" ]] || break
			if [[ "$answer" != /*=* ]]; then
				warn "Format: /path/ke/*.log=nama-service"
				continue
			fi
			CUSTOM_LOG_FILES+=("$answer")
		done
	fi
}

setup_process() {
	note "Isi nama proses (seperti di 'ps -eo comm'), pisahkan koma."
	ask PROCESS_NAMES "Proses yang dipantau" "${PROCESS_NAMES:-${DETECTED_PROCESSES:-}}"
	PROCESS_NAMES="${PROCESS_NAMES// /}"
	[[ -n "$PROCESS_NAMES" ]] || warn "Daftar proses kosong; hanya proses alloy yang dipantau."
}

# --- agent options -----------------------------------------------------------

normalize_size() {
	local s="${1^^}"
	s="${s%B}"
	[[ "$s" =~ ^[0-9]+[KMG]?$ ]] || return 1
	printf '%s' "$s"
}

# 90% of the limit, so the Go runtime collects garbage before the kernel kills it.
gomemlimit_for() {
	local s="$1" n unit mib
	n="${s%[KMG]}"
	unit="${s:${#n}}"
	case "$unit" in
	G) mib=$((n * 1024)) ;;
	M) mib=$n ;;
	K) mib=$((n / 1024)) ;;
	*) mib=$((n / 1048576)) ;;
	esac
	if ((mib > 0)); then
		printf '%dMiB' $((mib * 9 / 10))
	fi
}

choose_agent_options() {
	echo
	info "Pengaturan agent"

	local default_memory=512M answer
	((MEM_MB > 0 && MEM_MB < 2048)) && default_memory=256M
	echo "  ${BOLD}Batas memori${RESET}: agent dibatasi supaya tidak mengganggu aplikasi di server ini."
	note "Jika melewati batas, agent di-restart otomatis. 0 = tanpa batas."
	while :; do
		ask answer "Batas memori agent" "${AGENT_MEMORY_LIMIT:-$default_memory}"
		if [[ "$answer" == 0 ]]; then
			AGENT_MEMORY_LIMIT=0
			GOMEMLIMIT=""
			break
		fi
		if answer="$(normalize_size "$answer")"; then
			AGENT_MEMORY_LIMIT="$answer"
			GOMEMLIMIT="$(gomemlimit_for "$answer")"
			break
		fi
		interactive || die "Batas memori tidak valid."
		warn "Contoh: 256M, 512M, 1G, atau 0."
	done

	echo
	echo "  ${BOLD}Mode offline${RESET}: saat PLG Stack tidak bisa dihubungi, agent terus mengumpulkan data."
	note "Metrik disimpan di disk agent; log ditahan di sumbernya (journald, file log, log container)."
	note "Begitu terhubung lagi, semuanya dikirim, jadi penyebab putusnya tetap terlihat di dashboard."
	while :; do
		ask AGENT_OFFLINE_BUFFER "Simpan metrik saat terputus maksimal" "${AGENT_OFFLINE_BUFFER:-24h}"
		[[ "$AGENT_OFFLINE_BUFFER" =~ ^[0-9]+[hm]$ ]] && break
		interactive || die "Durasi offline tidak valid: $AGENT_OFFLINE_BUFFER"
		warn "Contoh: 12h, 24h, 72h."
	done

	JOURNAL_ENABLE=0
	if [[ $HAS_SYSTEMD -eq 1 && $JOURNAL_PERSISTENT -eq 0 ]]; then
		echo
		echo "  ${BOLD}Journald${RESET} di server ini hanya disimpan di RAM: log sebelum server mati atau reboot hilang."
		note "Disimpan di disk, log itu tetap ada dan terkirim setelah server hidup lagi (dibatasi maks. 10% disk)."
		if [[ -n "$JOURNAL_ARG" ]]; then
			[[ "$JOURNAL_ARG" == yes ]] && JOURNAL_ENABLE=1
		elif confirm "Simpan journald di disk?" y; then
			JOURNAL_ENABLE=1
		fi
	fi

	echo
	echo "  ${BOLD}Sensor rahasia${RESET}: nilai password, token, secret, api key, dan kredensial di URL"
	note "diganti *** sebelum log dikirim."
	if [[ "$REDACT_ARG" == no ]]; then
		LOG_REDACT_REGEX="$NEVER_MATCH"
	elif confirm "Aktifkan sensor rahasia di log?" "$([[ "$LOG_REDACT_REGEX" == "$NEVER_MATCH" ]] && echo n || echo y)"; then
		[[ "$LOG_REDACT_REGEX" == "$NEVER_MATCH" ]] && LOG_REDACT_REGEX=""
	else
		LOG_REDACT_REGEX="$NEVER_MATCH"
	fi

	AGENT_LOG_MAX_SIZE="${AGENT_LOG_MAX_SIZE:-10m}"
	return 0
}

# --- install -----------------------------------------------------------------

enable_persistent_journal() {
	install -d -m 2755 /var/log/journal
	if journald_storage_volatile; then
		install -d -m 0755 /etc/systemd/journald.conf.d
		printf '[Journal]\nStorage=persistent\n' >/etc/systemd/journald.conf.d/plg-agent.conf
	fi
	systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
	systemctl restart systemd-journald
	JOURNAL_PERSISTENT=1
	ok "Journald sekarang disimpan di disk."
}

prepare_host() {
	install -d -m 0755 "$CONF_DIR" "$LOGS_D" "$METRICS_D" "$TEXTFILE_DIR"
	((JOURNAL_ENABLE)) && enable_persistent_journal

	install -d -m 0755 "$MODULE_DIR"
	rm -f "$MODULE_DIR"/*.alloy
	local mod
	for mod in "${SELECTED[@]}"; do
		fetch_file "$mod.alloy" "$MODULE_DIR/$mod.alloy"
	done
	ok "Modul ditulis ke $MODULE_DIR"

	if [[ " ${SELECTED[*]} " == *" files "* ]]; then
		write_log_targets "$LOGS_D/auto.yaml" "${FILE_TARGETS[@]}"
		if ((${#CUSTOM_LOG_FILES[@]})); then
			local existing=() entry
			if [[ -f "$LOGS_D/custom.yaml" ]]; then
				mapfile -t existing < <(sed -n 's/^    __path__: "\(.*\)"$/\1/p' "$LOGS_D/custom.yaml")
			fi
			for entry in "${CUSTOM_LOG_FILES[@]}"; do
				[[ " ${existing[*]} " == *" ${entry%=*} "* ]] && continue
				[[ -f "$LOGS_D/custom.yaml" ]] || echo "# File log tambahan; boleh diedit." >"$LOGS_D/custom.yaml"
				printf -- '- targets: [localhost]\n  labels:\n    __path__: %s\n    service: %s\n' \
					"$(yaml_quote "${entry%=*}")" "$(yaml_quote "${entry##*=}")" >>"$LOGS_D/custom.yaml"
			done
		fi
		ok "Daftar file log di $LOGS_D"
	fi
}

persisted_keys() {
	local mod var
	printf '%s\n' "${CORE_KEYS[@]}"
	for mod in "${SELECTED[@]}"; do
		for var in ${M_VARS[$mod]}; do
			printf '%s\n' "$var"
		done
	done
}

install_docker() {
	info "Memasang agent (mode docker, Alloy $ALLOY_VERSION)"
	local -a keys
	mapfile -t keys < <(persisted_keys)
	write_env_file "$ENV_FILE" docker "${keys[@]}"

	docker pull -q "grafana/alloy:$ALLOY_VERSION" >/dev/null || die "Gagal menarik image grafana/alloy:$ALLOY_VERSION."
	docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

	local flags=(--network host --pid host --cgroupns host
		--log-opt "max-size=$AGENT_LOG_MAX_SIZE" --log-opt max-file=3)
	((PRIVILEGED)) && flags+=(--privileged)
	[[ "$AGENT_MEMORY_LIMIT" != 0 ]] && flags+=(--memory "${AGENT_MEMORY_LIMIT,,}")

	local mounts=(
		-v /proc:/host/proc:ro
		-v /sys:/host/sys:ro
		-v "$MODULE_DIR:/etc/alloy/plg:ro"
		-v "$DATA_VOLUME:/var/lib/alloy/data"
	)
	local path
	# Bind-mounting a missing path makes Docker create it as an empty
	# directory on the host, which breaks /etc/machine-id in particular.
	for path in /var/run/docker.sock /run/containerd /var/lib/docker /dev/disk /var/log/journal /run/log/journal /etc/machine-id; do
		[[ -e "$path" ]] && mounts+=(-v "$path:$path:ro")
	done

	# rslave lets disks mounted later show up in the agent, but Docker refuses
	# it when / is not a shared mount (e.g. Docker Desktop, some containers).
	local err
	if ! err="$(run_agent_container -v /:/host/root:ro,rslave 2>&1 >/dev/null)"; then
		[[ "$err" == *"not a shared or slave mount"* ]] || die "Gagal menjalankan container agent: $err"
		warn "/ bukan shared mount; disk yang di-mount setelah ini baru terlihat setelah agent di-restart."
		docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
		err="$(run_agent_container -v /:/host/root:ro 2>&1 >/dev/null)" || die "Gagal menjalankan container agent: $err"
	fi
	ok "Container $CONTAINER_NAME berjalan."
}

# Uses flags and mounts from install_docker; extra arguments add the root mount.
run_agent_container() {
	docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
		"${flags[@]}" \
		--env-file "$ENV_FILE" \
		--label com.plg-stack.agent=true \
		"$@" \
		"${mounts[@]}" \
		"grafana/alloy:$ALLOY_VERSION" \
		run --server.http.listen-addr="$ALLOY_HTTP" --storage.path=/var/lib/alloy/data /etc/alloy/plg
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
		# Debian package versions carry a revision suffix, e.g. 1.20.1-1.
		local apt_version
		apt_version="$(apt-cache madison alloy 2>/dev/null |
			awk -v v="$version" '$3 == v || index($3, v "-") == 1 {print $3; exit}')"
		if [[ -z "$apt_version" ]] ||
			! apt-get install -y -qq --allow-downgrades "alloy=$apt_version" </dev/null >/dev/null; then
			warn "Versi $version tidak ada di repo, memasang versi terbaru."
			apt-get install -y -qq alloy </dev/null >/dev/null
		fi
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

	local -a keys
	mapfile -t keys < <(persisted_keys)
	write_env_file "$ENV_FILE" systemd "${keys[@]}"

	local groups=() group
	for group in adm systemd-journal; do
		getent group "$group" >/dev/null && groups+=("$group")
	done
	if [[ " ${SELECTED[*]} " == *" docker-"* ]] && getent group docker >/dev/null; then
		groups+=(docker)
	fi

	install -d -m 0755 "$(dirname "$NATIVE_DROPIN")"
	{
		echo "[Service]"
		echo "EnvironmentFile=$ENV_FILE"
		echo "SupplementaryGroups=${groups[*]}"
		[[ "$AGENT_MEMORY_LIMIT" != 0 ]] && echo "MemoryMax=$AGENT_MEMORY_LIMIT"
		((PRIVILEGED)) && echo "AmbientCapabilities=CAP_DAC_READ_SEARCH CAP_SYS_PTRACE"
		echo "ExecStart="
		echo "ExecStart=/usr/bin/alloy run --server.http.listen-addr=$ALLOY_HTTP --storage.path=/var/lib/alloy/data $MODULE_DIR"
	} >"$NATIVE_DROPIN"
	systemctl daemon-reload
	systemctl enable alloy >/dev/null 2>&1
	systemctl restart alloy
	ok "Service alloy berjalan."
}

agent_metric_sum() {
	curl -fsS "http://$ALLOY_HTTP/metrics" 2>/dev/null |
		awk -v name="$1" -v filter="${2:-}" 'index($0, name) == 1 && (filter == "" || index($0, filter)) {sum += $NF} END {print sum + 0}'
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

	local unhealthy
	sleep 5
	unhealthy="$(agent_metric_sum alloy_component_controller_running_components 'health_type="unhealthy"')"
	if [[ "$unhealthy" != 0 ]]; then
		warn "$unhealthy komponen tidak sehat. Biasanya kredensial database salah atau path log tidak ada."
		print_logs_hint
	else
		ok "Semua komponen sehat."
	fi

	for i in $(seq 1 12); do
		[[ "$(agent_metric_sum prometheus_remote_storage_samples_total)" != 0 ]] && break
		sleep 5
	done
	if [[ "$(agent_metric_sum prometheus_remote_storage_samples_total)" != 0 ]]; then
		ok "Data pertama sudah terkirim ke PLG Stack."
	else
		warn "Belum ada data terkirim setelah 1 menit. Cek koneksi ke $MONITORING_URL dan token."
		print_logs_hint
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
	docker volume rm "$DATA_VOLUME" >/dev/null 2>&1 || true
	ok "Container agent dihapus."
}

remove_native() {
	systemctl disable --now alloy >/dev/null 2>&1 || true
	rm -f "$NATIVE_DROPIN"
	systemctl daemon-reload
	ok "Service alloy dimatikan."
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
	*)
		warn "Agent tidak ditemukan di server ini."
		return 0
		;;
	esac
	rm -rf "$MODULE_DIR" "$ENV_FILE" "$LOGS_D/auto.yaml"
	if confirm "Hapus juga file log tambahan, target metrik, dan metrik custom ($LOGS_D, $METRICS_D, $TEXTFILE_DIR)?" n; then
		rm -rf "$CONF_DIR" "$TEXTFILE_DIR"
	fi
	echo "  User database 'monitoring' (jika pernah dibuat) tidak dihapus."
}

# --- main --------------------------------------------------------------------

print_summary() {
	echo
	info "Ringkasan"
	printf '  %-14s %s\n' Mode "$MODE" Tujuan "$MONITORING_URL" Nama "$MONITORING_HOST" Env "$MONITORING_ENV" \
		Modul "${SELECTED[*]}" Privileged "$( ((PRIVILEGED)) && echo ya || echo tidak)" \
		"Batas memori" "$( [[ "$AGENT_MEMORY_LIMIT" == 0 ]] && echo "tanpa batas" || echo "$AGENT_MEMORY_LIMIT")" \
		"Mode offline" "metrik disimpan hingga $AGENT_OFFLINE_BUFFER"
}

main() {
	parse_args "$@"
	[[ $EUID -eq 0 ]] || die "Jalankan sebagai root, mis. dengan sudo."
	command -v curl >/dev/null || die "curl dibutuhkan."

	if [[ $UNINSTALL -eq 1 ]]; then
		uninstall
		return
	fi

	echo "${BOLD}PLG Stack agent installer${RESET} (Grafana Alloy $ALLOY_VERSION)"
	detect_system
	detect_existing
	print_report

	ask_connection
	load_catalog
	local -a module_vars
	mapfile -t module_vars < <(all_module_vars)
	((${#module_vars[@]})) && load_env_file "$ENV_FILE" "${module_vars[@]}"
	detect_modules

	choose_mode
	choose_modules
	configure_modules
	choose_agent_options
	print_summary
	confirm "Pasang sekarang?" y || exit 1
	echo

	if [[ -n "$EXISTING" && "$EXISTING" != "$MODE" ]]; then
		"remove_$EXISTING"
	fi
	prepare_host
	"install_$MODE"
	verify || true

	echo
	ok "${BOLD}Selesai.${RESET} Server '$MONITORING_HOST' akan muncul di dashboard Fleet Overview dalam ±1 menit."
	echo "  File log tambahan: $LOGS_D/*.yaml   Target metrik: $METRICS_D/*.yaml   Metrik custom: $TEXTFILE_DIR/*.prom"
	echo "  Jalankan ulang installer ini untuk mengubah pilihan, atau dengan --uninstall untuk menghapus."
}

if [[ "${PLG_INSTALL_SOURCE_ONLY:-}" != 1 ]]; then
	main "$@"
fi
