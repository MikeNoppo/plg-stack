#!/bin/sh
# Writes Loki's config before Loki starts, since the Loki image has no shell.
#
# Loki reads each day's logs from the store in use that day, so every switch
# of LOKI_STORAGE is recorded in /loki/storage-history, which is only ever
# appended to. A new store takes over at a midnight (UTC); switching back
# before then cancels the switch.
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

# Single quotes keep any secret a plain string (setup.sh rejects values
# with a single quote); Loki fills in the variables when it starts.
s3_storage() {
	cat <<'EOF'
storage_config:
  aws:
    bucketnames: '${LOKI_S3_BUCKET}'
    region: '${LOKI_S3_REGION}'
    # Empty endpoint and keys fall back to AWS defaults (instance role).
    endpoint: '${LOKI_S3_ENDPOINT}'
    access_key_id: '${LOKI_S3_ACCESS_KEY_ID}'
    secret_access_key: '${LOKI_S3_SECRET_ACCESS_KEY}'
    s3forcepathstyle: ${LOKI_S3_FORCE_PATH_STYLE:-false}
EOF
}

# The first midnight (UTC) at least an hour after the epoch seconds given. A
# period has to start after Loki loaded it, or Loki would look for logs it
# already stored that day in the new store; the hour leaves time to deploy.
switch_date() { date -u -d "@$(($1 + 90000))" +%Y-%m-%d; }

# Only the filesystem store writes here.
has_local_logs() { [ -n "$(find "$DATA/chunks" -type f 2>/dev/null | head -n 1)" ]; }

switch_storage() {
	# shellcheck disable=SC2046
	set -- "$1" $(tail -n 1 "$1")
	[ "$3" != "$LOKI_STORAGE" ] || return 0
	if [ "$(wc -l <"$1")" -gt 1 ] && [ "$(echo "$2" | tr -d -)" -gt "$(date -u +%Y%m%d)" ]; then
		sed -i '$d' "$1"
		log "peralihan ke $3 mulai $2 dibatalkan"
		return 0
	fi
	since="$(switch_date "$(date +%s)")"
	echo "$since $LOKI_STORAGE" >>"$1"
	log "log baru disimpan di $LOKI_STORAGE mulai $since 00:00 UTC; log sebelumnya tetap dibaca dari tempat lamanya"
}

render() {
	case "${LOKI_STORAGE:-}" in
	filesystem | s3) ;;
	*)
		log "LOKI_STORAGE harus filesystem atau s3, bukan '${LOKI_STORAGE:-}'"
		return 1
		;;
	esac
	history="$DATA/storage-history"
	plan="$(mktemp)"
	if [ -f "$history" ]; then
		if grep -qvE '^[0-9]{4}-[0-9]{2}-[0-9]{2} (filesystem|s3)$' "$history"; then
			log "$history rusak: setiap baris harus 'YYYY-MM-DD filesystem' atau 'YYYY-MM-DD s3'"
			return 1
		fi
		cp "$history" "$plan"
	elif has_local_logs; then
		echo "2024-01-01 filesystem" >"$plan"
	else
		echo "2024-01-01 $LOKI_STORAGE" >"$plan"
	fi
	switch_storage "$plan"
	if grep -q ' s3$' "$plan" && [ -z "${LOKI_S3_BUCKET:-}" ]; then
		log "log tersimpan di S3 sejak $(grep -m1 ' s3$' "$plan" | cut -d' ' -f1), tetapi LOKI_S3_BUCKET kosong; isi LOKI_S3_*"
		return 1
	fi
	# Writing into a volume Loki has not populated yet would stop Docker from
	# copying the image's /loki, and its owner, into it.
	if [ -n "$(ls -A "$DATA")" ]; then
		cp "$plan" "$history.tmp"
		mv "$history.tmp" "$history"
	fi
	{
		sed "s/__DELETE_REQUEST_STORE__/$LOKI_STORAGE/" "$TEMPLATE"
		while read -r from store; do period "$from" "$store"; done <"$plan"
		if grep -q ' s3$' "$plan"; then s3_storage; fi
	} >"$OUT.tmp"
	mv "$OUT.tmp" "$OUT"
	rm "$plan"
}

[ -z "${PLG_LOKI_INIT_SOURCE_ONLY:-}" ] || return 0
render
