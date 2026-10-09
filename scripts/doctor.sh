#!/usr/bin/env bash
# Checks a PLG Stack deployment end to end and says what to fix.
#
#   scripts/doctor.sh [--project NAME] [--host SERVER]
#
# On the stack's server it checks everything. Elsewhere (e.g. a laptop with
# the same .env) only configuration, DNS, TLS and the public endpoints.
# --host SERVER adds the details of one monitored server.
set -uo pipefail

cd "$(dirname "$0")/.."

if [[ -t 1 ]]; then
	GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m' BOLD=$'\e[1m' DIM=$'\e[2m' RESET=$'\e[0m'
else
	GREEN="" YELLOW="" RED="" BOLD="" DIM="" RESET=""
fi
OK=0 WARN=0 FAIL=0

section() { printf '\n%s\n' "${BOLD}==> $*${RESET}"; }
ok() {
	printf '  %s %s\n' "${GREEN}✓${RESET}" "$*"
	OK=$((OK + 1))
}
warn() {
	printf '  %s %s\n' "${YELLOW}!${RESET}" "$*"
	WARN=$((WARN + 1))
}
fail() {
	printf '  %s %s\n' "${RED}✗${RESET}" "$*"
	FAIL=$((FAIL + 1))
}
hint() { printf '    %s\n' "${DIM}$*${RESET}"; }
die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 2
}

PROJECT=""
FOCUS=""
while (($#)); do
	case "$1" in
	--project) PROJECT="${2:?--project butuh nilai}" && shift ;;
	--host) FOCUS="${2:?--host butuh nilai}" && shift ;;
	-h | --help) sed -n '2,8p' "$0" | sed 's/^#//' && exit 0 ;;
	*) die "Argumen tidak dikenal: $1 (lihat --help)" ;;
	esac
	shift
done

# setup.sh writes KEY='value' and Dokploy KEY="value"; Compose also drops a
# ' # comment' after an unquoted value.
env_value() {
	local value
	value="$(sed -n "s/^$1=//p" .env | tail -1)"
	case "$value" in
	\'*) value="${value#\'}" && value="${value%%\'*}" ;;
	\"*) value="${value#\"}" && value="${value%%\"*}" ;;
	*) value="${value%%[[:space:]]#*}" ;;
	esac
	printf '%s' "$value"
}
config_value() { sed -n "s/^$1 = \"\\(.*\\)\"/\\1/p" grafana/generator/config.toml | head -1; }
# A level of an inline threshold table in config.toml, e.g. threshold disk warning.
threshold() { sed -n "s/^$1 = {.*$2 = \"\\{0,1\\}\\([^\",} ]*\\).*/\\1/p" grafana/generator/config.toml | head -1; }
seconds() {
	local n="${1%[smhdw]}"
	case "$1" in
	*s) echo "$n" ;; *m) echo $((n * 60)) ;; *h) echo $((n * 3600)) ;; *d) echo $((n * 86400)) ;; *w) echo $((n * 604800)) ;;
	esac
}
ago() {
	local s="${1%.*}"
	if ((s < 120)); then echo "$s detik"; elif ((s < 7200)); then echo "$((s / 60)) menit"; elif ((s < 172800)); then echo "$((s / 3600)) jam"; else echo "$((s / 86400)) hari"; fi
}
has() { command -v "$1" >/dev/null 2>&1; }
newest_storage_period() {
	tr -d '"' | awk '/^schema_config:/ { on = 1; next } /^[^ ]/ { on = 0 }
		on && $2 == "from:" { from = $3 }
		on && $1 == "object_store:" { n++; previous = store; since = from; store = $2 }
		END { if (n) print n, since, store, previous }'
}
store_name() { if [[ "$1" == s3 ]]; then echo S3; else echo "disk lokal"; fi; }

# --- configuration ------------------------------------------------------------------

