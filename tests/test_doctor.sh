#!/usr/bin/env bash
# Tests for scripts/doctor.sh with fake curl, getent and docker (remote checks).
source "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/checkout/scripts" "$WORK/checkout/grafana/generator" "$WORK/bin"
cp "$ROOT/scripts/doctor.sh" "$WORK/checkout/scripts/"
cp "$ROOT/grafana/generator/config.toml" "$WORK/checkout/grafana/generator/"

cat >"$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do [[ "$arg" == https://* ]] && url="$arg"; done
code=404 body=""
case "$url" in
*/agent/install.sh) code=200 ;;
*/ping) [[ " $* " == *" -u "* ]] && code="${FAKE_PING_AUTH:-200}" || code=401 ;;
*/loki/api/v1/push) code=204 ;;
*/api/v1/write) code=400 ;;
*/api/health) code=200 body='{"database": "ok"}' ;;
https://*/) code=200 ;;
esac
if [[ " $* " == *" -w "* ]]; then printf '%s' "$code"; else printf '%s' "$body"; fi
EOF
printf '#!/bin/sh\necho "10.0.0.5 STREAM $2"\n' >"$WORK/bin/getent"
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/docker"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/openssl"
chmod +x "$WORK/bin/"*

doctor() { PATH="$WORK/bin:$PATH" bash "$WORK/checkout/scripts/doctor.sh" "$@" 2>&1; }
write_env() {
	cat >"$WORK/checkout/.env" <<EOF
COMPOSE_FILE='compose.yaml:compose.standalone.yaml'
GATEWAY_SCHEME='https'
GRAFANA_DOMAIN='grafana.test'
INGEST_DOMAIN='ingest.test'
GRAFANA_ADMIN_PASSWORD='s3cret'
AGENT_TOKENS='db-01:abc123'
COMPOSE_PROFILES='backup'
BACKUP_REPOSITORY='/local'
BACKUP_PASSWORD='key'
EOF
	printf '%s\n' "$@" >>"$WORK/checkout/.env"
}

write_env
out="$(doctor)"
assert_eq 0 "$?" "a healthy deployment passes"
assert_contains "$out" "grafana.test → 10.0.0.5" "domains are resolved"
assert_contains "$out" "Request tanpa token ditolak (401)" "the ingest endpoint demands a token"
assert_contains "$out" "Token 'db-01' diterima gateway" "the first agent token is tried"
assert_contains "$out" "Loki menerima push lewat gateway" "a log push reaches Loki"
assert_contains "$out" "Prometheus menerima remote write lewat gateway" "remote write reaches Prometheus"
assert_contains "$out" "Docker tidak bisa diakses" "local checks are skipped away from the stack"

out="$(FAKE_PING_AUTH=401 doctor)"
assert_eq 1 "$?" "a rejected token fails the check"
assert_contains "$out" "Token 'db-01' ditolak gateway (HTTP 401)" "the rejected token is named"

write_env "GRAFANA_DOMAIN='grafana.example.com'" "GRAFANA_ADMIN_PASSWORD='change-me'" "COMPOSE_FILE=''" "BACKUP_PASSWORD=''"
out="$(doctor)"
assert_eq 1 "$?" "configuration problems fail the check"
assert_contains "$out" "GRAFANA_DOMAIN masih contoh" "example domains are flagged"
assert_contains "$out" "GRAFANA_ADMIN_PASSWORD masih 'change-me'" "default passwords are flagged"
assert_contains "$out" "port 80/443 tidak dibuka" "standalone mode needs its compose file"
assert_contains "$out" "BACKUP_REPOSITORY / BACKUP_PASSWORD kosong" "an incomplete backup setup is flagged"

write_env "COMPOSE_PROFILES=''"
assert_contains "$(doctor)" "Backup terjadwal belum aktif" "disabled backups are pointed out"
assert_contains "$(doctor --host db-01)" "hanya bisa dicek di server stack" "--host needs the stack's server"

rm "$WORK/checkout/.env"
assert_fails "a missing .env fails" doctor >/dev/null

source <(sed -n '/^threshold()/p; /^config_value()/p; /^seconds()/,/^}/p' "$ROOT/scripts/doctor.sh")
cd "$ROOT" || exit 1
assert_eq 85 "$(threshold disk warning)" "thresholds come from the generator config"
assert_eq 2m "$(threshold agent_lag warning)" "duration thresholds keep their unit"
assert_eq 120 "$(seconds 2m)" "durations convert to seconds"
assert_eq 3m "$(config_value silent_after)" "the silence window comes from the generator config"

finish
