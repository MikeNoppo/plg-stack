#!/usr/bin/env bash
# Runs every tests/test_*.sh; exits non-zero if any fails.
set -uo pipefail

cd "$(dirname "$0")"
status=0
for test in test_*.sh; do
	bash "$test" || status=1
done
exit "$status"
