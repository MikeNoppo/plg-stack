#!/usr/bin/env bash
# Restores volumes archived by scripts/backup.sh into this checkout's stack.
#
#   scripts/restore.sh [--project NAME] [--no-start] BACKUP_DIR
#
# Standalone: run from the repo with .env in place; the stack is started after.
# Dokploy: deploy once, stop it, then pass --project <app name> --no-start
# and redeploy from Dokploy.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT=""
START=1
SRC=""

while (($#)); do
	case "$1" in
	--project) PROJECT="${2:?--project butuh nilai}" && shift ;;
	--no-start) START=0 ;;
	-h | --help) sed -n '2,9p' "$0" && exit 0 ;;
	*) SRC="$1" ;;
	esac
	shift
done

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[[ -n "$SRC" && -d "$SRC" ]] || die "Folder backup tidak ditemukan. Pemakaian: scripts/restore.sh BACKUP_DIR"
SRC="$(cd "$SRC" && pwd)"

if [[ -z "$PROJECT" ]]; then
	[[ -f .env ]] || die ".env belum ada; jalankan scripts/setup.sh atau salin dari server lama."
	PROJECT="$(docker compose config --format json | sed -n 's/^ *"name": *"\([^"]*\)".*/\1/p' | head -1)"
	[[ -n "$PROJECT" ]] || die "Gagal membaca nama project compose."
	docker compose up --no-start >/dev/null
fi

mapfile -t running < <(docker ps -q --filter "label=com.docker.compose.project=$PROJECT")
((${#running[@]} == 0)) || die "Stack $PROJECT masih berjalan; hentikan dulu (docker compose stop atau Stop di Dokploy)."

for archive in "$SRC"/*.tar.gz; do
	[[ -e "$archive" ]] || die "Tidak ada arsip .tar.gz di $SRC"
	key="$(basename "$archive" .tar.gz)"
	volume="$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" \
		--filter "label=com.docker.compose.volume=$key")"
	if [[ -z "$volume" ]]; then
		echo "  - volume $key tidak ada di project $PROJECT, dilewati"
		continue
	fi
	docker run --rm -v "$volume:/data" -v "$SRC:/backup:ro" alpine:3 \
		sh -c "find /data -mindepth 1 -delete && tar xzf '/backup/$key.tar.gz' -C /data"
	echo "  ✓ $key dipulihkan ke $volume"
done

if ((START)); then
	docker compose up -d
	echo "==> Stack berjalan. Jangan lupa arahkan DNS ke server ini."
else
	echo "==> Selesai. Jalankan stack lagi (Deploy di Dokploy)."
fi
