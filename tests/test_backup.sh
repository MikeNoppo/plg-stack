#!/usr/bin/env bash
# Tests for backup/backup.sh (with a fake restic) and the scripts that drive
# it from the host (with a fake docker).
source "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PLG_BACKUP_SOURCE_ONLY=1 source "$ROOT/backup/backup.sh"
set +eu +o pipefail
VOLUMES="$WORK/volumes"
TMP="$WORK/tmp"
METRICS="$WORK/textfile/plg_backup.prom"
mkdir -p "$TMP" "$WORK/textfile"
sleep() { :; }
wget() { printf '%s\n' "$*" >>"$WORK/wget.log"; }

# --- schedule -------------------------------------------------------------------

export TZ=UTC
at() { date -d "$1" +%s; }
assert_eq "$(at '2026-10-08 02:00')" "$(next_run "$(at '2026-10-08 01:00')" 02:00)" "the next run is later today"
assert_eq "$(at '2026-10-08 14:00')" "$(next_run "$(at '2026-10-08 03:00')" 02:00 14:00)" "the nearest of several times wins"
assert_eq "$(at '2026-10-09 02:00')" "$(next_run "$(at '2026-10-08 15:00')" 02:00 14:00)" "after the last time it rolls over to tomorrow"
assert_eq "$(at '2026-10-09 02:00')" "$(next_run "$(at '2026-10-08 02:00')" 02:00)" "a run never repeats at the same minute"

# --- staging --------------------------------------------------------------------

block=01J9ZK3Q4R5S6T7V8W9X0Y1Z2A
prom="$VOLUMES/prometheus"
mkdir -p "$prom/$block/chunks" "$prom/$block.tmp-for-creation" "$prom/wal/checkpoint.00000001" "$prom/chunks_head"
chmod 750 "$prom"
echo meta >"$prom/$block/meta.json"
echo samples >"$prom/wal/00000002"
echo old >"$prom/chunks_head/000001"
echo config >"$prom/prometheus.yml"

dir="$(stage_prometheus)"
assert_eq "$prom/.plg-backup" "$dir" "Prometheus is staged inside its own volume"
assert_ok "finished blocks are staged" test -f "$dir/$block/meta.json"
assert_ok "the WAL is staged" test -f "$dir/wal/00000002"
assert_fails "blocks still being written are skipped" test -e "$dir/$block.tmp-for-creation"
assert_fails "the rendered config is not backed up" test -e "$dir/prometheus.yml"
assert_eq "$(stat -c %i "$prom/$block/meta.json")" "$(stat -c %i "$dir/$block/meta.json")" "staged files are hard links, not copies"
assert_eq "$(stat -c '%u:%g %a' "$prom")" "$(stat -c '%u:%g %a' "$dir")" "the staged root keeps the volume root's owner and mode"

# Compaction that finishes while the WAL is linked moves data into a new block.
late=01J9ZK3Q4R5S6T7V8W9X0Y1Z2B
cp() {
	command cp "$@" || return
	if [[ "$*" == *"/prometheus/wal "* && ! -e "$prom/$late" ]]; then
		mkdir "$prom/$late" && echo meta >"$prom/$late/meta.json"
	fi
}
dir="$(stage_prometheus)"
unset -f cp
assert_ok "a block written while the WAL is linked is staged too" test -f "$dir/$late/meta.json"

loki="$VOLUMES/loki"
mkdir -p "$loki/chunks/fake" "$loki/wal" "$loki/tsdb-index" "$loki/tsdb-cache"
echo chunk >"$loki/chunks/fake/1"
echo "2024-01-01 filesystem" >"$loki/storage-history"
: >"$WORK/wget.log"
# A flush that finishes while the index is linked stores a new chunk.
cp() {
	command cp "$@" || return
	[[ "$*" == *"/loki/tsdb-index "* ]] && echo chunk >"$loki/chunks/fake/2"
	return 0
}
dir="$(stage_loki 2>/dev/null)"
unset -f cp
assert_ok "Loki chunks are staged" test -f "$dir/chunks/fake/1"
assert_ok "Loki's storage history is staged" test -f "$dir/storage-history"
assert_ok "a chunk stored while the index is linked is staged too" test -f "$dir/chunks/fake/2"
assert_fails "Loki caches are skipped" test -e "$dir/tsdb-cache"
assert_contains "$(cat "$WORK/wget.log")" "http://loki:3100/flush" "Loki is asked to flush first"

