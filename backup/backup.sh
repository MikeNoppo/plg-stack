#!/bin/sh
# Encrypted backups of the stack's volumes with restic, taken while the stack
# keeps running. Runs in the restic image (busybox sh).
#
#   backup.sh schedule        back up daily at BACKUP_SCHEDULE (HH:MM,..., in TZ)
#   backup.sh run             back up now
#   backup.sh snapshots       list backup runs
#   backup.sh check           verify the repository and 5% of its data
#   backup.sh restore [RUN]   replace the volumes with a run (default: latest)
#   backup.sh copy REPOSITORY copy the runs of another repository (e.g. /local)
set -eu
set -o pipefail

VOLUMES=/volumes
LOCAL=/local
STAGE=.plg-backup
TMP=/tmp/plg-backup
METRICS=/textfile/plg_backup.prom
ALL_TARGETS="grafana prometheus loki caddy"
LOKI_HISTORY=storage-history
HOST="${BACKUP_HOST:-plg-stack}"
TARGETS="$(printf '%s' "${BACKUP_TARGETS:-grafana,prometheus,loki,caddy}" | tr ',' ' ')"

log() { printf 'backup: %s\n' "$*" >&2; }
die() {
	log "$*"
	exit 1
}

idle() {
	while :; do sleep 3600; done
}

repository() { printf '%s' "${1:-${RESTIC_REPOSITORY:-}}" | sed 's#//[^/@]*@#//***@#'; }

# Waits for another restic process (a manual check, a long prune) instead of
# failing at once.
restic() { command restic --retry-lock 5m "$@"; }

require_config() {
	[ -n "${RESTIC_REPOSITORY:-}" ] && [ -n "${RESTIC_PASSWORD:-}" ] ||
		die "BACKUP_REPOSITORY dan BACKUP_PASSWORD harus diisi"
}

# A new repository takes the chunker parameters of the one its backups come
# from (the copy source, or /local after BACKUP_REPOSITORY moved away from it),
# so the data both hold is stored once.
create_repository() {
	from="${RESTIC_FROM_REPOSITORY:-}"
	if [ -z "$from" ] && [ "$RESTIC_REPOSITORY" != "$LOCAL" ] && [ -f "$LOCAL/config" ]; then
		from="$LOCAL"
	fi
	if [ -n "$from" ] && (
		export RESTIC_FROM_REPOSITORY="$from" RESTIC_FROM_PASSWORD="${RESTIC_FROM_PASSWORD:-$RESTIC_PASSWORD}"
		restic init --copy-chunker-params >/dev/null 2>"$TMP/error"
	); then
		return 0
	fi
	[ -z "$from" ] || log "parameter chunk $(repository "$from") tidak bisa dibaca, jadi tidak dipakai"
	restic init >/dev/null
}

open_repository() {
	# Clears locks left by a restic process that was killed; locks of running
	# processes stay.
	restic unlock >/dev/null 2>&1 || true
	code=0
	restic cat config >/dev/null 2>"$TMP/error" || code=$?
	case "$code" in
	0) ;;
	10)
		if [ "${1:-}" != create ]; then
			log "belum ada backup di $(repository)"
			return 1
		fi
		log "repository belum ada, membuat baru di $(repository)"
		create_repository
		;;
	11)
		log "repository $(repository) masih dikunci proses restic lain; lock dari proses yang mati dilepas otomatis"
		return 1
		;;
	12)
		log "BACKUP_PASSWORD tidak cocok dengan repository $(repository)"
		return 1
		;;
	*)
		cat "$TMP/error" >&2
		log "repository $(repository) tidak bisa dibuka (kode $code)"
		return 1
		;;
	esac
}

# The archive's top entry becomes the volume's root on restore, so it needs
# the owner and mode of the original root or the service cannot write there.
make_root() {
	mkdir -p "$2"
	chown "$(stat -c %u:%g "$1")" "$2"
	chmod "$(stat -c %a "$1")" "$2"
}

# Hard links freeze the current files without copying them. Prometheus and
# Loki only append to files or delete them, never rewrite them, so a link
# keeps a usable copy even if the original is deleted during the backup.
link_names() {
	src="$1"
	out="$2"
	shift 2
	for name in "$@"; do
		[ -e "$src/$name" ] || continue
		cp -al "$src/$name" "$out/$name" 2>/dev/null || return 1
	done
}

# Runs a link_* function into a fresh staging directory. A file deleted while
# linking makes cp fail, and the whole tree is linked again.
stage_links() {
	src="$VOLUMES/$1"
	out="$src/$STAGE"
	attempt=1
	while :; do
		rm -rf "$out"
		make_root "$src" "$out"
		if "link_$1" "$src" "$out"; then
			echo "$out"
			return 0
		fi
		[ "$attempt" -ge 5 ] && return 1
		attempt=$((attempt + 1))
		sleep 2
	done
}

