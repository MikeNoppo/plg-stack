#!/bin/sh
# Pings WATCHDOG_URL while the stack is healthy. The external service (e.g.
# healthchecks.io, an Uptime Kuma push monitor) alerts when pings stop, which
# also covers this whole server going down. WATCHDOG_FAIL_URL, if set, is
# called instead when a component is unhealthy.
set -u

interval="${WATCHDOG_INTERVAL:-60}"

if [ -z "${WATCHDOG_URL:-}" ]; then
	echo "watchdog: WATCHDOG_URL kosong, tidak ada heartbeat yang dikirim" >&2
	while :; do sleep 3600; done
fi

healthy() { wget -q -T 5 -O /dev/null "$1"; }

while :; do
	failed=""
	healthy http://gateway:9180/metrics || failed="$failed gateway"
	healthy http://prometheus:9090/-/ready || failed="$failed prometheus"
	healthy http://loki:3100/ready || failed="$failed loki"
	healthy http://grafana:3000/api/health || failed="$failed grafana"

	if [ -z "$failed" ]; then
		wget -q -T 10 -O /dev/null "$WATCHDOG_URL" || echo "watchdog: gagal mengirim heartbeat" >&2
	else
		echo "watchdog: tidak sehat:$failed" >&2
		if [ -n "${WATCHDOG_FAIL_URL:-}" ]; then
			wget -q -T 10 -O /dev/null "$WATCHDOG_FAIL_URL" || true
		fi
	fi
	sleep "$interval"
done
