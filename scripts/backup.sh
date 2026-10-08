#!/usr/bin/env bash
#   scripts/backup.sh [--project NAME]            back up now; the stack keeps running
#   scripts/backup.sh [--project NAME] snapshots  list backups
#   scripts/backup.sh [--project NAME] check      verify the backup repository
#
# Runs backup/backup.sh inside the stack's backup container, which also backs
# up on its own at BACKUP_SCHEDULE. It runs once COMPOSE_PROFILES includes
# "backup" and BACKUP_* is filled in (scripts/setup.sh).
set -euo pipefail

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

PROJECT=""
COMMAND=run
while (($#)); do
	case "$1" in
	--project) PROJECT="${2:?--project butuh nilai}" && shift ;;
	-h | --help) sed -n '2,8p' "$0" | sed 's/^#//' && exit 0 ;;
	run | snapshots | check) COMMAND="$1" ;;
	*) die "Argumen tidak dikenal: $1 (lihat --help)" ;;
	esac
	shift
done

# Dokploy names the compose project after its app, so the container is found
# by its labels instead of assuming "plg-stack".
filters=(--filter label=com.docker.compose.service=backup --filter status=running)
[[ -z "$PROJECT" ]] || filters+=(--filter "label=com.docker.compose.project=$PROJECT")
mapfile -t containers < <(docker ps -q "${filters[@]}")
((${#containers[@]})) || die "Container backup tidak berjalan. Isi BACKUP_* lewat scripts/setup.sh (menambahkan \"backup\" ke COMPOSE_PROFILES), lalu jalankan ulang stack."
((${#containers[@]} == 1)) || die "Ada beberapa stack dengan service backup; pilih dengan --project."

exec docker exec "${containers[0]}" /bin/sh /backup/backup.sh "$COMMAND"
