#!/bin/sh
# Writes Loki's config before Loki starts, since the Loki image has no shell:
# loki.yaml.tmpl plus the storage periods for LOKI_STORAGE (filesystem or s3).
set -eu

TEMPLATE=/src/loki.yaml.tmpl
OUT=/config/loki.yaml

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

render() {
	case "${LOKI_STORAGE:-}" in
	filesystem | s3) ;;
	*)
		log "LOKI_STORAGE harus filesystem atau s3, bukan '${LOKI_STORAGE:-}'"
		return 1
		;;
	esac
	{
		cat "$TEMPLATE"
		period 2024-01-01 "$LOKI_STORAGE"
	} >"$OUT.tmp"
	mv "$OUT.tmp" "$OUT"
}

[ -z "${PLG_LOKI_INIT_SOURCE_ONLY:-}" ] || return 0
render
