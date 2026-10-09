#!/usr/bin/env bash
# Tests for loki/init.sh, which writes Loki's config before Loki starts.
source "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PLG_LOKI_INIT_SOURCE_ONLY=1 source "$ROOT/loki/init.sh"
set +eu
TEMPLATE="$ROOT/loki/loki.yaml.tmpl"
OUT="$WORK/loki.yaml"

# Every run happens at 2026-10-08 10:00 UTC.
NOW="$(date -u -d '2026-10-08 10:00' +%s)"
date() {
	case " $* " in
	*" -d "*) command date "$@" ;;
	*) command date -d "@$NOW" "$@" ;;
	esac
}

volume() {
	DATA="$WORK/volume-$1"
	mkdir -p "$DATA/rules"
}
periods() {
	sed -n '/^schema_config:/,$p' "$OUT" |
		awk '$2 == "from:" { from = $3 } $1 == "object_store:" { print from, $2 }' | paste -sd, -
}
history() { paste -sd, - <"$DATA/storage-history"; }
storage() { LOKI_STORAGE="$1" render 2>"$WORK/stderr"; }

assert_eq 2026-10-09 "$(switch_date "$(date -u -d '2026-10-08 10:00' +%s)")" "a switch starts at the next midnight (UTC)"
assert_eq 2026-10-10 "$(switch_date "$(date -u -d '2026-10-08 23:30' +%s)")" "a midnight less than an hour away is skipped"

volume fresh-filesystem
storage filesystem
assert_eq 0 "$?" "the config is written"
assert_eq "2024-01-01 filesystem" "$(periods)" "filesystem keeps every log on the local disk"
assert_eq "2024-01-01 filesystem" "$(history)" "the store is recorded"
assert_contains "$(cat "$OUT")" "delete_request_store: \${LOKI_STORAGE}" "the rest of the template is kept for Loki to expand"

volume fresh-s3
storage s3
assert_eq "2024-01-01 s3" "$(periods)" "s3 keeps every log in the bucket"
assert_eq "2024-01-01 s3" "$(history)" "an s3 start is recorded too, so the bucket's logs keep a period"

DATA="$WORK/unpopulated"
mkdir -p "$DATA"
storage s3
assert_eq "2024-01-01 s3" "$(periods)" "an unpopulated volume still gets a config"
assert_fails "nothing is written before Docker copied the image's /loki into the volume" test -e "$DATA/storage-history"

# --- switching ------------------------------------------------------------------

volume switch
storage filesystem
storage s3
assert_eq "2024-01-01 filesystem,2026-10-09 s3" "$(periods)" "logs before the switch stay readable from the local disk"
assert_contains "$(cat "$WORK/stderr")" "mulai 2026-10-09 00:00 UTC" "the switch is explained"
storage s3
assert_eq "2024-01-01 filesystem,2026-10-09 s3" "$(history)" "a redeploy keeps the switch date"
storage filesystem
assert_eq "2024-01-01 filesystem" "$(history)" "switching back before the switch cancels it"
assert_contains "$(cat "$WORK/stderr")" "dibatalkan" "the cancelled switch is explained"

echo "2024-01-01 filesystem
2026-10-01 s3" >"$DATA/storage-history"
storage filesystem
assert_eq "2024-01-01 filesystem,2026-10-01 s3,2026-10-09 filesystem" "$(periods)" \
	"going back to filesystem keeps the logs already stored in S3 readable"
storage s3
assert_eq "2024-01-01 filesystem,2026-10-01 s3" "$(history)" "and returning to s3 before the switch cancels it again"

volume bucket-first
storage s3
storage filesystem
mkdir -p "$DATA/chunks/index/delete_requests"
echo db >"$DATA/chunks/index/delete_requests/delete_requests.gz"
NOW="$(date -u -d '2026-10-20 10:00' +%s)"
storage s3
assert_eq "2024-01-01 s3,2026-10-09 filesystem,2026-10-21 s3" "$(periods)" \
	"local files written later never move the bucket's older logs to the local disk"
NOW="$(date -u -d '2026-10-08 10:00' +%s)"

volume legacy
mkdir -p "$DATA/chunks/fake/1a2b"
echo chunk >"$DATA/chunks/fake/1a2b/MTg5OjE5MDox"
storage s3
assert_eq "2024-01-01 filesystem,2026-10-09 s3" "$(periods)" "local logs without a history are taken as filesystem"

# --- failures -------------------------------------------------------------------

storage local
assert_eq 1 "$?" "an unknown storage fails"
assert_contains "$(cat "$WORK/stderr")" "LOKI_STORAGE harus filesystem atau s3" "the valid values are named"
assert_eq "2024-01-01 filesystem,2026-10-09 s3" "$(periods)" "a failed run leaves the last config"

echo "2026-10-09 S3" >>"$DATA/storage-history"
storage s3
assert_eq 1 "$?" "a damaged history fails instead of being guessed"
assert_contains "$(cat "$WORK/stderr")" "storage-history rusak" "the damaged history is named"

finish