mkdir -p "$VOLUMES/grafana"
chmod 770 "$VOLUMES/grafana"
echo db >"$VOLUMES/grafana/grafana.db"
dir="$(stage_grafana)"
assert_eq db "$(cat "$dir/grafana.db")" "grafana.db is copied"
assert_eq 770 "$(stat -c %a "$dir")" "the Grafana archive root keeps the volume root's mode"
touch "$VOLUMES/grafana/grafana.db-journal"
stage_grafana >/dev/null 2>&1
assert_eq 1 "$?" "a database with an open transaction is not copied"
rm "$VOLUMES/grafana/grafana.db-journal"
GRAFANA_DB_TYPE=postgres
stage_grafana >/dev/null 2>&1
assert_eq 2 "$?" "an external Grafana database is skipped"
GRAFANA_DB_TYPE=sqlite3
mkdir -p "$VOLUMES/caddy"
echo cert >"$VOLUMES/caddy/cert.pem"

# --- run ------------------------------------------------------------------------

restic() {
	printf '%s\n' "$*" >>"$WORK/restic.log"
	case "$1" in
	backup)
		local target=""
		while [[ "$1" != -- ]]; do
			[[ "$1" == --stdin-filename ]] && target="${2%.tar}"
			shift
		done
		shift
		"$@" >"$WORK/$target.tar" || return 1
		[[ " ${FAIL_TARGETS:-} " == *" $target "* ]] && return 1
		echo '{"message_type":"status"}'
		echo '{"message_type":"summary","total_bytes_processed":3000000,"data_added":900,"data_added_packed":400}'
		;;
	snapshots) echo '[{"tags":["plg-stack","grafana","run-a"]},{"tags":["plg-stack","caddy","run-a"]},{"tags":["plg-stack","grafana","run-b"]}]' ;;
	esac
}

export RESTIC_REPOSITORY=/local RESTIC_PASSWORD=secret BACKUP_PING_URL=https://ping.example BACKUP_FAIL_URL=https://fail.example
HOST=test-host
TARGETS="grafana prometheus caddy"
: >"$WORK/restic.log" && : >"$WORK/wget.log"
(run_backup) 2>"$WORK/stderr"
assert_eq 0 "$?" "a backup run succeeds"
log="$(cat "$WORK/restic.log")"
assert_contains "$log" "backup --json --host test-host --tag plg-stack,prometheus,run-" "each target is a tagged snapshot"
assert_contains "$log" "--stdin-filename caddy.tar --stdin-from-command -- tar -C $VOLUMES/caddy -cf - ." "volumes are streamed as tar"
assert_contains "$log" "forget --host test-host --tag plg-stack --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6" "old backups are pruned"
assert_contains "$(tar -tf "$WORK/prometheus.tar")" "./$block/meta.json" "the Prometheus archive holds the staged blocks"
assert_fails "staging is removed afterwards" test -e "$prom/.plg-backup"
metrics="$(cat "$METRICS")"
assert_contains "$metrics" "plg_backup_last_status 1" "success is recorded"
assert_contains "$metrics" 'plg_backup_processed_bytes{target="prometheus"} 3000000' "bytes read are recorded"
assert_contains "$metrics" 'plg_backup_added_bytes{target="prometheus"} 400' "uploaded bytes are recorded"
assert_contains "$metrics" "plg_backup_runs 2" "kept backups are counted per run"
assert_contains "$(cat "$WORK/wget.log")" "https://ping.example" "the success URL is called"
success="$(sed -n 's/^plg_backup_last_success_timestamp_seconds //p' "$METRICS")"

: >"$WORK/wget.log"
FAIL_TARGETS=prometheus
(run_backup) 2>"$WORK/stderr"
assert_eq 1 "$?" "a failed target fails the run"
FAIL_TARGETS=""
assert_contains "$(cat "$METRICS")" "plg_backup_last_status 0" "failure is recorded"
assert_contains "$(cat "$METRICS")" "plg_backup_last_success_timestamp_seconds $success" "the last success survives a failure"
assert_contains "$(cat "$WORK/wget.log")" "https://fail.example" "the failure URL is called"
assert_contains "$(cat "$WORK/stderr")" "prometheus GAGAL" "the failed target is named"

