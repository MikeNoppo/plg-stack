#!/bin/sh
# Builds the agent credential matcher from AGENT_TOKENS (name:token pairs,
# separated by commas, spaces or newlines) plus the self-monitoring agent,
# then starts Caddy.
set -eu
set -f

out="${AGENT_AUTH_FILE:-/config/agent-auth.caddy}"
count=0
lines=""

add_agent() {
	name="$1"
	token="$2"
	case "$name" in
	"" | *[!A-Za-z0-9._-]*)
		echo "gateway: nama agent tidak valid diabaikan: '$name'" >&2
		return 0
		;;
	esac
	case "$token" in
	"" | *[!A-Za-z0-9._~+/=-]*)
		echo "gateway: token untuk '$name' tidak valid, diabaikan" >&2
		return 0
		;;
	esac
	# Agents send standard basic auth, so comparing the whole header value
	# avoids hashing every token at startup.
	value="$(printf '%s:%s' "$name" "$token" | base64 | tr -d '\n')"
	lines="${lines}header Authorization \"Basic ${value}\"
"
	count=$((count + 1))
}

for pair in $(printf '%s' "${AGENT_TOKENS:-}" | tr ',' ' '); do
	case "$pair" in
	*:*) add_agent "${pair%%:*}" "${pair#*:}" ;;
	*) echo "gateway: entri AGENT_TOKENS tanpa ':' diabaikan" >&2 ;;
	esac
done
if [ -n "${SELF_MONITORING_TOKEN:-}" ]; then
	add_agent "${SELF_MONITORING_NAME:-plg-stack}" "$SELF_MONITORING_TOKEN"
fi

if [ "$count" -eq 0 ]; then
	# An empty matcher would match every request; this value matches none.
	lines="header Authorization \"Basic $(head -c 32 /dev/urandom | base64 | tr -d '\n')\"
"
	echo "gateway: belum ada token agent; endpoint ingest menolak semua agent" >&2
fi

mkdir -p "$(dirname "$out")"
printf '%s' "$lines" >"$out"
echo "gateway: $count token agent dimuat" >&2

[ "${1:-}" = "--render-only" ] && exit 0
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
