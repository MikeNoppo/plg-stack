#!/usr/bin/env bash
#   scripts/agent-token.sh add NAME      create a token and print the install command
#   scripts/agent-token.sh rotate NAME   replace NAME's token
#   scripts/agent-token.sh revoke NAME   remove NAME's token
#   scripts/agent-token.sh list
#
# Tokens live in AGENT_TOKENS in .env. Each server has its own, so one can be
# revoked without touching the others.
set -euo pipefail

cd "$(dirname "$0")/.."

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

usage() {
	sed -n '2,5p' "$0" | sed 's/^#//'
	exit "${1:-0}"
}

env_value() {
	sed -n "s/^$1=//p" .env | tail -1 | sed "s/^'\\(.*\\)'\$/\\1/"
}

# Rewrites AGENT_TOKENS in .env, keeping every other line as it is.
save_tokens() {
	local value="$1"
	{
		grep -v '^AGENT_TOKENS=' .env || true
		printf "AGENT_TOKENS='%s'\n" "$value"
	} >.env.tmp
	chmod 600 .env.tmp
	mv .env.tmp .env
}

declare -a NAMES=() TOKENS=()

load_tokens() {
	local pair
	for pair in $(env_value AGENT_TOKENS | tr ',' ' '); do
		[[ "$pair" == *:* ]] || continue
		NAMES+=("${pair%%:*}")
		TOKENS+=("${pair#*:}")
	done
}

joined_tokens() {
	local i out=()
	for i in "${!NAMES[@]}"; do
		out+=("${NAMES[$i]}:${TOKENS[$i]}")
	done
	local IFS=,
	printf '%s' "${out[*]}"
}

index_of() {
	local i
	for i in "${!NAMES[@]}"; do
		[[ "${NAMES[$i]}" == "$1" ]] && printf '%s' "$i" && return 0
	done
	return 1
}

apply_changes() {
	if docker compose ps --status running --services 2>/dev/null | grep -qx gateway; then
		docker compose up -d gateway >/dev/null 2>&1
		echo "==> Gateway dimuat ulang dengan token terbaru."
	elif [[ "$(env_value GATEWAY_SCHEME)" == http ]]; then
		echo "==> Mode Dokploy: perbarui variabel ini di tab Environment, lalu Deploy:"
		echo "    AGENT_TOKENS='$(joined_tokens)'"
	else
		echo "==> Token tersimpan di .env; berlaku saat stack dijalankan (docker compose up -d)."
	fi
}

print_install() {
	local name="$1" token="$2" domain
	domain="$(env_value INGEST_DOMAIN)"
	cat <<EOF

Jalankan di server '$name':

  curl -fsSL https://$domain/agent/install.sh | sudo bash -s -- --url https://$domain --name $name --token $token

Simpan token ini; tidak ditampilkan lagi selain lewat .env.
EOF
}

[[ -f .env ]] || die ".env belum ada; jalankan scripts/setup.sh dulu."
command="${1:-}"
name="${2:-}"
[[ -n "$command" ]] || usage 1
load_tokens

case "$command" in
add | rotate)
	[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Nama server tidak valid: '$name' (huruf, angka, . _ -)"
	token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
	if idx="$(index_of "$name")"; then
		[[ "$command" == rotate ]] || die "Token untuk '$name' sudah ada. Pakai: $0 rotate $name"
		TOKENS[idx]="$token"
	else
		[[ "$command" == add ]] || die "Token untuk '$name' tidak ditemukan."
		NAMES+=("$name")
		TOKENS+=("$token")
	fi
	save_tokens "$(joined_tokens)"
	apply_changes
	print_install "$name" "$token"
	;;
revoke)
	idx="$(index_of "$name")" || die "Token untuk '$name' tidak ditemukan."
	unset 'NAMES[idx]' 'TOKENS[idx]'
	NAMES=("${NAMES[@]}")
	TOKENS=("${TOKENS[@]}")
	save_tokens "$(joined_tokens)"
	apply_changes
	echo "==> Token '$name' dicabut. Agent di server itu tidak bisa mengirim data lagi."
	;;
list)
	if ((${#NAMES[@]} == 0)); then
		echo "Belum ada token agent."
	else
		for i in "${!NAMES[@]}"; do
			printf '%-30s %s…\n' "${NAMES[$i]}" "${TOKENS[$i]:0:6}"
		done
	fi
	;;
-h | --help) usage 0 ;;
*) usage 1 ;;
esac
