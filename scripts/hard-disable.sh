#!/bin/bash

set -euo pipefail

script_directory="$(cd -P "$(dirname "$0")" && pwd)"
state_override_present="${HITW_INSTALL_STATE_ROOT+x}"
applications_override_present="${HITW_INSTALL_APPLICATIONS_DIR+x}"
hooks_override_present="${HITW_INSTALL_HOOKS_FILE+x}"
lifecycle_adapter_present="${HITW_LIFECYCLE_ADAPTER+x}"
fault_seam_present="${HITW_INSTALL_TEST_FAIL_AT+x}"
barrier_seam_present="${HITW_INSTALL_TEST_BARRIER_DIR+x}"
fixture_state_present="${HITW_TEST_LIFECYCLE_STATE+x}"
fixture_log_present="${HITW_TEST_LIFECYCLE_LOG+x}"
fixture_mode_present="${HITW_TEST_LIFECYCLE_MODE+x}"
state_root="${HITW_INSTALL_STATE_ROOT:-$HOME/Library/Application Support/Human in the Whoop}"
applications_directory="${HITW_INSTALL_APPLICATIONS_DIR:-$HOME/Applications}"
hooks_file="${HITW_INSTALL_HOOKS_FILE:-$HOME/.codex/hooks.json}"
lifecycle_adapter="${HITW_LIFECYCLE_ADAPTER:-}"
lifecycle_timeout="${HITW_LIFECYCLE_TIMEOUT_SECONDS:-5}"
test_mode="${HITW_INSTALL_TEST_MODE:-0}"
installed_control="$state_root/bin/hitwctl"
installed_hook="$state_root/bin/hitw-hook"
installed_app="$applications_directory/Human in the Whoop.app"
bundle_identifier="com.randyhaddad.human-in-the-whoop"

reject_path() { echo "Refusing unsafe $1 path: $2" >&2; exit 2; }