restic() {
	printf '%s\n' "$*" >>"$WORK/restic.log"
	[[ "$1" == cat ]] && return 12
	return 0
}
: >"$WORK/wget.log"
(run_backup) 2>"$WORK/stderr"
assert_eq 1 "$?" "a repository that cannot be opened fails the run"
assert_contains "$(cat "$WORK/stderr")" "BACKUP_PASSWORD tidak cocok" "a wrong password is explained"
assert_contains "$(cat "$METRICS")" "plg_backup_last_status 0" "the failure is recorded for the dashboard"
assert_contains "$(cat "$WORK/wget.log")" "https://fail.example" "the failure URL is called"
restic() { [[ "$1" == cat ]] && return 11; return 0; }
(run_backup) 2>"$WORK/stderr"
assert_contains "$(cat "$WORK/stderr")" "masih dikunci" "a locked repository is explained"

# A repository that does not exist until restic init creates it.
restic() {
	printf '%s | from %s\n' "$*" "${RESTIC_FROM_REPOSITORY:-}" >>"$WORK/restic.log"
	case "$1" in
	cat) [[ -f "$WORK/created" ]] || return 10 ;;
	init)
		[[ "$*" == *--copy-chunker-params* && -n "${UNREADABLE_SOURCE:-}" ]] && return 12
		touch "$WORK/created"
		;;
	backup)
		while [[ "$1" != -- ]]; do shift; done
		shift
		"$@" >/dev/null
		echo '{"message_type":"summary","total_bytes_processed":1,"data_added":1}'
		;;
	snapshots) echo '[]' ;;
	esac
}
LOCAL="$WORK/local-repository"
mkdir -p "$LOCAL" && echo '{}' >"$LOCAL/config"
TARGETS="caddy"
export RESTIC_REPOSITORY=s3:https://s3.example.com/bucket/plg-stack
rm -f "$WORK/created" && : >"$WORK/restic.log"
(list_runs) >/dev/null 2>"$WORK/stderr"
assert_eq 1 "$?" "listing a missing repository fails"
assert_fails "and does not create it" grep -q "^init" "$WORK/restic.log"
assert_contains "$(cat "$WORK/stderr")" "belum ada backup di s3:https://s3.example.com/bucket/plg-stack" "the missing repository is named"
(run_backup) 2>/dev/null
assert_eq 0 "$?" "a backup creates a missing repository"
assert_contains "$(cat "$WORK/restic.log")" "init --copy-chunker-params | from $LOCAL" \
	"it takes /local's chunker parameters, so copying /local in later stores shared data once"
rm -f "$WORK/created" && : >"$WORK/restic.log"
(UNREADABLE_SOURCE=1 run_backup) 2>"$WORK/stderr"
assert_eq 0 "$?" "an unreadable /local does not stop the backup"
assert_ok "the repository is then created without its parameters" grep -qxF "init | from " "$WORK/restic.log"
assert_contains "$(cat "$WORK/stderr")" "parameter chunk $LOCAL tidak bisa dibaca" "and that is pointed out"
export RESTIC_REPOSITORY=/local
LOCAL=/local
TARGETS="grafana prometheus caddy"

restic() {
	printf '%s\n' "$*" >>"$WORK/restic.log"
	case "$1" in
	backup)
		while [[ "$1" != -- ]]; do shift; done
		shift
		"$@" >/dev/null
		echo '{"message_type":"summary","total_bytes_processed":1,"data_added":1}'
		;;
	snapshots) echo '[]' ;;
	esac
}

TARGETS="grafana typo"
(run_backup) 2>"$WORK/stderr"
assert_eq 1 "$?" "unknown targets fail the run"
TARGETS="grafana prometheus caddy"

exec 8>"$TMP/lock"
flock -n 8
(run_backup) 2>"$WORK/stderr"
assert_eq 1 "$?" "a second run does not start while one is running"
assert_contains "$(cat "$WORK/stderr")" "backup lain sedang berjalan" "the overlap is explained"
# The background run must not inherit fd 8, which holds the lock.
(exec 8>&-; run_backup wait) 2>"$WORK/stderr" &
for _ in $(seq 50); do
	grep -q menunggu "$WORK/stderr" && break
	command sleep 0.1
done
assert_ok "a scheduled run waits instead of skipping the day" kill -0 $!
exec 8>&-
wait $!
assert_eq 0 "$?" "and backs up once the other run is done"

