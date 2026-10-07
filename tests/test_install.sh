#!/usr/bin/env bash
# Unit tests for agent/install.sh helpers (no root, Docker or network needed).
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PLG_INSTALL_SOURCE_ONLY=1 PLG_CONF_DIR="$TMP/conf" source "$ROOT/agent/install.sh"
set +e

# --- catalog -------------------------------------------------------------------

parse_catalog "$ROOT/agent/modules/catalog.conf"
assert_eq "base" "${MODULE_ORDER[0]}" "base is the first module"
assert_contains " ${MODULE_ORDER[*]} " " postgres " "postgres is in the catalog"
assert_eq "process postgres|postmaster" "${M_DETECT[postgres]}" "detect spec keeps the regex"
assert_eq " POSTGRES_DSN" "${M_VARS[postgres]}" "postgres declares its DSN"
assert_eq "secret" "${V_FLAGS[POSTGRES_DSN]}" "DSN is a secret"
assert_contains "${V_PROMPT[POSTGRES_DSN]}" "sslmode=disable" "prompt keeps '=' characters"
assert_eq "127.0.0.1:6379" "${V_DEFAULT[REDIS_ADDR]}" "plain variables carry a default"
assert_eq "secret,optional" "${V_FLAGS[REDIS_PASSWORD]}" "optional flag is parsed"
assert_eq "yes" "${M_PRIV[docker-metrics]}" "docker-metrics needs privileged"
assert_eq "docker" "${M_REQ[docker-logs]}" "docker-logs requires Docker"

for mod in "${MODULE_ORDER[@]}"; do
	assert_ok "module $mod has an .alloy file" test -f "$ROOT/agent/modules/$mod.alloy"
	assert_ok "module $mod has a title" test -n "${M_TITLE[$mod]:-}"