validate_path() {
    local label="$1"; local path="$2"
    if [[ -z "$path" || "$path" != /* ]]; then reject_path "$label" "$path"; fi
    case "$path" in *//*|*/../*|*/..|*/./*|*/.|*/) reject_path "$label" "$path" ;; esac
    case "$path" in /|/Users|/Library|/System|/Applications|/tmp|/private|/private/tmp|"$HOME") reject_path "$label" "$path" ;; esac
    if [[ "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then reject_path "$label" "$path"; fi
}

reject_symlink_components() {
    local label="$1"; local path="$2"; local remainder="${path#/}"; local current=""
    local old_ifs="$IFS"; local components=(); IFS='/' read -r -a components <<< "$remainder"; IFS="$old_ifs"
    local last_index=$((${#components[@]} - 1)); local index
    for index in "${!components[@]}"; do
        current="$current/${components[$index]}"
        if [[ -L "$current" ]]; then reject_path "$label symbolic-link component" "$current"; fi
        if [[ -e "$current" && "$index" != "$last_index" && ! -d "$current" ]]; then reject_path "$label non-directory component" "$current"; fi
        if [[ ! -e "$current" ]]; then return 0; fi
    done
}

require_isolated_test_directory() {
    local label="$1"; local path="$2"
    validate_path "$label" "$path"
    case "$path" in /private/tmp/*) ;; *) reject_path "isolated test $label" "$path" ;; esac
    reject_symlink_components "$label" "$path"
    [[ -d "$path" && ! -L "$path" ]] || reject_path "isolated test $label" "$path"
    local physical
    physical="$(cd -P "$path" && pwd)" || reject_path "isolated test $label" "$path"
    [[ "$physical" == "$path" ]] || reject_path "canonical isolated test $label" "$path"
}

require_isolated_test_file_parent() {
    local label="$1"; local path="$2"
    require_isolated_test_directory "$label parent" "$(dirname "$path")"
}

path_exists() { [[ -e "$1" || -L "$1" ]]; }

require_isolated_test_regular_or_missing() {
    local label="$1"; local path="$2"
    validate_path "$label" "$path"
    case "$path" in /private/tmp/*) ;; *) reject_path "isolated test $label" "$path" ;; esac
    reject_symlink_components "$label" "$path"
    require_isolated_test_file_parent "$label" "$path"
    if path_exists "$path"; then
        [[ -f "$path" && ! -L "$path" ]] || reject_path "isolated test $label" "$path"
        local physical
        physical="$(realpath "$path")" || reject_path "isolated test $label" "$path"
        [[ "$physical" == "$path" ]] || reject_path "canonical isolated test $label" "$path"
    fi
}

require_isolated_test_state_files() {
    local leaf
    for leaf in state.sqlite3 state.sqlite3-wal state.sqlite3-shm; do
        require_isolated_test_regular_or_missing "Application Support $leaf" "$state_root/$leaf"
    done
}

lifecycle_call() {
    local action="$1"
    if [[ -n "$lifecycle_adapter" ]]; then
        "$lifecycle_adapter" "$action" "$bundle_identifier" "$installed_app" "$lifecycle_timeout"
    else
        /usr/bin/osascript -l JavaScript "$script_directory/companion-lifecycle.js" \
            "$action" "$bundle_identifier" "$installed_app" "$lifecycle_timeout"
    fi
}

case "$test_mode" in 0|1) ;; *) echo "HITW_INSTALL_TEST_MODE must be 0 or 1." >&2; exit 2 ;; esac
if [[ "$test_mode" == 0 ]]; then
    if [[ -n "$lifecycle_adapter_present" || -n "$fault_seam_present" || -n "$barrier_seam_present" \
        || -n "$fixture_state_present" || -n "$fixture_log_present" || -n "$fixture_mode_present" ]]
    then
        echo "Hard-disable test seams require HITW_INSTALL_TEST_MODE=1." >&2
        exit 2
    fi
else
    [[ -n "$state_override_present" && -n "${HITW_INSTALL_STATE_ROOT:-}" ]] \
        || { echo "Test mode requires explicit HITW_INSTALL_STATE_ROOT." >&2; exit 2; }
    [[ -n "$applications_override_present" && -n "${HITW_INSTALL_APPLICATIONS_DIR:-}" ]] \
        || { echo "Test mode requires explicit HITW_INSTALL_APPLICATIONS_DIR." >&2; exit 2; }
    [[ -n "$hooks_override_present" && -n "${HITW_INSTALL_HOOKS_FILE:-}" ]] \
        || { echo "Test mode requires explicit HITW_INSTALL_HOOKS_FILE." >&2; exit 2; }
    [[ -n "$lifecycle_adapter_present" && -n "$lifecycle_adapter" ]] \
        || { echo "Test mode requires explicit HITW_LIFECYCLE_ADAPTER." >&2; exit 2; }
    [[ -z "$fault_seam_present" && -z "$barrier_seam_present" ]] \
        || { echo "Hard-disable does not accept install fault or barrier seams." >&2; exit 2; }
fi
case "$lifecycle_timeout" in ''|*[!0-9]*) echo "Invalid lifecycle timeout." >&2; exit 2 ;; esac
if (( lifecycle_timeout < 1 || lifecycle_timeout > 30 )); then echo "Invalid lifecycle timeout." >&2; exit 2; fi
validate_path "Application Support" "$state_root"
validate_path "Applications" "$applications_directory"
validate_path "hooks file" "$hooks_file"
[[ "$(basename "$hooks_file")" == "hooks.json" ]] || reject_path "hooks file" "$hooks_file"
reject_symlink_components "Application Support" "$state_root"
reject_symlink_components "Applications" "$applications_directory"
reject_symlink_components "hooks file" "$hooks_file"
if [[ "$test_mode" == 1 ]]; then
    require_isolated_test_directory "Application Support" "$state_root"
    require_isolated_test_directory "Applications" "$applications_directory"
    require_isolated_test_state_files
    require_isolated_test_regular_or_missing "hooks file" "$hooks_file"
    require_isolated_test_regular_or_missing "installed control" "$installed_control"
    path_exists "$installed_control" || reject_path "isolated test installed control" "$installed_control"
    [[ -x "$installed_control" ]] || reject_path "isolated test installed control" "$installed_control"
    require_isolated_test_regular_or_missing "installed hook" "$installed_hook"
    validate_path "lifecycle adapter" "$lifecycle_adapter"
    reject_symlink_components "lifecycle adapter" "$lifecycle_adapter"
    [[ -f "$lifecycle_adapter" && -x "$lifecycle_adapter" ]] || reject_path "lifecycle adapter" "$lifecycle_adapter"
    adapter_physical="$(realpath "$lifecycle_adapter")" || reject_path "lifecycle adapter" "$lifecycle_adapter"
    [[ "$adapter_physical" == "$lifecycle_adapter" && "$adapter_physical" == /private/tmp/* ]] \
        || reject_path "test lifecycle adapter" "$lifecycle_adapter"
fi

if [[ ! -x "$installed_control" || -L "$installed_control" || ! -f "$installed_control" ]]; then
    echo "Installed hitwctl is missing or unsafe: $installed_control" >&2
    exit 1
fi

soft_off_failed=false
hook_failed=false
companion_failed=false
if ! HITW_STATE_ROOT="$state_root" "$installed_control" disable; then
    echo "Soft Off failed; continuing to remove the hook." >&2
    soft_off_failed=true
fi
if ! HITW_STATE_ROOT="$state_root" "$installed_control" uninstall-hook \
    --hooks-file "$hooks_file" --hook-binary "$installed_hook"
then
    echo "Could not remove the Human in the Whoop hook." >&2
    hook_failed=true
fi

probe_result="$(lifecycle_call probe)" || probe_result="error"
case "$probe_result" in
    stopped) ;;
    running)
        if [[ "$(lifecycle_call terminate)" != "stopped" ]]; then
            echo "Could not terminate the exact Human in the Whoop companion." >&2
            companion_failed=true
        fi
        ;;
    *)
        echo "Could not verify Human in the Whoop companion termination." >&2
        companion_failed=true
        ;;
esac

if [[ "$soft_off_failed" == true || "$hook_failed" == true || "$companion_failed" == true ]]; then
    echo "Hard-disable is incomplete." >&2
    [[ "$soft_off_failed" == true ]] && echo "- Soft Off was not confirmed." >&2
    [[ "$hook_failed" == true ]] && echo "- Hook removal was not confirmed." >&2
    [[ "$companion_failed" == true ]] && echo "- Companion termination was not confirmed." >&2
    echo "Do not assume Human in the Whoop is fully disabled." >&2
    exit 1
fi

echo "Human in the Whoop is hard-disabled. Local database and Keychain credentials were preserved."
echo "Restart Codex or start a new Codex process so it reloads hooks.json."