section "Konfigurasi"
[[ -f .env ]] || {
	fail ".env tidak ada; jalankan scripts/setup.sh"
	exit 1
}
GRAFANA_DOMAIN="$(env_value GRAFANA_DOMAIN)"
INGEST_DOMAIN="$(env_value INGEST_DOMAIN)"
SCHEME="$(env_value GATEWAY_SCHEME)"
PROFILES=",$(env_value COMPOSE_PROFILES),"
SELF_NAME="$(env_value SELF_MONITORING_NAME)"
SELF_NAME="${SELF_NAME:-plg-stack}"
SELF_TOKEN="$(env_value SELF_MONITORING_TOKEN)"
TOKENS="$(env_value AGENT_TOKENS)"
if [[ "${SCHEME:-https}" == http ]]; then MODE=dokploy; else MODE=standalone; fi
ok ".env ditemukan (mode $MODE)"

for key in GRAFANA_DOMAIN INGEST_DOMAIN; do
	value="${!key}"
	if [[ -z "$value" ]]; then
		fail "$key kosong"
	elif [[ "$value" == *example.com ]]; then
		fail "$key masih contoh ($value)"
	fi
done
[[ "$(env_value GRAFANA_ADMIN_PASSWORD)" == change-me ]] && fail "GRAFANA_ADMIN_PASSWORD masih 'change-me'"
if [[ "$PROFILES" == *,self-monitoring,* && ( -z "$SELF_TOKEN" || "$SELF_TOKEN" == change-me ) ]]; then
	fail "SELF_MONITORING_TOKEN kosong atau masih 'change-me'"
fi
compose_file="$(env_value COMPOSE_FILE)"
if [[ "$MODE" == standalone && "$compose_file" != *compose.standalone.yaml* ]]; then
	fail "Mode standalone tanpa compose.standalone.yaml di COMPOSE_FILE: port 80/443 tidak dibuka"
elif [[ "$MODE" == dokploy && "$compose_file" == *compose.standalone.yaml* ]]; then
	warn "Mode Dokploy tapi COMPOSE_FILE memuat compose.standalone.yaml (bentrok dengan port Traefik)"
fi
token_count="$(tr ', ' '\n\n' <<<"$TOKENS" | grep -c ':' || true)"
if ((token_count == 0)) && [[ "$PROFILES" != *,self-monitoring,* ]]; then
	warn "Belum ada token agent"
	hint "Tambahkan server: scripts/agent-token.sh add NAMA"
else
	ok "$token_count token agent$([[ "$PROFILES" == *,self-monitoring,* ]] && echo " + agent self-monitoring")"
fi
if [[ "$PROFILES" == *,backup,* ]]; then
	if [[ -z "$(env_value BACKUP_REPOSITORY)" || -z "$(env_value BACKUP_PASSWORD)" ]]; then
		fail "Profil backup aktif tapi BACKUP_REPOSITORY / BACKUP_PASSWORD kosong"
	fi
else
	warn "Backup terjadwal belum aktif"
	hint "Aktifkan lewat scripts/setup.sh (bagian Backup)"
fi

# --- DNS ------------------------------------------------------------------------------

