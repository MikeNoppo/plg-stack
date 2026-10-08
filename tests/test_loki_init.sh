#!/usr/bin/env bash
# Tests for loki/init.sh, which writes Loki's config before Loki starts.
source "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PLG_LOKI_INIT_SOURCE_ONLY=1 source "$ROOT/loki/init.sh"
set +eu
TEMPLATE="$ROOT/loki/loki.yaml.tmpl"
OUT="$WORK/loki.yaml"

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

LOKI_STORAGE=local render 2>"$WORK/stderr"
assert_eq 1 "$?" "an unknown storage fails"
assert_contains "$(cat "$WORK/stderr")" "LOKI_STORAGE harus filesystem atau s3" "the valid values are named"
assert_eq "2024-01-01 s3" "$(periods)" "a failed run leaves the last config"

finish