# The WAL (and the out-of-order WAL) goes first and the finished blocks are
# listed only afterwards: data Prometheus moves from the WAL into a new block
# meanwhile is then in one of the two. Blocks being written or deleted have
# temporary names, not ULIDs. Prometheus replays the WAL on start.
link_prometheus() {
	link_names "$1" "$2" wal wbl &&
		# shellcheck disable=SC2046
		link_names "$1" "$2" $(ls "$1" | grep -E '^[0-9A-Z]{26}$')
}

# Chunks go last: Loki stores a chunk before indexing it, so every chunk the
# linked index refers to is linked too.
link_loki() {
	# shellcheck disable=SC2046
	link_names "$1" "$2" $(ls "$1" | grep -vE "^$STAGE\$|cache|^chunks\$") &&
		link_names "$1" "$2" chunks
}

stage_prometheus() { stage_links prometheus; }

stage_loki() {
	# Writes the chunks Loki still holds in memory; anything newer is in the WAL.
	wget -q -T 60 -O /dev/null --post-data '' http://loki:3100/flush 2>/dev/null ||
		log "Loki tidak bisa diminta flush; log terbaru diambil dari WAL"
	stage_links loki
}

# grafana.db is rewritten in place, so it is copied; a copy taken while a
# transaction is open would be torn. The copy is kept only if the file did not
# change while it was read and no rollback journal existed.
stage_grafana() {
	if [ "${GRAFANA_DB_TYPE:-sqlite3}" != sqlite3 ]; then
		log "Grafana memakai database $GRAFANA_DB_TYPE; backup database itu terpisah"
		return 2
	fi
	db="$VOLUMES/grafana/grafana.db"
	[ -f "$db" ] || return 2
	make_root "$VOLUMES/grafana" "$TMP/grafana"
	attempt=1
	while [ "$attempt" -le 10 ]; do
		if [ ! -e "$db-journal" ]; then
			before="$(sha256sum <"$db")"
			cp -p "$db" "$TMP/grafana/grafana.db"
			if [ ! -e "$db-journal" ] && [ "$before" = "$(sha256sum <"$db")" ] &&
				[ "$before" = "$(sha256sum <"$TMP/grafana/grafana.db")" ]; then
				echo "$TMP/grafana"
				return 0
			fi
		fi
		attempt=$((attempt + 1))
		sleep 1
	done
	log "grafana.db terus berubah selama disalin"
	return 1
}

stage_caddy() { echo "$VOLUMES/caddy"; }

cleanup() {
	rm -rf "$VOLUMES/prometheus/$STAGE" "$VOLUMES/loki/$STAGE" "$TMP/grafana"
}

notify() {
	[ -n "$1" ] || return 0
	wget -q -T 10 -O /dev/null "$1" 2>/dev/null || log "gagal memanggil URL notifikasi"
}

write_metrics() {
	status="$1"
	[ -d "${METRICS%/*}" ] && [ -w "${METRICS%/*}" ] || return 0
	now="$(date +%s)"
	last_success="$(sed -n 's/^plg_backup_last_success_timestamp_seconds //p' "$METRICS" 2>/dev/null || true)"
	[ "$status" = 1 ] && last_success="$now"
	{
		echo "# HELP plg_backup_last_status 1 if the last backup run succeeded."
		echo "# TYPE plg_backup_last_status gauge"
		echo "plg_backup_last_status $status"
		echo "plg_backup_last_run_timestamp_seconds $now"
		[ -z "$last_success" ] || echo "plg_backup_last_success_timestamp_seconds $last_success"
		echo "plg_backup_last_duration_seconds $((now - STARTED))"
		[ -z "${RUNS:-}" ] || echo "plg_backup_runs $RUNS"
		while read -r target processed added; do
			echo "plg_backup_processed_bytes{target=\"$target\"} $processed"
			echo "plg_backup_added_bytes{target=\"$target\"} $added"
		done <"$TMP/sizes"
	} >"$METRICS.tmp"
	mv "$METRICS.tmp" "$METRICS"
}

take_lock() {
	exec 9>"$TMP/lock"
	flock -n 9 && return 0
	[ "${1:-}" = wait ] || die "backup lain sedang berjalan"
	log "menunggu backup atau copy lain selesai"
	flock 9
}