section "DNS"
for domain in "$GRAFANA_DOMAIN" "$INGEST_DOMAIN"; do
	[[ -n "$domain" ]] || continue
	mapfile -t ips < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
	if ((${#ips[@]} == 0)); then
		fail "$domain tidak bisa di-resolve"
		hint "Buat A record $domain ke IP server stack"
		continue
	fi
	ok "$domain → ${ips[*]}"
done

# --- HTTPS ------------------------------------------------------------------------------

section "HTTPS dan sertifikat"
has curl || fail "curl tidak ada; cek HTTPS dilewati"
certificate() {
	local domain="$1" text end issuer days
	has openssl || return 0
	text="$(openssl s_client -connect "$domain:443" -servername "$domain" </dev/null 2>/dev/null |
		openssl x509 -noout -enddate -issuer 2>/dev/null)"
	end="$(sed -n 's/^notAfter=//p' <<<"$text")"
	[[ -n "$end" ]] || return 0
	issuer="$(sed -n 's/^issuer=.*O *= *\([^,]*\).*/\1/p' <<<"$text")"
	[[ -n "$issuer" ]] || issuer="$(sed -n 's/^issuer=.*CN *= *//p' <<<"$text")"
	days=$((($(date -d "$end" +%s) - $(date +%s)) / 86400))
	if ((days < 0)); then
		fail "Sertifikat $domain kedaluwarsa"
	elif ((days < 14)); then
		warn "Sertifikat $domain berlaku $days hari lagi (${issuer:-?}); perpanjangan otomatis mungkin gagal"
	else
		ok "Sertifikat $domain berlaku $days hari lagi (${issuer:-?})"
	fi
}
if has curl; then
	for domain in "$GRAFANA_DOMAIN" "$INGEST_DOMAIN"; do
		[[ -n "$domain" ]] || continue
		if error="$(curl -sS -o /dev/null --max-time 10 "https://$domain/" 2>&1)"; then
			certificate "$domain"
		else
			fail "https://$domain tidak bisa dibuka: ${error#curl: }"
			[[ "$MODE" == standalone ]] && hint "Cek port 80/443 terbuka dan DNS sudah mengarah ke server ini (Caddy butuh keduanya untuk sertifikat)"
			[[ "$MODE" == dokploy ]] && hint "Cek tab Domains di Dokploy: domain ke service gateway, port 80, HTTPS aktif"
		fi
	done
	health="$(curl -sS --max-time 10 "https://$GRAFANA_DOMAIN/api/health" 2>/dev/null)"
	if [[ "$health" == *'"database"'*'"ok"'* ]]; then
		ok "Grafana sehat"
	elif [[ -n "$GRAFANA_DOMAIN" ]]; then
		fail "Grafana tidak menjawab /api/health dengan benar"
	fi
fi

# --- ingest -------------------------------------------------------------------------------

section "Endpoint ingest"
ingest="https://$INGEST_DOMAIN"
status() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null; }
if has curl && [[ -n "$INGEST_DOMAIN" ]]; then
	code="$(status "$ingest/agent/install.sh")"
	if [[ "$code" == 200 ]]; then
		ok "Installer agent bisa diunduh"
	else
		fail "Installer agent tidak bisa diunduh (HTTP $code)"
	fi
	code="$(status "$ingest/ping")"
	if [[ "$code" == 401 ]]; then
		ok "Request tanpa token ditolak (401)"
	else
		fail "Request tanpa token mendapat HTTP $code, seharusnya 401"
	fi
	name="" token=""
	if [[ -n "$SELF_TOKEN" && "$PROFILES" == *,self-monitoring,* ]]; then
		name="$SELF_NAME" token="$SELF_TOKEN"
	else
		pair="$(tr ', ' '\n\n' <<<"$TOKENS" | grep -m1 ':' || true)"
		name="${pair%%:*}" token="${pair#*:}"
	fi
	if [[ -n "$token" ]]; then
		code="$(status -u "$name:$token" "$ingest/ping")"
		if [[ "$code" == 200 ]]; then
			ok "Token '$name' diterima gateway"
			code="$(status -u "$name:$token" -H 'Content-Type: application/json' --data '{"streams":[]}' "$ingest/loki/api/v1/push")"
			if [[ "$code" == 204 ]]; then
				ok "Loki menerima push lewat gateway"
			else
				fail "Push ke Loki lewat gateway gagal (HTTP $code)"
			fi
			# An empty body is rejected by Prometheus itself (400), which proves
			# the request got through the gateway.
			code="$(status -u "$name:$token" -X POST "$ingest/api/v1/write")"
			if [[ "$code" == 400 ]]; then
				ok "Prometheus menerima remote write lewat gateway"
			else
				fail "Remote write ke Prometheus lewat gateway gagal (HTTP $code)"
			fi
		else
			fail "Token '$name' ditolak gateway (HTTP $code)"
			hint "Token baru berlaku setelah gateway dimuat ulang (redeploy / docker compose up -d gateway)"
		fi
	fi
fi

# --- containers ---------------------------------------------------------------------------

if ! has docker || ! docker info >/dev/null 2>&1; then
	printf '\n%s\n' "${DIM}Docker tidak bisa diakses dari sini; cek container, data, backup, dan disk dilewati.${RESET}"
	LOCAL=0
else
	if [[ -z "$PROJECT" ]]; then
		mapfile -t projects < <(docker ps --filter label=com.docker.compose.service=prometheus \
			--format '{{.Label "com.docker.compose.project"}}' | sort -u)
		((${#projects[@]} <= 1)) || die "Ada beberapa stack (${projects[*]}); pilih dengan --project."
		PROJECT="${projects[0]:-}"
	fi
	if [[ -z "$PROJECT" ]]; then
		printf '\n%s\n' "${DIM}Stack tidak berjalan di mesin ini; cek container, data, backup, dan disk dilewati.${RESET}"
		LOCAL=0
	else
		LOCAL=1
	fi
fi

container() {
	docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
		--filter "label=com.docker.compose.service=$1" | head -1
}

if ((LOCAL)); then
	section "Container (project $PROJECT)"
	services=(gateway prometheus loki grafana watchdog)
	[[ "$PROFILES" == *,self-monitoring,* ]] && services+=(agent)
	[[ "$PROFILES" == *,backup,* ]] && services+=(backup)
	for service in "${services[@]}"; do
		id="$(container "$service")"
		if [[ -z "$id" ]]; then
			fail "$service tidak ada"
			continue
		fi
		read -r state health restarts < <(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.RestartCount}}' "$id")
		if [[ "$state" != running ]]; then
			fail "$service $state"
			hint "Lihat penyebabnya: docker logs --tail 50 $(docker inspect -f '{{.Name}}' "$id" | tr -d /)"
		elif [[ "$health" == unhealthy ]]; then
			fail "$service berjalan tapi unhealthy"
		elif ((restarts > 3)); then
			warn "$service berjalan, tapi sudah restart ${restarts}x"
		elif [[ "$health" == - ]]; then
			ok "$service berjalan"
		else
			ok "$service berjalan ($health)"
		fi
	done
	init="$(container loki-init)"
	if [[ -n "$init" && "$(docker inspect -f '{{.State.ExitCode}}' "$init")" != 0 ]]; then
		fail "loki-init gagal menulis config Loki, jadi Loki tidak bisa start"
		hint "Lihat penyebabnya: docker logs $(docker inspect -f '{{.Name}}' "$init" | tr -d /)"
	fi
	PROM="$(container prometheus)"
fi

# --- data -----------------------------------------------------------------------------------

urlencode() {
	local s="$1" out="" c i
	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		case "$c" in
		[A-Za-z0-9.~_-]) out+="$c" ;;
		*) printf -v c '%%%02X' "'$c" && out+="$c" ;;
		esac
	done
	printf '%s' "$out"
}

# One line per series: "label=value,... <TAB> value".
query() {
	local url="$1" expr="$2" json
	json="$(docker exec "$PROM" wget -qO- "$url?query=$(urlencode "$expr")" 2>/dev/null)" || return 1
	if has jq; then
		jq -r '.data.result[] | "\(.metric | to_entries | map("\(.key)=\(.value)") | join(","))\t\(.value[1])"' <<<"$json"
	else
		python3 -c '
import json, sys
for r in json.load(sys.stdin)["data"]["result"]:
    print(",".join(f"{k}={v}" for k, v in r["metric"].items()) + "\t" + r["value"][1])' <<<"$json"
	fi
}
prom() { query http://127.0.0.1:9090/api/v1/query "$1"; }
loki() { query http://loki:3100/loki/api/v1/query "$1"; }
label() { sed -n "s/.*\\b$1=\\([^,	]*\\).*/\\1/p" <<<"$2"; }
value() { cut -f2 <<<"$1"; }
list() { cut -f1 <<<"$1" | sed 's/^host=//' | sed '/^$/d' | paste -sd, - | sed 's/,/, /g'; }

if [[ -n "$FOCUS" ]] && ((!LOCAL)); then
	warn "--host $FOCUS hanya bisa dicek di server stack"
fi
if ((LOCAL)) && [[ -n "$PROM" ]] && ! has jq && ! has python3; then
	warn "jq atau python3 dibutuhkan untuk cek data; dilewati"
elif ((LOCAL)) && [[ -n "$PROM" ]]; then
	section "Data masuk"
	silent="$(config_value silent_after)"
	silent="${silent:-3m}"
	forget="$(config_value forget_after)"
	forget="${forget:-24h}"

	if [[ "$(docker exec "$PROM" wget -qO- http://127.0.0.1:9090/-/ready 2>/dev/null)" == *Ready* ]]; then
		ok "Prometheus siap ($(value "$(prom 'prometheus_tsdb_head_series')") series aktif)"
	else
		fail "Prometheus belum siap"
	fi
	if [[ "$(docker exec "$PROM" wget -qO- http://loki:3100/ready 2>/dev/null)" == ready* ]]; then
		ok "Loki siap"
	else
		fail "Loki belum siap"
	fi
	storage="$(env_value LOKI_STORAGE)"
	storage="${storage:-filesystem}"
	read -r periods since store previous < <(docker exec "$PROM" wget -qO- http://loki:3100/config 2>/dev/null |
		newest_storage_period)
	if [[ -z "$store" ]]; then
		:
	elif [[ "$store" != "$storage" ]]; then
		fail "LOKI_STORAGE=$storage, tapi Loki masih menyimpan log di $store"
		hint "Deploy ulang (docker compose up -d, atau Deploy di Dokploy)"
	elif ((periods > 1)) && [[ "$since" > "$(date -u +%F)" ]]; then
		ok "Log disimpan di $(store_name "$previous") sampai $since 00:00 UTC, lalu di $(store_name "$store")"
	elif ((periods > 1)); then
		ok "Log disimpan di $(store_name "$store") sejak $since; log sebelumnya tetap dibaca dari tempat lamanya sampai terhapus retensi"
	else
		ok "Log disimpan di $(store_name "$store")"
	fi

	reporting="$(value "$(prom "count(group by (host) (last_over_time(up{job=\"node\"}[$silent])))")")"
	if [[ "${reporting:-0}" == 0 ]]; then
		warn "Belum ada server yang melapor dalam $silent terakhir"
	else
		ok "$reporting server melapor"
	fi
	lines="$(prom "(time() - max by (host) (timestamp(up{job=\"node\"}) or max_over_time(timestamp(up{job=\"node\"})[$forget:1m]))) > $(seconds "$silent")")"
	while IFS=$'\t' read -r labels seconds_ago; do
		[[ -n "$labels" ]] || continue
		fail "Server $(label host "$labels") tidak mengirim data sejak $(ago "$seconds_ago") lalu"
	done <<<"$lines"
	[[ -n "$lines" ]] && hint "Di server itu: systemctl status alloy / docker logs plg-agent; detail: scripts/doctor.sh --host NAMA"

	seen=" $(prom 'group by (host) (last_over_time(up{job="node"}[7d]))' | cut -f1 | sed 's/^host=//' | tr '\n' ' ') "
	unused=()
	for pair in $(tr ', ' '\n\n' <<<"$TOKENS"); do
		[[ "$pair" == *:* && "$seen" != *" ${pair%%:*} "* ]] && unused+=("${pair%%:*}")
	done
	((${#unused[@]} == 0)) || warn "Token tanpa data 7 hari terakhir: ${unused[*]} (agent belum dipasang, atau server sudah dipensiunkan)"

	dupes="$(prom 'count by (host) (count by (host, machine_id) (alloy_build_info{job="alloy"})) > 1')"
	[[ -z "$dupes" ]] || fail "Nama server dipakai lebih dari satu mesin: $(list "$dupes")"
	lag="$(prom "max by (host) (prometheus_remote_storage_highest_timestamp_in_seconds{job=\"alloy\"}) - max by (host) (prometheus_remote_storage_queue_highest_sent_timestamp_seconds{job=\"alloy\"} > 0) > $(seconds "$(threshold agent_lag warning)")")"
	[[ -z "$lag" ]] || warn "Agent tertinggal mengirim data: $(list "$lag")"
	dropped="$(prom 'sum by (host) (increase(prometheus_remote_storage_samples_failed_total{job="alloy"}[1h])) > 0 or sum by (host) (increase(loki_write_dropped_entries_total{job="alloy"}[1h])) > 0')"
	[[ -z "$dropped" ]] || warn "Agent membuang data dalam 1 jam terakhir: $(list "$dropped")"

	rejected="$(prom 'sum(increase(prometheus_tsdb_out_of_bound_samples_total[1h])) + sum(increase(prometheus_tsdb_too_old_samples_total[1h])) + sum(increase(prometheus_tsdb_out_of_order_samples_total[1h])) > 0')"
	if [[ -n "$rejected" ]]; then
		warn "Prometheus menolak $(value "$rejected" | cut -d. -f1) sampel dalam 1 jam terakhir"
		hint "Biasanya backlog agent yang lebih tua dari PROMETHEUS_OOO_WINDOW"
	fi
	while IFS=$'\t' read -r labels count; do
		[[ -n "$labels" ]] || continue
		reason="$(label reason "$labels")"
		warn "Loki menolak ${count%.*} log ($reason) dalam 1 jam terakhir"
		case "$reason" in
		rate_limited | per_stream_rate_limit) hint "Naikkan LOKI_INGESTION_RATE_MB / LOKI_PER_STREAM_RATE_MB, atau kurangi log dengan --log-drop" ;;
		greater_than_max_sample_age) hint "Backlog lebih tua dari LOKI_MAX_LOG_AGE" ;;
		esac
	done <<<"$(prom 'sum by (reason) (increase(loki_discarded_samples_total{job="plg-loki"}[1h])) > 0')"
	flushes="$(prom 'sum(increase(loki_ingester_chunks_flush_failures_total{job="plg-loki"}[1h])) > 0')"
	if [[ -n "$flushes" ]]; then
		fail "Loki gagal menyimpan sebagian log ke storage dalam 1 jam terakhir"
		hint "Lihat penyebabnya: docker logs --tail 50 $(docker inspect -f '{{.Name}}' "$(container loki)" | tr -d /); untuk S3 cek LOKI_S3_* dan akses ke bucket"
	fi
	usage="$(prom '100 * (prometheus_tsdb_storage_blocks_bytes + prometheus_tsdb_wal_storage_size_bytes) / (prometheus_tsdb_retention_limit_bytes > 0)')"
	usage="$(value "$usage" | cut -d. -f1)"
	if [[ -n "$usage" ]] && ((usage >= $(threshold metrics_disk warning))); then
		warn "Data metrik memakai ${usage}% dari PROMETHEUS_RETENTION_SIZE; data tertua akan dihapus lebih awal dari PROMETHEUS_RETENTION"
	fi

	if [[ -n "$FOCUS" ]]; then
		section "Server $FOCUS"
		if [[ "$FOCUS" == "$SELF_NAME" || ",$TOKENS," == *",$FOCUS:"* || " $TOKENS " == *" $FOCUS:"* ]]; then
			ok "Token terdaftar"
		else
			fail "Tidak ada token untuk '$FOCUS'"
			hint "scripts/agent-token.sh add $FOCUS"
		fi
		last="$(value "$(prom "time() - max(timestamp(up{job=\"node\", host=\"$FOCUS\"}) or max_over_time(timestamp(up{job=\"node\", host=\"$FOCUS\"})[7d:1m]))")")"
		if [[ -z "$last" ]]; then
			fail "Belum pernah mengirim metrik (7 hari terakhir)"
			hint "Di server itu: curl -u $FOCUS:TOKEN $ingest/ping harus menjawab ok; lalu jalankan ulang installer agent"
		elif ((${last%.*} > $(seconds "$silent"))); then
			fail "Metrik terakhir $(ago "$last") lalu"
		else
			ok "Metrik terakhir $(ago "$last") lalu"
		fi
		version="$(prom "max by (version) (alloy_build_info{job=\"alloy\", host=\"$FOCUS\"})")"
		[[ -z "$version" ]] || ok "Agent Alloy $(label version "$version")"
		logs="$(value "$(loki "sum(count_over_time({host=\"$FOCUS\"}[15m]))")")"
		if [[ -n "$logs" ]]; then
			ok "${logs%.*} baris log dalam 15 menit terakhir"
		else
			warn "Tidak ada log dalam 15 menit terakhir"
		fi
		lag="$(value "$(prom "max(prometheus_remote_storage_highest_timestamp_in_seconds{job=\"alloy\", host=\"$FOCUS\"}) - max(prometheus_remote_storage_queue_highest_sent_timestamp_seconds{job=\"alloy\", host=\"$FOCUS\"} > 0)")")"
		if [[ -n "$lag" ]] && ((${lag%.*} > $(seconds "$(threshold agent_lag warning)"))); then
			warn "Tertinggal mengirim $(ago "$lag")"
		elif [[ -n "$lag" ]]; then
			ok "Pengiriman lancar"
		fi
	fi
fi

# --- backup ---------------------------------------------------------------------------------

if ((LOCAL)) && [[ "$PROFILES" == *,backup,* ]]; then
	section "Backup"
	id="$(container backup)"
	status="$([[ -n "$id" ]] && docker exec "$id" cat /textfile/plg_backup.prom 2>/dev/null)"
	last="$(sed -n 's/^plg_backup_last_success_timestamp_seconds //p' <<<"$status")"
	if [[ -z "$status" ]]; then
		warn "Belum ada backup yang selesai"
		hint "Jalankan sekarang: docker exec $(docker inspect -f '{{.Name}}' "$id" | tr -d /) sh /backup/backup.sh run"
	elif [[ "$(sed -n 's/^plg_backup_last_status //p' <<<"$status")" != 1 ]]; then
		fail "Backup terakhir gagal${last:+; yang terakhir berhasil $(ago $(($(date +%s) - last))) lalu}"
		hint "Lihat penyebabnya: docker logs --tail 50 $(docker inspect -f '{{.Name}}' "$id" | tr -d /)"
	elif (($(date +%s) - last > $(seconds "$(threshold backup_age warning)"))); then
		warn "Backup terakhir berhasil $(ago $(($(date +%s) - last))) lalu"
	else
		ok "Backup terakhir berhasil $(ago $(($(date +%s) - last))) lalu"
	fi
fi

# --- disk -------------------------------------------------------------------------------------

if ((LOCAL)); then
	section "Disk"
	root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)"
	used="$(df -P "$root" 2>/dev/null | awk 'NR == 2 { sub("%", "", $5); print $5 }')"
	if [[ -z "$used" ]]; then
		warn "Pemakaian disk $root tidak bisa dibaca"
	elif ((used >= $(threshold disk critical))); then
		fail "Disk Docker ($root) terpakai ${used}%"
	elif ((used >= $(threshold disk warning))); then
		warn "Disk Docker ($root) terpakai ${used}%"
	else
		ok "Disk Docker ($root) terpakai ${used}%"
	fi
fi

printf '\n%s\n' "${BOLD}Ringkasan:${RESET} ${GREEN}$OK oke${RESET}, ${YELLOW}$WARN peringatan${RESET}, ${RED}$FAIL masalah${RESET}"
((FAIL == 0))
