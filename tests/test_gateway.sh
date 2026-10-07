#!/usr/bin/env bash
# Tests for gateway/entrypoint.sh, which turns AGENT_TOKENS into Caddy matchers.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render() {
	env -i PATH="$PATH" AGENT_AUTH_FILE="$TMP/auth.caddy" "$@" sh "$ROOT/gateway/entrypoint.sh" --render-only 2>"$TMP/stderr"
	cat "$TMP/auth.caddy"
}

basic() { printf 'header Authorization "Basic %s"' "$(printf '%s' "$1" | base64 | tr -d '\n')"; }

out="$(render AGENT_TOKENS='db-01:abc,app-01:def')"
assert_contains "$out" "$(basic db-01:abc)" "first token becomes a matcher"
assert_contains "$out" "$(basic app-01:def)" "second token becomes a matcher"
assert_eq 2 "$(grep -c '^header Authorization' <<<"$out")" "one line per token"

out="$(render AGENT_TOKENS='a:1 b:2
c:3' SELF_MONITORING_NAME=plg-stack SELF_MONITORING_TOKEN=self)"
assert_eq 4 "$(grep -c '^header Authorization' <<<"$out")" "spaces/newlines separate tokens and the self agent is added"
assert_contains "$out" "$(basic plg-stack:self)" "self-monitoring token is accepted"

long_name="server-with-a-rather-long-name-for-testing"
out="$(render AGENT_TOKENS="$long_name:0123456789abcdef0123456789abcdef")"
assert_eq 1 "$(wc -l <<<"$out")" "long credentials are not wrapped"

out="$(render AGENT_TOKENS='b@d:x,nocolon,ok:tok,evil:"x"')"
assert_eq 1 "$(grep -c '^header Authorization' <<<"$out")" "invalid entries are skipped"
assert_contains "$(cat "$TMP/stderr")" "diabaikan" "skipped entries are reported"

out="$(render AGENT_TOKENS='')"
assert_eq 1 "$(grep -c '^header Authorization "Basic ' <<<"$out")" "no tokens still yields a non-empty matcher"
assert_contains "$(cat "$TMP/stderr")" "menolak semua agent" "missing tokens are reported"

finish
