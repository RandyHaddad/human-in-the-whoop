#!/bin/bash

set -euo pipefail

script_directory="$(cd -P "$(dirname "$0")" && pwd)"
repository_root="$(cd -P "$script_directory/.." && pwd)"
app_artifact="$repository_root/.build/release/Human in the Whoop.app"
control_binary="$repository_root/.build/release/hitwctl"
temporary_status_file=""

cleanup_status_file() {
    if [[ -n "$temporary_status_file" && -f "$temporary_status_file" && ! -L "$temporary_status_file" ]]; then
        rm -f "$temporary_status_file"
    fi
    temporary_status_file=""
}

trap cleanup_status_file EXIT
trap 'cleanup_status_file; exit 1' HUP INT TERM

status_validation_error() {
    echo "Status output failed safe validation." >&2
    return 1
}

parse_status_json() {
    local status_file status_size feature charge_type score_type cycle_type refresh_type
    local charge score cycle refresh

    umask 077
    status_file="$(mktemp /private/tmp/hitw-status.XXXXXX)"
    temporary_status_file="$status_file"
    /usr/bin/head -c 16385 > "$status_file"

    status_size="$(LC_ALL=C wc -c < "$status_file" | tr -d '[:space:]')"
    if [[ ! "$status_size" =~ ^[0-9]+$ ]] || (( status_size == 0 || status_size > 16384 )); then
        rm -f "$status_file"
        temporary_status_file=""
        status_validation_error
        return 1
    fi
    if ! feature="$(/usr/bin/plutil -extract feature raw -expect string -o - "$status_file" 2>/dev/null)"; then
        rm -f "$status_file"
        temporary_status_file=""
        status_validation_error
        return 1
    fi

    charge_type="$(/usr/bin/plutil -type charge "$status_file" 2>/dev/null || true)"
    score_type="$(/usr/bin/plutil -type recovery_score "$status_file" 2>/dev/null || true)"
    cycle_type="$(/usr/bin/plutil -type recovery_cycle_id "$status_file" 2>/dev/null || true)"
    refresh_type="$(/usr/bin/plutil -type last_successful_refresh "$status_file" 2>/dev/null || true)"

    case "$refresh_type" in
        '(any)')
            refresh="never"
            ;;
        string)
            if ! refresh="$(/usr/bin/plutil -extract last_successful_refresh raw -expect string -o - "$status_file" 2>/dev/null)"; then
                rm -f "$status_file"
                temporary_status_file=""
                status_validation_error
                return 1
            fi
            if [[ ! "$refresh" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; then
                rm -f "$status_file"
                temporary_status_file=""
                status_validation_error
                return 1
            fi
            ;;
        *)
            rm -f "$status_file"
            temporary_status_file=""
            status_validation_error
            return 1
            ;;
    esac

    case "$feature" in
        off|unavailable)
            if [[ "$charge_type" != '(any)' || "$score_type" != '(any)' || "$cycle_type" != '(any)' ]]; then
                rm -f "$status_file"
                temporary_status_file=""
                status_validation_error
                return 1
            fi
            charge="unavailable"
            score="unavailable"
            cycle="unavailable"
            ;;
        ready)
            if [[ "$charge_type" != integer || "$score_type" != integer || "$cycle_type" != integer ]]; then
                rm -f "$status_file"
                temporary_status_file=""
                status_validation_error
                return 1
            fi
            if ! charge="$(/usr/bin/plutil -extract charge raw -expect integer -o - "$status_file" 2>/dev/null)" \
                || ! score="$(/usr/bin/plutil -extract recovery_score raw -expect integer -o - "$status_file" 2>/dev/null)" \
                || ! cycle="$(/usr/bin/plutil -extract recovery_cycle_id raw -expect integer -o - "$status_file" 2>/dev/null)";
            then
                rm -f "$status_file"
                temporary_status_file=""
                status_validation_error
                return 1
            fi
            if [[ ! "$charge" =~ ^[0-9]+$ || ! "$score" =~ ^[0-9]+$ || ! "$cycle" =~ ^[0-9]+$ ]] \
                || (( charge > 100 || score > 100 || cycle == 0 ));
            then
                rm -f "$status_file"
                status_validation_error
                return 1
            fi
            charge="$charge/100"
            score="$score/100"
            ;;
        *)
            rm -f "$status_file"
            temporary_status_file=""
            status_validation_error
            return 1
            ;;
    esac

    rm -f "$status_file"
    temporary_status_file=""
    printf '%s\n' \
        'Status verified:' \
        "  Feature: $feature" \
        "  Charge: $charge" \
        "  Recovery score: $score" \
        "  Recovery cycle: $cycle" \
        "  Last successful refresh: $refresh"
}

if [[ "${1:-}" == "--parse-status-json" ]]; then
    [[ "$#" == 1 ]] || { status_validation_error; exit 1; }
    parse_status_json
    exit 0
fi

if [[ "$#" != 0 ]]; then
    echo "Usage: $(basename "$0")" >&2
    exit 2
fi

cd "$repository_root"

echo "[1/6] Running the full isolated test suite."
swift test

echo "[2/6] Building release products."
swift build -c release

echo "[3/6] Packaging the menu-bar companion without installing or launching it."
"$script_directory/package-app.sh"

echo "[4/6] Verifying the packaged app signature."
codesign --verify --deep --strict "$app_artifact"

echo "[5/6] Reading local presentation status only."
status_json="$($control_binary status --json)"
printf '%s' "$status_json" | parse_status_json

echo "[6/6] Non-live verification complete. See the verification report for any separately authorized live evidence."