run_backup() {
	require_config
	mkdir -p "$TMP"
	take_lock "${1:-}"
	STARTED="$(date +%s)"
	RUN="$(date +%Y%m%d-%H%M%S)"
	: >"$TMP/sizes"
	trap cleanup EXIT
	cleanup
	if ! open_repository create; then
		finish_run " repository"
		return 1
	fi

	failed=""
	for target in $TARGETS; do
		case " $ALL_TARGETS " in
		*" $target "*) ;;
		*)
			log "target tidak dikenal di BACKUP_TARGETS: $target"
			failed="$failed $target"
			continue
			;;
		esac
		code=0
		dir="$("stage_$target")" || code=$?
		[ "$code" = 2 ] && continue
		if [ "$code" != 0 ] || ! restic backup --json --host "$HOST" --tag "plg-stack,$target,run-$RUN" \
			--stdin-filename "$target.tar" --stdin-from-command -- tar -C "$dir" -cf - . >"$TMP/$target.json" 2>"$TMP/error"; then
			cat "$TMP/error" >&2
			log "$target GAGAL"
			failed="$failed $target"
			continue
		fi
		jq -r --arg t "$target" 'select(.message_type == "summary")
			| "\($t) \(.total_bytes_processed) \(.data_added_packed // .data_added)"' "$TMP/$target.json" >>"$TMP/sizes"
		log "$target selesai ($(awk -v t="$target" '$1 == t { printf "%.1f MB dibaca, %.1f MB baru", $2 / 1e6, $3 / 1e6 }' "$TMP/sizes"))"
	done
	cleanup

	if ! restic forget --host "$HOST" --tag plg-stack --prune --keep-daily "${BACKUP_KEEP_DAILY:-7}" \
		--keep-weekly "${BACKUP_KEEP_WEEKLY:-4}" --keep-monthly "${BACKUP_KEEP_MONTHLY:-6}" >"$TMP/forget" 2>&1; then
		cat "$TMP/forget" >&2
		failed="$failed retensi"
	fi
	RUNS="$(restic snapshots --host "$HOST" --tag plg-stack --json 2>/dev/null |
		jq '[.[].tags[] | select(startswith("run-"))] | unique | length' || true)"
	finish_run "$failed"
}

# Records the outcome where the dashboard and the ping URLs see it.
finish_run() {
	if [ -z "$1" ]; then
		write_metrics 1
		notify "${BACKUP_PING_URL:-}"
		log "backup $RUN selesai dalam $(($(date +%s) - STARTED)) detik"
		return 0
	fi
	write_metrics 0
	notify "${BACKUP_FAIL_URL:-}"
	log "backup $RUN gagal:$1"
	return 1
}

schedule() {
	if [ -z "${RESTIC_REPOSITORY:-}" ] || [ -z "${RESTIC_PASSWORD:-}" ]; then
		log "BACKUP_REPOSITORY / BACKUP_PASSWORD kosong; backup terjadwal tidak berjalan"
		idle
	fi
	times="$(printf '%s' "${BACKUP_SCHEDULE:-02:00}" | tr ',' ' ')"
	if [ "$times" = off ]; then
		log "BACKUP_SCHEDULE=off; backup hanya dijalankan manual: sh /backup/backup.sh run"
		idle
	fi
	for at in $times; do
		if ! printf '%s' "$at" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
			log "BACKUP_SCHEDULE tidak valid: '$at' (format HH:MM, pisahkan dengan koma)"
			idle
		fi
	done
	log "backup harian pukul ${BACKUP_SCHEDULE:-02:00} (${TZ:-UTC}) ke $(repository)"
	while :; do
		now="$(date +%s)"
		sleep $(($(next_run "$now" $times) - now))
		# Waits for a manual backup or a long copy instead of skipping the day.
		(run_backup wait) || true
	done
}

# Next of the daily HH:MM times after NOW (epoch seconds), in local time.
next_run() {
	now="$1"
	shift
	next=""
	for at in "$@"; do
		when="$(date -d "$(date -d "@$now" +%Y-%m-%d) $at" +%s)"
		[ "$when" -gt "$now" ] || when=$((when + 86400))
		if [ -z "$next" ] || [ "$when" -lt "$next" ]; then next="$when"; fi
	done
	echo "$next"
}

