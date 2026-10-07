# Minimal assertion helpers shared by tests/test_*.sh.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

assert_eq() {
	local expected="$1" actual="$2" message="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$message" "$expected" "$actual" >&2
		FAILURES=$((FAILURES + 1))
	fi
}

assert_contains() {
	local haystack="$1" needle="$2" message="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		printf 'FAIL: %s\n  missing: %q\n  in:      %q\n' "$message" "$needle" "$haystack" >&2
		FAILURES=$((FAILURES + 1))
	fi
}

assert_ok() {
	local message="$1"
	shift
	if ! "$@"; then
		printf 'FAIL: %s\n' "$message" >&2
		FAILURES=$((FAILURES + 1))
	fi
}

assert_fails() {
	local message="$1"
	shift
	if "$@"; then
		printf 'FAIL: %s (expected failure)\n' "$message" >&2
		FAILURES=$((FAILURES + 1))
	fi
}

finish() {
	if ((FAILURES)); then
		printf '%s: %d failure(s)\n' "$(basename "$0")" "$FAILURES" >&2
		exit 1
	fi
	printf '%s: ok\n' "$(basename "$0")"
}