done
for file in "$ROOT"/agent/modules/*.alloy; do
	name="$(basename "$file" .alloy)"
	assert_contains " ${MODULE_ORDER[*]} " " $name " "$name.alloy is listed in the catalog"
done

cat >"$TMP/bad.conf" <<'EOF'
[broken]
var.lower_case = plain | x |
EOF
assert_fails "invalid variable names are rejected" bash -c "
	PLG_INSTALL_SOURCE_ONLY=1 source '$ROOT/agent/install.sh'
	parse_catalog '$TMP/bad.conf'
" 2>/dev/null

mapfile -t vars < <(all_module_vars)
assert_eq 0 "$(printf '%s\n' "${vars[@]}" | grep -cx '')" "module variable list has no empty entries"
assert_contains " ${vars[*]} " " POSTGRES_DSN " "module variables are listed"
SELECTED=(base docker-logs postgres)
mapfile -t keys < <(persisted_keys)
assert_eq 0 "$(printf '%s\n' "${keys[@]}" | grep -cx '')" "persisted keys have no empty entries"
assert_contains " ${keys[*]} " " POSTGRES_DSN " "selected module variables are persisted"

# --- module selection ------------------------------------------------------------

HAS_DOCKER=0
resolve_selection "1,postgres"
assert_eq "base postgres" "${SELECTED[*]}" "numbers and names resolve, base always included"
assert_fails "docker-only modules are hidden without Docker" resolve_selection "docker-logs" 2>/dev/null
HAS_DOCKER=1
resolve_selection "docker-logs,docker-logs"
assert_eq "base docker-logs" "${SELECTED[*]}" "duplicates are ignored"
assert_eq "1,2" "$(selection_numbers base,docker-logs)" "names convert back to numbers"

MODE=native
assert_fails "docker-metrics is not offered in native mode" resolve_selection "docker-metrics" 2>/dev/null
assert_ok "docker-logs still works in native mode" resolve_selection "docker-logs"
MODE=docker
assert_ok "docker-metrics is offered in docker mode" resolve_selection "docker-metrics"
MODE=""

HAS_DOCKER=0
MODULES_ARG="" MONITORING_MODULES="base,docker-logs,postgres,gone"
assert_eq "base,postgres" "$(default_selection)" "unavailable modules from the previous install are dropped"
MONITORING_MODULES=""

# --- env file round trip --------------------------------------------------------

MONITORING_PASSWORD='abc123='
POSTGRES_DSN='postgresql://u:p@127.0.0.1:5432/db?sslmode=disable'
LOG_REDACT_REGEX='[^\s\S]'
MONITORING_HOST='db "01" \ x'
for style in docker systemd; do
	write_env_file "$TMP/$style.env" "$style" MONITORING_PASSWORD POSTGRES_DSN LOG_REDACT_REGEX MONITORING_HOST MONITORING_ENV
	(
		MONITORING_PASSWORD="" POSTGRES_DSN="" LOG_REDACT_REGEX="" MONITORING_HOST=""
		load_env_file "$TMP/$style.env" MONITORING_PASSWORD POSTGRES_DSN LOG_REDACT_REGEX MONITORING_HOST
		assert_eq 'abc123=' "$MONITORING_PASSWORD" "$style: trailing '=' survives"
		assert_eq 'postgresql://u:p@127.0.0.1:5432/db?sslmode=disable' "$POSTGRES_DSN" "$style: DSN survives"
		assert_eq '[^\s\S]' "$LOG_REDACT_REGEX" "$style: backslashes survive"
		assert_eq 'db "01" \ x' "$MONITORING_HOST" "$style: quotes survive"
		exit "$FAILURES"
	) || FAILURES=$((FAILURES + $?))
done
assert_contains "$(cat "$TMP/docker.env")" "HOST_ROOT=/host/root" "docker env points modules at the host root"
assert_fails "empty values are not written" grep -q '^MONITORING_ENV=' "$TMP/docker.env"
assert_eq "600" "$(stat -c %a "$TMP/docker.env")" "env file is private"

(
	MONITORING_PASSWORD="from-flag"
	load_env_file "$TMP/docker.env" MONITORING_PASSWORD
	assert_eq "from-flag" "$MONITORING_PASSWORD" "values from flags win over the previous install"
	exit "$FAILURES"
) || FAILURES=$((FAILURES + $?))

printf 'PATH=/evil\nMONITORING_ENV=prod\n' >"$TMP/extra.env"
(
	MONITORING_ENV=""
	load_env_file "$TMP/extra.env" MONITORING_ENV
	assert_eq "prod" "$MONITORING_ENV" "listed keys load"
	assert_fails "unlisted keys are ignored" test "$PATH" = /evil
	exit "$FAILURES"
) || FAILURES=$((FAILURES + $?))

# --- memory limits --------------------------------------------------------------

assert_eq "512M" "$(normalize_size 512m)" "sizes are upper-cased"
assert_eq "1G" "$(normalize_size 1GB)" "a trailing B is dropped"
assert_fails "junk sizes are rejected" normalize_size 12x
assert_eq "460MiB" "$(gomemlimit_for 512M)" "GOMEMLIMIT is 90% of the limit"
assert_eq "921MiB" "$(gomemlimit_for 1G)" "gigabytes convert to MiB"
assert_eq "" "$(gomemlimit_for 100K)" "tiny limits leave GOMEMLIMIT unset"

# --- log targets ----------------------------------------------------------------

write_log_targets "$TMP/auto.yaml" '/var/log/nginx/*.log=nginx' '/srv/a "b"/*.log=app'
assert_contains "$(cat "$TMP/auto.yaml")" '__path__: "/var/log/nginx/*.log"' "paths are quoted"
assert_contains "$(cat "$TMP/auto.yaml")" '__path__: "/srv/a \"b\"/*.log"' "quotes in paths are escaped"
assert_contains "$(cat "$TMP/auto.yaml")" 'service: "app"' "service label is written"
write_log_targets "$TMP/empty.yaml"
assert_contains "$(cat "$TMP/empty.yaml")" "[]" "no targets is still a valid YAML list"

# --- docker mode: root mount fallback --------------------------------------------

DOCKER_RUNS="$TMP/docker-runs"
docker() {
	case "$1" in
	run)
		printf '%s\n' "$*" >>"$DOCKER_RUNS"
		if [[ "$*" == *rslave* && "${DOCKER_FAIL:-}" == propagation ]]; then
			echo "docker: Error response from daemon: path / is mounted on / but it is not a shared or slave mount" >&2
			return 125
		fi
		if [[ "${DOCKER_FAIL:-}" == other ]]; then
			echo "docker: Error response from daemon: conflict" >&2
			return 125
		fi
		echo container-id
		;;
	esac
}

(
	ENV_FILE="$TMP/agent.env" MODULE_DIR="$TMP/modules" SELECTED=(base)
	PRIVILEGED=0 AGENT_MEMORY_LIMIT=512M AGENT_LOG_MAX_SIZE=10m DOCKER_FAIL=propagation
	: >"$DOCKER_RUNS"
	install_docker >/dev/null 2>"$TMP/stderr"
	assert_eq 2 "$(wc -l <"$DOCKER_RUNS")" "a refused rslave mount is retried once"
	assert_contains "$(sed -n 1p "$DOCKER_RUNS")" "-v /:/host/root:ro,rslave" "rslave is tried first"
	assert_contains "$(sed -n 2p "$DOCKER_RUNS")" "-v /:/host/root:ro " "the retry mounts / without propagation"
	assert_contains "$(cat "$TMP/stderr")" "bukan shared mount" "the fallback is explained"
	assert_contains "$(sed -n 1p "$DOCKER_RUNS")" "--memory 512m" "the memory limit is passed in Docker's format"
	assert_fails "privileged is off unless a module needs it" grep -q -- --privileged "$DOCKER_RUNS"
	exit "$FAILURES"
) || FAILURES=$((FAILURES + $?))

(
	ENV_FILE="$TMP/agent.env" MODULE_DIR="$TMP/modules" SELECTED=(base)
	PRIVILEGED=0 AGENT_MEMORY_LIMIT=0 AGENT_LOG_MAX_SIZE=10m DOCKER_FAIL=other
	: >"$DOCKER_RUNS"
	install_docker >/dev/null 2>&1
) && FAILURES=$((FAILURES + 1)) && echo "FAIL: other docker run errors must abort" >&2
assert_eq 1 "$(wc -l <"$DOCKER_RUNS")" "other errors are not retried"
unset -f docker

# --- process detection ------------------------------------------------------------

assert_fails "a process in our own PID namespace is not a container" in_container $$
sleep 30 &
sleeper=$!
assert_fails "child processes share the namespace" in_container "$sleeper"
kill "$sleeper" 2>/dev/null

# --- prompts --------------------------------------------------------------------

(
	ASSUME_YES=1
	for name in answer var prompt default reply hint; do
		unset "$name"
		ask "$name" "prompt" "value-$name"
		assert_eq "value-$name" "${!name:-}" "ask fills a caller variable named $name"
		unset "$name"
		ask_secret "$name" "prompt" "secret-$name"
		assert_eq "secret-$name" "${!name:-}" "ask_secret fills a caller variable named $name"
	done
	exit "$FAILURES"
) || FAILURES=$((FAILURES + $?))

# --- labels ---------------------------------------------------------------------

assert_ok "plain names are valid" valid_label db-01.prod_a
assert_fails "spaces are invalid" valid_label "db 01"
assert_fails "leading dash is invalid" valid_label -db

finish
