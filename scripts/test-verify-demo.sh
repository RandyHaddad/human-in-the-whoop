#!/bin/bash

set -euo pipefail

script_directory="$(cd -P "$(dirname "$0")" && pwd)"
verifier="$script_directory/verify-demo.sh"
test_root="$(mktemp -d /private/tmp/hitw-verify-demo-test.XXXXXX)"

fail() {
    echo "$1" >&2
    exit 1
}

cleanup() {
    local status=$?
    trap - EXIT
    rm -rf "$test_root"
    exit "$status"
}
trap cleanup EXIT

[[ -x "$verifier" ]] || fail "Verification script is missing or not executable."
bash -n "$verifier"

off_output="$({
    printf '%s' '{"feature":"off","charge":null,"recovery_score":null,"recovery_cycle_id":null,"last_successful_refresh":null,"oauth_access_token":"status-parser-secret"}'
} | "$verifier" --parse-status-json)"

expected_off='Status verified:
  Feature: off
  Charge: unavailable
  Recovery score: unavailable
  Recovery cycle: unavailable
  Last successful refresh: never'
[[ "$off_output" == "$expected_off" ]] || fail "Off status was not rendered from the approved fields."
[[ "$off_output" != *status-parser-secret* ]] || fail "Parser leaked an unapproved field."

ready_output="$({
    printf '%s' '{"feature":"ready","charge":72,"recovery_score":72,"recovery_cycle_id":123456,"last_successful_refresh":"2026-07-20T01:02:03.456Z","raw_whoop_response":"never-print-this"}'
} | "$verifier" --parse-status-json)"

expected_ready='Status verified:
  Feature: ready
  Charge: 72/100
  Recovery score: 72/100
  Recovery cycle: 123456
  Last successful refresh: 2026-07-20T01:02:03.456Z'
[[ "$ready_output" == "$expected_ready" ]] || fail "Ready status was not rendered from the approved fields."
[[ "$ready_output" != *never-print-this* ]] || fail "Parser leaked a raw response field."

expect_safe_rejection() {
    local label="$1"
    local input="$2"
    local forbidden="$3"
    local stdout_file="$test_root/$label.stdout"
    local stderr_file="$test_root/$label.stderr"

    set +e
    printf '%s' "$input" | "$verifier" --parse-status-json >"$stdout_file" 2>"$stderr_file"
    local status=$?
    set -e

    [[ "$status" != 0 ]] || fail "$label status unexpectedly passed validation."
    [[ ! -s "$stdout_file" ]] || fail "$label status wrote partially validated output."
    grep -Fq 'Status output failed safe validation.' "$stderr_file" \
        || fail "$label status did not return the generic parser error."
    if [[ -n "$forbidden" ]] && grep -Fq "$forbidden" "$stderr_file"; then
        fail "$label status leaked rejected input through stderr."
    fi
}

expect_safe_rejection \
    malformed \
    '{"feature":"ready","access_token":"malformed-secret"' \
    'malformed-secret'

expect_safe_rejection \
    inconsistent \
    '{"feature":"ready","charge":null,"recovery_score":72,"recovery_cycle_id":123,"last_successful_refresh":null,"client_secret":"inconsistent-secret"}' \
    'inconsistent-secret'

expect_safe_rejection \
    injected_date \
    '{"feature":"off","charge":null,"recovery_score":null,"recovery_cycle_id":null,"last_successful_refresh":"2026-07-20T01:02:03Z\\nrefresh_token=injected-secret"}' \
    'injected-secret'

echo "verify-demo parser tests passed."