# --- restore --------------------------------------------------------------------

mkdir -p "$WORK/archive" && echo restored >"$WORK/archive/grafana.db"
tar -C "$WORK/archive" -cf "$WORK/grafana-dump.tar" .
restic() {
	printf '%s\n' "$*" >>"$WORK/restic.log"
	case "$1 $*" in
	snapshots*",grafana "*) echo '[{}]' ;;
	snapshots*) echo '[]' ;;
	dump*) cat "$WORK/grafana-dump.tar" ;;
	esac
}
echo stale >"$VOLUMES/grafana/stale"
: >"$WORK/restic.log"
(restore 20261008-020000) 2>"$WORK/stderr"
assert_eq 0 "$?" "a run is restored"
assert_eq restored "$(cat "$VOLUMES/grafana/grafana.db")" "the volume holds the backup"
assert_fails "old files are removed first" test -e "$VOLUMES/grafana/stale"
assert_ok "volumes without a backup are left alone" test -f "$VOLUMES/caddy/cert.pem"
assert_contains "$(cat "$WORK/restic.log")" "dump --host test-host --tag plg-stack,run-20261008-020000,grafana latest /grafana.tar" "the run is selected by tag"
restic() { echo '[]'; }
(restore 19990101-000000) 2>/dev/null
assert_eq 1 "$?" "an unknown run fails"

# Restores of Loki, whose volume carries the storage history of loki/init.sh.
restic() {
	case "$1" in
	snapshots) echo '[{}]' ;;
	dump) cat "$WORK/loki-dump.tar" ;;
	esac
}
loki_backup() {
	rm -rf "$WORK/loki-archive" && mkdir -p "$WORK/loki-archive/chunks"
	echo restored >"$WORK/loki-archive/chunks/old"
	[[ -z "$1" ]] || printf '%s\n' "$@" >"$WORK/loki-archive/storage-history"
	tar -C "$WORK/loki-archive" -cf "$WORK/loki-dump.tar" .
}
restore_loki() {
	printf '%s\n' "$@" >"$loki/storage-history"
	rm -rf "$VOLUMES/caddy" && mkdir "$VOLUMES/caddy"
	(set -e; restore 20261008-020000) 2>"$WORK/stderr"
	echo "$?" >"$WORK/restore-status"
	paste -sd, - <"$loki/storage-history"
}
loki_backup "2024-01-01 filesystem"
assert_eq "2024-01-01 filesystem,2026-10-09 s3" "$(restore_loki "2024-01-01 filesystem" "2026-10-09 s3")" \
	"an older history gives way to the current one, which also names the stores of newer logs"
assert_eq restored "$(cat "$loki/chunks/old")" "Loki's volume is restored while Loki uses S3"
assert_eq 0 "$(cat "$WORK/restore-status")" "the restore goes on after Loki"
assert_ok "and restores the volumes after it" test -f "$VOLUMES/caddy/chunks/old"
loki_backup ""
assert_eq "2024-01-01 s3" "$(restore_loki "2024-01-01 s3")" "a backup without a history keeps the current one"
loki_backup "2024-01-01 filesystem" "2026-10-01 s3"
assert_eq "2024-01-01 filesystem,2026-10-01 s3" "$(restore_loki "2024-01-01 s3")" \
	"the history of another deployment (a moved stack) comes with its logs"
assert_contains "$(cat "$WORK/stderr")" "riwayat penyimpanan Loki dari backup dipakai" "the replaced history is pointed out"
assert_eq 0 "$(cat "$WORK/restore-status")" "a replaced history does not stop the restore"

# --- copy -----------------------------------------------------------------------

