#!/bin/bash

set -euo pipefail

action="$1"
bundle_identifier="$2"
expected_app="$3"
timeout_seconds="$4"
state_file="${HITW_TEST_LIFECYCLE_STATE:?missing lifecycle state fixture}"
log_file="${HITW_TEST_LIFECYCLE_LOG:?missing lifecycle log fixture}"
mode="${HITW_TEST_LIFECYCLE_MODE:-normal}"

printf '%s|%s|%s|%s\n' "$action" "$bundle_identifier" "$expected_app" "$timeout_seconds" >> "$log_file"
state="stopped"
if [[ -f "$state_file" ]]; then state="$(sed -n '1p' "$state_file")"; fi

case "$action" in
    probe)
        if [[ "$state" == "running|$expected_app" ]]; then echo running; else echo stopped; fi
        ;;
    terminate)
        if [[ "$mode" == "refuse-terminate" ]]; then exit 1; fi
        if [[ "$mode" == "slow-refuse-terminate" ]]; then sleep 1.2; exit 1; fi
        if [[ "$mode" == "terminate-then-error" ]]; then
            printf '%s\n' stopped > "$state_file"
            exit 1
        fi
        printf '%s\n' stopped > "$state_file"
        echo stopped
        ;;
    launch)
        if [[ "$mode" == "refuse-launch" ]]; then exit 1; fi
        printf 'running|%s\n' "$expected_app" > "$state_file"
        echo running
        ;;
    wait-running)
        if [[ "$state" == "running|$expected_app" ]]; then echo running; else exit 1; fi
        ;;
    *) exit 2 ;;
esac
