#!/bin/sh
# Writes Loki's config before Loki starts, since the Loki image has no shell:
# loki.yaml.tmpl plus the storage periods for LOKI_STORAGE (filesystem or s3).
#
# Moving from filesystem to s3 keeps the logs already on the local disk
# readable: their days stay a filesystem period, which retention empties as
# usual, and S3 takes over from the day kept in /loki/s3-since.
set -eu

TEMPLATE=/src/loki.yaml.tmpl
OUT=/config/loki.yaml
DATA=/loki

log() { printf 'loki-init: %s\n' "$*" >&2; }

period() {
	cat <<EOF
    - from: $1
      store: tsdb
      object_store: $2
      schema: v13
      index:
        prefix: index_
        period: 24h
EOF
}

# The first midnight (UTC) at least an hour after the epoch seconds given. A
# period has to start after Loki loaded it, or Loki would look for logs it
# already stored that day in the new store; the hour leaves time to deploy.
switch_date() { date -u -d "@$(($1 + 90000))" +%Y-%m-%d; }

has_local_logs() { [ -n "$(find "$DATA/chunks" -type f 2>/dev/null | head -n 1)" ]; }

render() {
	since_file="$DATA/s3-since"
	case "${LOKI_STORAGE:-}" in
	filesystem)
		if [ -f "$since_file" ]; then
			log "peralihan ke S3 (mulai $(cat "$since_file")) dibatalkan; log yang sudah tersimpan di S3 tidak terbaca lagi"
			rm "$since_file"
		fi
		periods="$(period 2024-01-01 filesystem)"
		;;
	s3)
		if [ ! -f "$since_file" ] && has_local_logs; then
			switch_date "$(date +%s)" >"$since_file.tmp"
			mv "$since_file.tmp" "$since_file"
		fi
		if [ -f "$since_file" ]; then
			since="$(cat "$since_file")"
			log "log sebelum $since tetap di disk lokal sampai terhapus retensi; mulai $since 00:00 UTC log disimpan di S3"
			periods="$(
				period 2024-01-01 filesystem
				period "$since" s3
			)"
		else
			periods="$(period 2024-01-01 s3)"
		fi
		;;
	*)
		log "LOKI_STORAGE harus filesystem atau s3, bukan '${LOKI_STORAGE:-}'"
		return 1
		;;
	esac
	{
		cat "$TEMPLATE"
		printf '%s\n' "$periods"
	} >"$OUT.tmp"
	mv "$OUT.tmp" "$OUT"
}

[ -z "${PLG_LOKI_INIT_SOURCE_ONLY:-}" ] || return 0
render
