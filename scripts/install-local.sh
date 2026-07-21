#!/bin/bash

set -euo pipefail

script_directory="$(cd -P "$(dirname "$0")" && pwd)"
repository_root="$(cd -P "$script_directory/.." && pwd)"
app_name="Human in the Whoop.app"
bundle_identifier="com.randyhaddad.human-in-the-whoop"
applications_override_present="${HITW_INSTALL_APPLICATIONS_DIR+x}"
state_override_present="${HITW_INSTALL_STATE_ROOT+x}"
hooks_override_present="${HITW_INSTALL_HOOKS_FILE+x}"
package_override_present="${HITW_PACKAGE_CACHE_ROOT+x}"
lifecycle_adapter_present="${HITW_LIFECYCLE_ADAPTER+x}"
fault_seam_present="${HITW_INSTALL_TEST_FAIL_AT+x}"
barrier_seam_present="${HITW_INSTALL_TEST_BARRIER_DIR+x}"
fixture_state_present="${HITW_TEST_LIFECYCLE_STATE+x}"
fixture_log_present="${HITW_TEST_LIFECYCLE_LOG+x}"
fixture_mode_present="${HITW_TEST_LIFECYCLE_MODE+x}"
applications_directory="${HITW_INSTALL_APPLICATIONS_DIR:-$HOME/Applications}"
state_root="${HITW_INSTALL_STATE_ROOT:-$HOME/Library/Application Support/Human in the Whoop}"
hooks_file="${HITW_INSTALL_HOOKS_FILE:-$HOME/.codex/hooks.json}"
lifecycle_adapter="${HITW_LIFECYCLE_ADAPTER:-}"
lifecycle_timeout="${HITW_LIFECYCLE_TIMEOUT_SECONDS:-5}"
test_mode="${HITW_INSTALL_TEST_MODE:-0}"
expected_package_root="${HITW_PACKAGE_CACHE_ROOT:-$HOME/Library/Caches/com.randyhaddad.human-in-the-whoop/package}"
installed_app="$applications_directory/$app_name"
bin_directory="$state_root/bin"
installed_control="$bin_directory/hitwctl"
installed_hook="$bin_directory/hitw-hook"

reject_path() {
    echo "Refusing unsafe $1 path: $2" >&2
    if [[ "${compensation_mode:-false}" == true ]]; then return 1; fi
    exit 2
}