# The source is /local; the destination exists once dest-config does.
restic() {
	printf '%s | from %s:%s\n' "$*" "${RESTIC_FROM_REPOSITORY:-}" "${RESTIC_FROM_PASSWORD:-}" >>"$WORK/restic.log"
	case "$1" in
	cat)
		if [[ "$RESTIC_REPOSITORY" == /local ]]; then
			[[ "$RESTIC_PASSWORD" == secret ]] || return 12
			echo '{"chunker_polynomial":"abc"}'
		else
			cat "$WORK/dest-config" 2>/dev/null || return 10
		fi
		;;
	init) echo '{"chunker_polynomial":"abc"}' >"$WORK/dest-config" ;;
	esac
}
export RESTIC_REPOSITORY=s3:https://s3.example.com/bucket/plg-stack
: >"$WORK/restic.log"
(copy_runs /local) >/dev/null 2>"$WORK/stderr"
assert_eq 0 "$?" "backups are copied from another repository"
log="$(cat "$WORK/restic.log")"
assert_contains "$log" "init --copy-chunker-params | from /local:secret" "a new repository takes the source's chunker parameters"
assert_contains "$log" "copy --tag plg-stack | from /local:secret" "every run is copied, with BACKUP_PASSWORD for the source by default"
assert_fails "matching chunker parameters need no warning" grep -q "dua kali" "$WORK/stderr"

echo '{"chunker_polynomial":"def"}' >"$WORK/dest-config"
: >"$WORK/restic.log"
(copy_runs /local) >/dev/null 2>"$WORK/stderr"
assert_contains "$(cat "$WORK/stderr")" "tersimpan dua kali" "a repository used before the copy is pointed out"
assert_fails "an existing repository is not created again" grep -q "^init" "$WORK/restic.log"

(RESTIC_FROM_PASSWORD=other copy_runs /local) >/dev/null 2>"$WORK/stderr"
assert_eq 1 "$?" "a source that cannot be opened fails"
assert_contains "$(cat "$WORK/stderr")" "isi RESTIC_FROM_PASSWORD" "a different source password is explained"
(copy_runs) 2>/dev/null
assert_eq 1 "$?" "the source is required"
(copy_runs "$RESTIC_REPOSITORY") 2>/dev/null
assert_eq 1 "$?" "a repository is not copied into itself"
exec 8>"$TMP/lock"
flock -n 8
(copy_runs /local) 2>"$WORK/stderr"
assert_contains "$(cat "$WORK/stderr")" "backup lain sedang berjalan" "a copy does not overlap a running backup"
exec 8>&-
export RESTIC_REPOSITORY=/local

# --- host scripts ---------------------------------------------------------------

mkdir -p "$WORK/bin" "$WORK/checkout/scripts"
cat >"$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
case "$1 $2" in
"ps -q") printf '%s' "${FAKE_CONTAINERS:-}" | tr ' ' '\n' | sed '/^$/d' ;;
"compose config"|"compose -p") printf '{\n  "name": "plg-stack",\n  "services": {}\n}\n' ;;
esac
EOF
chmod +x "$WORK/bin/docker"
export FAKE_DOCKER_LOG="$WORK/docker.log"
host_run() { PATH="$WORK/bin:$PATH" bash "$@"; }

cp "$ROOT/scripts/restore.sh" "$WORK/checkout/scripts/"
printf "BACKUP_REPOSITORY='/local'\n" >"$WORK/checkout/.env"
host_run "$WORK/checkout/scripts/restore.sh" --yes 2>"$WORK/stderr"
assert_eq 1 "$?" "restore.sh needs the backup password"
printf "BACKUP_PASSWORD='secret'\n" >>"$WORK/checkout/.env"
FAKE_CONTAINERS="running" host_run "$WORK/checkout/scripts/restore.sh" --yes 2>"$WORK/stderr"
assert_contains "$(cat "$WORK/stderr")" "masih berjalan" "restore.sh refuses while the stack runs"
: >"$FAKE_DOCKER_LOG"
FAKE_CONTAINERS="" host_run "$WORK/checkout/scripts/restore.sh" --yes 20261008-020000 >/dev/null
log="$(cat "$FAKE_DOCKER_LOG")"
assert_contains "$log" "compose --profile backup run --rm --no-deps backup restore 20261008-020000" "the chosen run is restored"
assert_contains "$log" "compose up -d" "the stack is started afterwards"
: >"$FAKE_DOCKER_LOG"
FAKE_CONTAINERS="" host_run "$WORK/checkout/scripts/restore.sh" --yes --no-start >/dev/null
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "backup restore latest" "the latest backup is the default"
assert_fails "--no-start leaves the stack stopped" grep -q "up -d" "$FAKE_DOCKER_LOG"
FAKE_CONTAINERS="" host_run "$WORK/checkout/scripts/restore.sh" <<<"n" >/dev/null 2>&1
assert_eq 1 "$?" "restore.sh stops unless confirmed"

finish
