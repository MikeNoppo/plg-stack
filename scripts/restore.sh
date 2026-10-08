#!/usr/bin/env bash
# Replaces the stack's data with a backup made by the backup service.
#
#   scripts/restore.sh [--project NAME] [--no-start] [--yes] [RUN]
#
# RUN is a backup from `scripts/backup.sh snapshots` (default: the latest).
# .env must hold the BACKUP_* values of the server that made the backup.
# Standalone: run from the repo; the stack is started afterwards.
# Dokploy: deploy once and Stop the app, then run this from the app's code
# directory with --project <app name> --no-start, and Deploy again.
set -euo pipefail

cd "$(dirname "$0")/.."

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

PROJECT=""
START=1
YES=0
RUN=latest
while (($#)); do
	case "$1" in
	--project) PROJECT="${2:?--project butuh nilai}" && shift ;;
	--no-start) START=0 ;;
	--yes) YES=1 ;;
	-h | --help) sed -n '2,11p' "$0" | sed 's/^#//' && exit 0 ;;
	-*) die "Opsi tidak dikenal: $1" ;;
	*) RUN="$1" ;;
	esac
	shift
done

[[ -f .env ]] || die ".env belum ada; salin dari server lama atau jalankan scripts/setup.sh."
grep -q '^BACKUP_REPOSITORY=..*' .env && grep -q '^BACKUP_PASSWORD=..*' .env ||
	die "BACKUP_REPOSITORY dan BACKUP_PASSWORD di .env harus sama dengan server yang membuat backup."

compose=(docker compose)
[[ -z "$PROJECT" ]] || compose+=(-p "$PROJECT")
PROJECT="$("${compose[@]}" config --format json | sed -n 's/^ *"name": *"\([^"]*\)".*/\1/p' | head -1)"
[[ -n "$PROJECT" ]] || die "Gagal membaca nama project compose."

mapfile -t running < <(docker ps -q --filter "label=com.docker.compose.project=$PROJECT")
((${#running[@]} == 0)) || die "Stack $PROJECT masih berjalan; hentikan dulu (docker compose stop, atau Stop di Dokploy)."

if ((!YES)); then
	read -r -p "Semua data stack $PROJECT (metrik, log, Grafana, sertifikat) diganti dengan backup '$RUN'. Lanjut? [y/N] " answer
	[[ "${answer,,}" =~ ^(y|yes|ya)$ ]] || exit 1
fi

"${compose[@]}" --profile backup up --no-start >/dev/null
"${compose[@]}" --profile backup run --rm --no-deps backup restore "$RUN"

if ((START)); then
	"${compose[@]}" up -d
	echo "==> Stack berjalan dengan data dari backup '$RUN'. Jangan lupa arahkan DNS ke server ini."
else
	echo "==> Selesai. Jalankan stack lagi (Deploy di Dokploy)."
fi
