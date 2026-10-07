#!/usr/bin/env bash
# Tests for scripts/agent-token.sh against a throwaway checkout.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts"
cp "$ROOT/scripts/agent-token.sh" "$TMP/scripts/"
cat >"$TMP/.env" <<'EOF'
GATEWAY_SCHEME='http'
INGEST_DOMAIN='ingest.example.com'
GRAFANA_ADMIN_PASSWORD='keep-me'
EOF

run() { bash "$TMP/scripts/agent-token.sh" "$@"; }
tokens() { sed -n "s/^AGENT_TOKENS='\\(.*\\)'\$/\\1/p" "$TMP/.env"; }

out="$(run add db-01)"
assert_contains "$out" "--url https://ingest.example.com --name db-01 --token " "add prints the install command"
assert_contains "$out" "Mode Dokploy" "dokploy mode explains how to apply"
first="$(tokens)"
assert_contains "$first" "db-01:" "token is stored"

run add app-01 >/dev/null
assert_contains "$(tokens)" ",app-01:" "second token is appended"
assert_fails "adding an existing name fails" run add db-01 2>/dev/null

old_db="${first#db-01:}"
run rotate db-01 >/dev/null
assert_fails "rotate replaces the token" grep -q "db-01:$old_db" "$TMP/.env"

assert_contains "$(run list)" "app-01" "list shows names"
assert_fails "list hides full tokens" grep -q "$(tokens | sed 's/.*app-01://')" <<<"$(run list)"

run revoke db-01 >/dev/null
assert_fails "revoked token is gone" grep -q "db-01:" "$TMP/.env"
assert_contains "$(tokens)" "app-01:" "other tokens are kept"
assert_contains "$(cat "$TMP/.env")" "GRAFANA_ADMIN_PASSWORD='keep-me'" "other settings are kept"
assert_eq 1 "$(grep -c '^AGENT_TOKENS=' "$TMP/.env")" "AGENT_TOKENS appears once"

assert_fails "invalid names are rejected" run add "bad name" 2>/dev/null
assert_fails "revoking an unknown name fails" run revoke nobody 2>/dev/null

finish
