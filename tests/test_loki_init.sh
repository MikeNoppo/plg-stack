#!/usr/bin/env bash
# Tests for loki/init.sh, which writes Loki's config before Loki starts.
source "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PLG_LOKI_INIT_SOURCE_ONLY=1 source "$ROOT/loki/init.sh"
set +eu
TEMPLATE="$ROOT/loki/loki.yaml.tmpl"
OUT="$WORK/loki.yaml"
DATA="$WORK/data"
mkdir -p "$DATA/chunks"

# "from store" for each period of the written config.
periods() {
	sed -n '/^schema_config:/,$p' "$OUT" |
		awk '$2 == "from:" { from = $3 } $1 == "object_store:" { print from, $2 }' | paste -sd, -
}

LOKI_STORAGE=filesystem render
assert_eq 0 "$?" "the config is written"
assert_eq "2024-01-01 filesystem" "$(periods)" "filesystem keeps every log on the local disk"
assert_contains "$(cat "$OUT")" "delete_request_store: \${LOKI_STORAGE}" "the rest of the template is kept for Loki to expand"

LOKI_STORAGE=s3 render
assert_eq "2024-01-01 s3" "$(periods)" "s3 keeps every log in the bucket"

assert_fails "an empty disk needs no switch date" test -e "$DATA/s3-since"

LOKI_STORAGE=local render 2>"$WORK/stderr"
assert_eq 1 "$?" "an unknown storage fails"
assert_contains "$(cat "$WORK/stderr")" "LOKI_STORAGE harus filesystem atau s3" "the valid values are named"
assert_eq "2024-01-01 s3" "$(periods)" "a failed run leaves the last config"

# --- moving from filesystem to s3 -------------------------------------------------

at() { date -u -d "$1" +%s; }
assert_eq 2026-10-09 "$(switch_date "$(at '2026-10-08 10:00')")" "S3 takes over at the next midnight (UTC)"
assert_eq 2026-10-10 "$(switch_date "$(at '2026-10-08 23:30')")" "a midnight less than an hour away is skipped"

mkdir -p "$DATA/chunks/fake/1a2b"
echo chunk >"$DATA/chunks/fake/1a2b/MTg5OjE5MDox"
LOKI_STORAGE=filesystem render
assert_fails "filesystem needs no switch date" test -e "$DATA/s3-since"

LOKI_STORAGE=s3 render 2>"$WORK/stderr"
since="$(cat "$DATA/s3-since")"
assert_eq "$(switch_date "$(date +%s)")" "$since" "the switch date is recorded"
assert_eq "2024-01-01 filesystem,$since s3" "$(periods)" "logs before the switch stay readable from the local disk"
assert_contains "$(cat "$WORK/stderr")" "log sebelum $since tetap di disk lokal" "the switch is explained"
assert_fails "the date is written atomically" test -e "$DATA/s3-since.tmp"

echo 2026-10-09 >"$DATA/s3-since"
rm -r "$DATA/chunks/fake"
LOKI_STORAGE=s3 render 2>/dev/null
assert_eq "2024-01-01 filesystem,2026-10-09 s3" "$(periods)" "the switch date stays after retention emptied the disk"

LOKI_STORAGE=filesystem render 2>"$WORK/stderr"
assert_eq "2024-01-01 filesystem" "$(periods)" "going back to filesystem drops the S3 period"
assert_fails "and forgets the switch date" test -e "$DATA/s3-since"
assert_contains "$(cat "$WORK/stderr")" "tidak terbaca lagi" "logs left on S3 are pointed out"

finish