list_runs() {
	require_config
	open_repository || exit 1
	printf '%-17s %10s  %s\n' RUN UKURAN KOMPONEN
	restic snapshots --host "$HOST" --tag plg-stack --json | jq -r '
		map({run: ((.tags // [])[] | select(startswith("run-")) | ltrimstr("run-")),
		     size: (.summary.total_bytes_processed // 0),
		     target: (((.tags // []) - ["plg-stack"]) | map(select(startswith("run-") | not)) | first)})
		| group_by(.run) | .[]
		| "\(.[0].run) \(map(.size) | add) \(map(.target) | sort | join(","))"' |
		while read -r run size targets; do
			printf '%-17s %7s MB  %s\n' "$run" "$((size / 1000000))" "$targets"
		done
}

# Loki reads each day from the store its storage history names (loki/init.sh),
# and the bucket keeps what Loki stored after the backup. So a restored
# history that is an earlier version of the current one gives way to it; one
# from another deployment (e.g. the old server) is kept.
keep_loki_history() {
	if [ ! -f "$2" ] || [ "$(head -n "$(wc -l <"$2")" "$1")" = "$(cat "$2")" ]; then
		cp "$1" "$2"
	else
		log "riwayat penyimpanan Loki dari backup dipakai, karena bukan versi lama dari riwayat sekarang"
	fi
}

restore() {
	require_config
	open_repository || exit 1
	run="${1:-latest}"
	filter=plg-stack
	[ "$run" = latest ] || filter="plg-stack,run-$run"
	restored=0
	for target in $ALL_TARGETS; do
		[ -d "$VOLUMES/$target" ] || continue
		count="$(restic snapshots --host "$HOST" --tag "$filter,$target" --json | jq length)"
		if [ "$count" = 0 ]; then
			log "tidak ada backup $target untuk $run, dilewati"
			continue
		fi
		log "memulihkan $target"
		rm -f "$TMP/loki-history"
		[ "$target" != loki ] || [ ! -f "$VOLUMES/loki/$LOKI_HISTORY" ] || cp "$VOLUMES/loki/$LOKI_HISTORY" "$TMP/loki-history"
		find "$VOLUMES/$target" -mindepth 1 -delete
		restic dump --host "$HOST" --tag "$filter,$target" latest "/$target.tar" | tar -x -C "$VOLUMES/$target"
		[ ! -f "$TMP/loki-history" ] || keep_loki_history "$TMP/loki-history" "$VOLUMES/loki/$LOKI_HISTORY"
		restored=$((restored + 1))
	done
	[ "$restored" -gt 0 ] || die "tidak ada backup yang cocok dengan '$run' (host $HOST)"
	log "$restored komponen dipulihkan dari $run"
}

# Runs copied before are skipped, so a copy can be run again.
copy_runs() {
	require_config
	from="${1:-}"
	[ -n "$from" ] || die "sebutkan repository asal, mis.: sh /backup/backup.sh copy /local"
	[ "$from" != "$RESTIC_REPOSITORY" ] || die "repository asal sama dengan BACKUP_REPOSITORY"
	export RESTIC_FROM_REPOSITORY="$from" RESTIC_FROM_PASSWORD="${RESTIC_FROM_PASSWORD:-$RESTIC_PASSWORD}"
	take_lock
	source="$(repository "$from")"
	code=0
	# --json keeps restic's notice about waiting for a lock out of the config.
	source_config="$(
		export RESTIC_REPOSITORY="$from" RESTIC_PASSWORD="$RESTIC_FROM_PASSWORD"
		restic unlock >/dev/null 2>&1 || true
		restic --json cat config 2>"$TMP/error"
	)" || code=$?
	case "$code" in
	0) ;;
	10) die "repository asal $source tidak ditemukan" ;;
	11) die "repository asal $source masih dikunci proses restic lain" ;;
	12) die "password repository asal $source tidak cocok; isi RESTIC_FROM_PASSWORD bila berbeda dari BACKUP_PASSWORD" ;;
	*)
		cat "$TMP/error" >&2
		die "repository asal $source tidak bisa dibuka (kode $code)"
		;;
	esac
	open_repository create || exit 1
	[ "$(restic --json cat config | jq -r .chunker_polynomial)" = "$(printf '%s' "$source_config" | jq -r .chunker_polynomial)" ] ||
		log "$(repository) sudah dipakai sebelum copy, jadi data yang sama di backup lama dan baru tersimpan dua kali sampai backup lama terhapus retensi"
	restic copy --tag plg-stack
	log "semua backup dari $source sudah ada di $(repository)"
}

[ -z "${PLG_BACKUP_SOURCE_ONLY:-}" ] || return 0
mkdir -p "$TMP"
case "${1:-schedule}" in
schedule) schedule ;;
run) run_backup ;;
snapshots) list_runs ;;
check)
	require_config
	restic check --read-data-subset=5%
	;;
restore) restore "${2:-latest}" ;;
copy) copy_runs "${2:-}" ;;
*) die "perintah tidak dikenal: $1 (schedule, run, snapshots, check, restore, copy)" ;;
esac