validate_destination() {
    local label="$1"
    local path="$2"
    if [[ -z "$path" || "$path" != /* ]]; then reject_path "$label" "$path"; fi
    case "$path" in *//*|*/../*|*/..|*/./*|*/.|*/) reject_path "$label" "$path" ;; esac
    case "$path" in /|/Users|/Library|/System|/Applications|/tmp|/private|/private/tmp|"$HOME") reject_path "$label" "$path" ;; esac
    if [[ "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then reject_path "$label" "$path"; fi
}

reject_symlink_components() {
    local label="$1"
    local path="$2"
    local allow_final_symlink="${3:-0}"
    local remainder="${path#/}"
    local current=""
    local old_ifs="$IFS"
    local components=()
    IFS='/' read -r -a components <<< "$remainder"
    IFS="$old_ifs"
    local last_index=$((${#components[@]} - 1))
    local index
    for index in "${!components[@]}"; do
        current="$current/${components[$index]}"
        if [[ -L "$current" ]]; then
            if [[ "$allow_final_symlink" == 1 && "$index" == "$last_index" ]]; then return 0; fi
            reject_path "$label symbolic-link component" "$current"
            return 1
        fi
        if [[ -e "$current" && "$index" != "$last_index" && ! -d "$current" ]]; then
            reject_path "$label non-directory component" "$current"
            return 1
        fi
        if [[ ! -e "$current" ]]; then return 0; fi
    done
}

path_exists() { [[ -e "$1" || -L "$1" ]]; }

require_isolated_test_directory() {
    local label="$1"
    local path="$2"
    validate_destination "$label" "$path"
    case "$path" in /private/tmp/*) ;; *) reject_path "isolated test $label" "$path" ;; esac
    reject_symlink_components "$label" "$path"
    [[ -d "$path" && ! -L "$path" ]] || reject_path "isolated test $label" "$path"
    local physical
    physical="$(cd -P "$path" && pwd)" || reject_path "isolated test $label" "$path"
    [[ "$physical" == "$path" ]] || reject_path "canonical isolated test $label" "$path"
}

require_isolated_test_file_parent() {
    local label="$1"
    local path="$2"
    require_isolated_test_directory "$label parent" "$(dirname "$path")"
}

require_isolated_test_regular_or_missing() {
    local label="$1"
    local path="$2"
    validate_destination "$label" "$path"
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

validate_lifecycle_settings() {
    case "$lifecycle_timeout" in ''|*[!0-9]*) echo "Invalid lifecycle timeout." >&2; exit 2 ;; esac
    if (( lifecycle_timeout < 1 || lifecycle_timeout > 30 )); then
        echo "Lifecycle timeout must be between 1 and 30 seconds." >&2
        exit 2
    fi
    if [[ -n "$lifecycle_adapter" ]]; then
        [[ "$test_mode" == 1 ]] || { echo "HITW_LIFECYCLE_ADAPTER is test-only." >&2; exit 2; }
        validate_destination "lifecycle adapter" "$lifecycle_adapter"
        reject_symlink_components "lifecycle adapter" "$lifecycle_adapter"
        [[ -f "$lifecycle_adapter" && -x "$lifecycle_adapter" ]] || reject_path "lifecycle adapter" "$lifecycle_adapter"
        adapter_physical="$(realpath "$lifecycle_adapter")" || reject_path "lifecycle adapter" "$lifecycle_adapter"
        [[ "$adapter_physical" == "$lifecycle_adapter" && "$adapter_physical" == /private/tmp/* ]] \
            || reject_path "test lifecycle adapter" "$lifecycle_adapter"
    fi
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

launch_and_verify() {
    if [[ -n "$lifecycle_adapter" ]]; then
        "$lifecycle_adapter" launch "$bundle_identifier" "$installed_app" "$lifecycle_timeout" >/dev/null
    else
        /usr/bin/open "$installed_app"
    fi
    [[ "$(lifecycle_call wait-running)" == "running" ]]
}

case "$test_mode" in 0|1) ;; *) echo "HITW_INSTALL_TEST_MODE must be 0 or 1." >&2; exit 2 ;; esac
if [[ "$test_mode" == 0 ]]; then
    if [[ -n "$lifecycle_adapter_present" || -n "$fault_seam_present" || -n "$barrier_seam_present" \
        || -n "$fixture_state_present" || -n "$fixture_log_present" || -n "$fixture_mode_present" ]]
    then
        echo "Install test seams require HITW_INSTALL_TEST_MODE=1." >&2
        exit 2
    fi
else
    [[ -n "$applications_override_present" && -n "${HITW_INSTALL_APPLICATIONS_DIR:-}" ]] \
        || { echo "Test mode requires explicit HITW_INSTALL_APPLICATIONS_DIR." >&2; exit 2; }
    [[ -n "$state_override_present" && -n "${HITW_INSTALL_STATE_ROOT:-}" ]] \
        || { echo "Test mode requires explicit HITW_INSTALL_STATE_ROOT." >&2; exit 2; }
    [[ -n "$hooks_override_present" && -n "${HITW_INSTALL_HOOKS_FILE:-}" ]] \
        || { echo "Test mode requires explicit HITW_INSTALL_HOOKS_FILE." >&2; exit 2; }
    [[ -n "$package_override_present" && -n "${HITW_PACKAGE_CACHE_ROOT:-}" ]] \
        || { echo "Test mode requires explicit HITW_PACKAGE_CACHE_ROOT." >&2; exit 2; }
    [[ -n "$lifecycle_adapter_present" && -n "$lifecycle_adapter" ]] \
        || { echo "Test mode requires explicit HITW_LIFECYCLE_ADAPTER." >&2; exit 2; }
    if [[ -n "$fault_seam_present" && -z "${HITW_INSTALL_TEST_FAIL_AT:-}" ]]; then
        echo "HITW_INSTALL_TEST_FAIL_AT cannot be empty when present." >&2
        exit 2
    fi
    if [[ -n "$barrier_seam_present" && -z "${HITW_INSTALL_TEST_BARRIER_DIR:-}" ]]; then
        echo "HITW_INSTALL_TEST_BARRIER_DIR cannot be empty when present." >&2
        exit 2
    fi
    require_isolated_test_directory "Applications" "$applications_directory"
    require_isolated_test_directory "Application Support" "$state_root"
    require_isolated_test_state_files
    require_isolated_test_regular_or_missing "hooks file" "$hooks_file"
    require_isolated_test_directory "package cache" "$expected_package_root"
    if [[ -n "$barrier_seam_present" && -n "${HITW_INSTALL_TEST_BARRIER_DIR:-}" ]]; then
        require_isolated_test_directory "test barrier" "$HITW_INSTALL_TEST_BARRIER_DIR"
    fi
fi
validate_destination "Applications" "$applications_directory"
validate_destination "Application Support" "$state_root"
validate_destination "hooks file" "$hooks_file"
[[ "$(basename "$hooks_file")" == "hooks.json" ]] || reject_path "hooks file" "$hooks_file"
validate_lifecycle_settings
reject_symlink_components "Applications" "$applications_directory"
reject_symlink_components "Application Support" "$state_root"
reject_symlink_components "hooks file" "$hooks_file"

cd "$repository_root"
"$script_directory/package-app.sh" >/dev/null
swift build -c release --product hitw-hook
swift build -c release --product hitwctl
binary_directory="$(swift build -c release --show-bin-path)"
packaged_link="$repository_root/.build/release/$app_name"

path_exists "$packaged_link" || { echo "Packaged app is missing: $packaged_link" >&2; exit 1; }
validate_destination "package cache" "$expected_package_root"
reject_symlink_components "package cache" "$expected_package_root"
packaged_app="$(realpath "$packaged_link")" || { echo "Could not resolve packaged app." >&2; exit 1; }
[[ "$packaged_app" == "$expected_package_root/$app_name" ]] || reject_path "packaged app target" "$packaged_app"
reject_symlink_components "packaged app" "$packaged_app"
codesign --verify --deep --strict "$packaged_app"
for binary in "$binary_directory/hitwctl" "$binary_directory/hitw-hook"; do
    reject_symlink_components "release binary" "$binary"
    [[ -f "$binary" && ! -L "$binary" ]] || { echo "Release binary is missing or unsafe: $binary" >&2; exit 1; }
done

mkdir -p "$applications_directory" "$bin_directory" "$(dirname "$hooks_file")"
reject_symlink_components "Applications" "$applications_directory"
reject_symlink_components "Application Support" "$state_root"
reject_symlink_components "bin directory" "$bin_directory"
reject_symlink_components "hooks file" "$hooks_file"
chmod 700 "$bin_directory"

# Test-only barrier used to prove an observed ancestor swap aborts before any
# install mutation. Production leaves this unset.
if [[ -n "${HITW_INSTALL_TEST_BARRIER_DIR:-}" ]]; then
    barrier_directory="$HITW_INSTALL_TEST_BARRIER_DIR"
    validate_destination "test barrier" "$barrier_directory"
    reject_symlink_components "test barrier" "$barrier_directory"
    [[ -d "$barrier_directory" ]] || reject_path "test barrier" "$barrier_directory"
    touch "$barrier_directory/ready"
    barrier_count=0
    while [[ ! -e "$barrier_directory/continue" && "$barrier_count" -lt 100 ]]; do
        sleep 0.05
        barrier_count=$((barrier_count + 1))
    done
    [[ -e "$barrier_directory/continue" ]] || { echo "Install test barrier timed out." >&2; exit 1; }
    reject_symlink_components "Applications" "$applications_directory"
    reject_symlink_components "Application Support" "$state_root"
    reject_symlink_components "hooks file" "$hooks_file"
fi

staged_app="$applications_directory/.Human in the Whoop.app.installing.$$"
staged_control="$bin_directory/.hitwctl.installing.$$"
staged_hook="$bin_directory/.hitw-hook.installing.$$"
app_backup="$applications_directory/.Human in the Whoop.app.backup.$$"
control_backup="$bin_directory/.hitwctl.backup.$$"
hook_backup="$bin_directory/.hitw-hook.backup.$$"

remove_exact_artifact() {
    local artifact="$1"
    case "$artifact" in
        "$installed_app"|"$staged_app"|"$app_backup") ;;
        "$installed_control"|"$installed_hook"|"$staged_control"|"$staged_hook"|"$control_backup"|"$hook_backup") ;;
        *) echo "Refusing to remove unexpected install artifact: $artifact" >&2; return 1 ;;
    esac
    reject_symlink_components "install artifact parent" "$(dirname "$artifact")"
    if [[ -L "$artifact" || -f "$artifact" ]]; then
        rm -f "$artifact"
    elif [[ -d "$artifact" ]]; then
        rm -rf "$artifact"
    elif [[ -e "$artifact" ]]; then
        echo "Refusing nonregular install artifact: $artifact" >&2
        return 1
    fi
}

for artifact in "$staged_app" "$staged_control" "$staged_hook" "$app_backup" "$control_backup" "$hook_backup"; do
    if path_exists "$artifact"; then echo "Refusing existing install staging artifact: $artifact" >&2; exit 1; fi
done
if path_exists "$installed_app" && [[ ! -d "$installed_app" || -L "$installed_app" ]]; then reject_path "installed app" "$installed_app"; fi
for binary in "$installed_control" "$installed_hook"; do
    if path_exists "$binary" && [[ ! -f "$binary" || -L "$binary" ]]; then reject_path "installed binary" "$binary"; fi
done

app_prior_moved=false; app_new_installed=false
control_prior_moved=false; control_new_installed=false
hook_prior_moved=false; hook_new_installed=false
prior_app_running=false
completed=false
compensation_failed=false
compensation_failures=()
compensation_mode=false

record_compensation_failure() {
    compensation_failed=true
    compensation_failures+=("$1")
}

restore_previous_install() {
    if [[ "$hook_new_installed" == true ]] && path_exists "$installed_hook"; then
        remove_exact_artifact "$installed_hook" || record_compensation_failure "new hook binary could not be removed"
    fi
    if [[ "$hook_prior_moved" == true ]]; then
        if ! path_exists "$hook_backup" || path_exists "$installed_hook" || ! mv "$hook_backup" "$installed_hook"; then
            record_compensation_failure "prior hook binary could not be restored"
        fi
    fi
    if [[ "$control_new_installed" == true ]] && path_exists "$installed_control"; then
        remove_exact_artifact "$installed_control" || record_compensation_failure "new control binary could not be removed"
    fi
    if [[ "$control_prior_moved" == true ]]; then
        if ! path_exists "$control_backup" || path_exists "$installed_control" || ! mv "$control_backup" "$installed_control"; then
            record_compensation_failure "prior control binary could not be restored"
        fi
    fi
    if [[ "$app_new_installed" == true ]] && path_exists "$installed_app"; then
        remove_exact_artifact "$installed_app" || record_compensation_failure "new companion app could not be removed"
    fi
    if [[ "$app_prior_moved" == true ]]; then
        if ! path_exists "$app_backup" || path_exists "$installed_app" || ! mv "$app_backup" "$installed_app"; then
            record_compensation_failure "prior companion app could not be restored"
        fi
    fi
    if [[ "$prior_app_running" == true ]]; then
        if [[ ! -d "$installed_app" ]]; then
            record_compensation_failure "prior running companion is missing"
        else
            restored_probe="$(lifecycle_call probe 2>/dev/null)" || restored_probe="error"
            if [[ "$restored_probe" != "running" ]] && ! launch_and_verify >/dev/null 2>&1; then
                record_compensation_failure "prior running companion could not be relaunched"
            fi
        fi
    fi
}

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    compensation_mode=true
    if [[ "$completed" != true ]]; then restore_previous_install; fi
    remove_exact_artifact "$staged_app" || record_compensation_failure "staged app could not be removed"
    remove_exact_artifact "$staged_control" || record_compensation_failure "staged control binary could not be removed"
    remove_exact_artifact "$staged_hook" || record_compensation_failure "staged hook binary could not be removed"
    if [[ "$compensation_failed" == true ]]; then
        echo "Installation failed; app/binary/lifecycle compensation is incomplete." >&2
        for failure in "${compensation_failures[@]}"; do echo "- $failure" >&2; done
        exit 3
    fi
    exit "$status"
}
trap cleanup EXIT

# Restoration is armed before the first lifecycle mutation. If termination
# reports an error after the process already exited, cleanup restores the prior
# running state or clearly reports incomplete compensation.
if ! probe_result="$(lifecycle_call probe)"; then
    echo "Could not determine companion lifecycle state." >&2
    exit 1
fi
case "$probe_result" in
    running)
        prior_app_running=true
        if ! termination_result="$(lifecycle_call terminate)" || [[ "$termination_result" != "stopped" ]]; then
            echo "Could not terminate the exact installed companion." >&2
            exit 1
        fi
        ;;
    stopped) ;;
    *) echo "Could not determine companion lifecycle state." >&2; exit 1 ;;
esac

ditto --norsrc "$packaged_app" "$staged_app"
codesign --verify --deep --strict "$staged_app"
install -m 0755 "$binary_directory/hitwctl" "$staged_control"
install -m 0755 "$binary_directory/hitw-hook" "$staged_hook"

if path_exists "$installed_app"; then mv "$installed_app" "$app_backup"; app_prior_moved=true; fi
mv "$staged_app" "$installed_app"; app_new_installed=true
codesign --verify --deep --strict "$installed_app"
if path_exists "$installed_control"; then mv "$installed_control" "$control_backup"; control_prior_moved=true; fi
mv "$staged_control" "$installed_control"; control_new_installed=true
if path_exists "$installed_hook"; then mv "$installed_hook" "$hook_backup"; hook_prior_moved=true; fi
mv "$staged_hook" "$installed_hook"; hook_new_installed=true

# One bounded local coordinator performs exact Soft Off plus hook mutation. It
# never calls WHOOP; reported failures restore the full prior ledger and exact
# hook bytes/absence before this shell restores app and binaries.
set +e
HITW_STATE_ROOT="$state_root" "$installed_control" install-soft-off-hook \
    --hooks-file "$hooks_file" --hook-binary "$installed_hook"
coordinator_status=$?
set -e
case "$coordinator_status" in
    0) ;;
    3)
        echo "Ledger/hook compensation is incomplete; app/binary/lifecycle compensation will still be attempted." >&2
        exit 3
        ;;
    *) exit "$coordinator_status" ;;
esac

completed=true
for backup in "$app_backup" "$control_backup" "$hook_backup"; do
    if path_exists "$backup"; then remove_exact_artifact "$backup" || echo "Installed successfully; remove stale backup manually: $backup" >&2; fi
done

if ! launch_and_verify; then
    echo "Installation committed, but the exact installed companion could not be launched and verified." >&2
    exit 1
fi

echo "Installed Human in the Whoop in Soft Off mode."
echo "Restart Codex or start a new Codex process, then review and trust the hook through /hooks or Codex's hook review UI."
