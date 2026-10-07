#!/usr/bin/env bash
# Archives the stack's Docker volumes so they can be restored on another
# server with scripts/restore.sh.
#
#   scripts/backup.sh [--project NAME] [--no-stop] [OUTPUT_DIR]
set -euo pipefail

VOLUMES=(prometheus-data loki-data grafana-data caddy-data)
PROJECT=""
STOP=1
OUT=""

while (($#)); do
	case "$1" in
	--project) PROJECT="${2:?--project butuh nilai}" && shift ;;
	--no-stop) STOP=0 ;;
	-h | --help) sed -n '2,6p' "$0" && exit 0 ;;
	*) OUT="$1" ;;
	esac
	shift
done

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

# Dokploy names the compose project after its app, so find it from the
# volume labels instead of assuming "monitoring".
if [[ -z "$PROJECT" ]]; then
	mapfile -t projects < <(docker volume ls --filter label=com.docker.compose.volume=prometheus-data \
		--format '{{.Label "com.docker.compose.project"}}' | sort -u)
	((${#projects[@]})) || die "Volume stack tidak ditemukan di server ini."
	((${#projects[@]} == 1)) || die "Ada beberapa project (${projects[*]}); pilih dengan --project."
	PROJECT="${projects[0]}"
fi

OUT="${OUT:-backups/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

mapfile -t running < <(docker ps -q --filter "label=com.docker.compose.project=$PROJECT")
if ((STOP)) && ((${#running[@]})); then
	echo "==> Menghentikan ${#running[@]} container project $PROJECT agar data konsisten"
	docker stop "${running[@]}" >/dev/null
	trap 'echo "==> Menyalakan kembali container"; docker start "${running[@]}" >/dev/null' EXIT
fi

for key in "${VOLUMES[@]}"; do
	volume="$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" \
		--filter "label=com.docker.compose.volume=$key")"
	if [[ -z "$volume" ]]; then
		echo "  - $key tidak ada, dilewati"
		continue
	fi
	docker run --rm -v "$volume:/data:ro" -v "$OUT:/backup" alpine:3 \
		tar czf "/backup/$key.tar.gz" -C /data .
	echo "  ✓ $key → $OUT/$key.tar.gz ($(du -h "$OUT/$key.tar.gz" | cut -f1))"
done

echo "==> Backup selesai: $OUT"
echo "    Salin folder ini beserta .env ke server baru, lalu jalankan scripts/restore.sh $OUT"
