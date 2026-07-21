#!/bin/bash

set -euo pipefail

script_directory="$(cd -P "$(dirname "$0")" && pwd)"
installer="$script_directory/install-local.sh"
hard_disable="$script_directory/hard-disable.sh"
package_script="$script_directory/package-app.sh"
lifecycle_adapter_source="$script_directory/test-fixtures/lifecycle-adapter.sh"
recording_control_source="$script_directory/test-fixtures/recording-hitwctl.sh"
test_root="$(mktemp -d /private/tmp/hitw-local-controls-test.XXXXXX)"
lifecycle_adapter="$test_root/lifecycle-adapter.sh"
applications_directory="$test_root/Applications"
state_root="$test_root/Application Support/Human in the Whoop"
hooks_file="$test_root/.codex/hooks.json"
config_file="$test_root/.codex/config.toml"
package_cache_root="$test_root/package-cache"
installed_app="$applications_directory/Human in the Whoop.app"
installed_control="$state_root/bin/hitwctl"
installed_hook="$state_root/bin/hitw-hook"
lifecycle_state="$test_root/lifecycle.state"
lifecycle_log="$test_root/lifecycle.log"

fail() { echo "$1" >&2; exit 1; }
path_exists() { [[ -e "$1" || -L "$1" ]]; }

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    "$package_script" >/dev/null
    rm -rf "$test_root"
    rm -rf "/private/var/tmp/hitw-local-controls-negative.$$"
    rm -rf "/private/var/tmp/hitw-hard-disable-negative.$$"
    exit "$status"
}
trap cleanup EXIT

bash -n "$installer"
bash -n "$hard_disable"
osacompile -l JavaScript -o "$test_root/lifecycle.scpt" "$script_directory/companion-lifecycle.js"
cp "$lifecycle_adapter_source" "$lifecycle_adapter"
chmod 755 "$lifecycle_adapter"

mkdir -p "$applications_directory" "$state_root" "$(dirname "$hooks_file")" "$package_cache_root"
printf '%s\n' '{"future":true,"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/tmp/keep"}]}]}}' > "$hooks_file"
printf '%s\n' 'model = "keep-this-config-unchanged"' > "$config_file"
printf '%s\n' stopped > "$lifecycle_state"
: > "$lifecycle_log"
config_checksum="$(shasum -a 256 "$config_file" | awk '{print $1}')"

export HITW_TEST_LIFECYCLE_STATE="$lifecycle_state"
export HITW_TEST_LIFECYCLE_LOG="$lifecycle_log"
export HITW_TEST_LIFECYCLE_MODE=normal
export HITW_INSTALL_TEST_MODE=1

# Test mode alone is a closed boundary: every destination and adapter must be
# explicit. Invalid timeout is a harmless backstop if a presence guard regresses.
fake_home="$test_root/fake-home"
mkdir -p "$fake_home/Applications" \
    "$fake_home/Library/Application Support/Human in the Whoop" \
    "$fake_home/Library/Caches/com.randyhaddad.human-in-the-whoop/package" \
    "$fake_home/.codex"

expect_explicit_test_override() {
    local script="$1"; local omitted="$2"; local stderr_file="$test_root/omitted-$omitted.stderr"
    set +e
    (
        export HOME="$fake_home"
        export HITW_INSTALL_TEST_MODE=1
        export HITW_INSTALL_APPLICATIONS_DIR="$applications_directory"
        export HITW_INSTALL_STATE_ROOT="$state_root"
        export HITW_INSTALL_HOOKS_FILE="$hooks_file"
        export HITW_PACKAGE_CACHE_ROOT="$package_cache_root"
        export HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter"
        export HITW_LIFECYCLE_TIMEOUT_SECONDS=0
        unset "$omitted"
        "$script"
    ) >/dev/null 2>"$stderr_file"
    local status=$?
    set -e
    [[ "$status" != 0 ]] || fail "$(basename "$script") accepted omitted $omitted."
    grep -Fq "$omitted" "$stderr_file" || fail "$(basename "$script") did not identify omitted $omitted."
}

for omitted in HITW_INSTALL_APPLICATIONS_DIR HITW_INSTALL_STATE_ROOT HITW_INSTALL_HOOKS_FILE HITW_PACKAGE_CACHE_ROOT HITW_LIFECYCLE_ADAPTER; do
    expect_explicit_test_override "$installer" "$omitted"
done
for omitted in HITW_INSTALL_APPLICATIONS_DIR HITW_INSTALL_STATE_ROOT HITW_INSTALL_HOOKS_FILE HITW_LIFECYCLE_ADAPTER; do
    expect_explicit_test_override "$hard_disable" "$omitted"
done

expect_mode_zero_seam_rejected() {
    local script="$1"; local seam="$2"; local stderr_file="$test_root/mode-zero-$seam.stderr"
    set +e
    (
        export HOME="$fake_home"
        unset HITW_INSTALL_TEST_MODE HITW_LIFECYCLE_ADAPTER HITW_INSTALL_TEST_FAIL_AT HITW_INSTALL_TEST_BARRIER_DIR
        unset HITW_TEST_LIFECYCLE_STATE HITW_TEST_LIFECYCLE_LOG HITW_TEST_LIFECYCLE_MODE
        export HITW_LIFECYCLE_TIMEOUT_SECONDS=0
        env "$seam=" "$script"
    ) >/dev/null 2>"$stderr_file"
    local status=$?
    set -e
    [[ "$status" != 0 ]] || fail "$(basename "$script") accepted mode-zero seam $seam."
    grep -Fq "test seams" "$stderr_file" || fail "$(basename "$script") did not reject mode-zero seam $seam upfront."
}

for seam in HITW_LIFECYCLE_ADAPTER HITW_INSTALL_TEST_FAIL_AT HITW_INSTALL_TEST_BARRIER_DIR HITW_TEST_LIFECYCLE_STATE HITW_TEST_LIFECYCLE_LOG HITW_TEST_LIFECYCLE_MODE; do
    expect_mode_zero_seam_rejected "$installer" "$seam"
    expect_mode_zero_seam_rejected "$hard_disable" "$seam"
done

for seam in HITW_INSTALL_TEST_FAIL_AT HITW_INSTALL_TEST_BARRIER_DIR; do
    empty_seam_stderr="$test_root/empty-$seam.stderr"
    set +e
    env "$seam=" \
        HITW_INSTALL_TEST_MODE=1 \
        HITW_INSTALL_APPLICATIONS_DIR="$applications_directory" \
        HITW_INSTALL_STATE_ROOT="$state_root" \
        HITW_INSTALL_HOOKS_FILE="$hooks_file" \
        HITW_PACKAGE_CACHE_ROOT="$package_cache_root" \
        HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
        HITW_LIFECYCLE_TIMEOUT_SECONDS=0 \
            "$installer" >/dev/null 2>"$empty_seam_stderr"
    empty_seam_status=$?
    set -e
    [[ "$empty_seam_status" != 0 ]] || fail "Installer accepted empty test seam $seam."
    grep -Fq "cannot be empty" "$empty_seam_stderr" || fail "Installer did not reject empty test seam $seam upfront."
done

run_install() {
    local fault="${1:-}"
    if [[ -n "$fault" ]]; then
        HITW_INSTALL_APPLICATIONS_DIR="$applications_directory" \
        HITW_INSTALL_STATE_ROOT="$state_root" \
        HITW_INSTALL_HOOKS_FILE="$hooks_file" \
        HITW_PACKAGE_CACHE_ROOT="$package_cache_root" \
        HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
        HITW_LIFECYCLE_TIMEOUT_SECONDS="${HITW_TEST_INSTALL_TIMEOUT:-5}" \
        HITW_INSTALL_TEST_FAIL_AT="$fault" \
            "$installer"
    else
        HITW_INSTALL_APPLICATIONS_DIR="$applications_directory" \
        HITW_INSTALL_STATE_ROOT="$state_root" \
        HITW_INSTALL_HOOKS_FILE="$hooks_file" \
        HITW_PACKAGE_CACHE_ROOT="$package_cache_root" \
        HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
        HITW_LIFECYCLE_TIMEOUT_SECONDS="${HITW_TEST_INSTALL_TIMEOUT:-5}" \
            "$installer"
    fi
}

# Production/live invocations cannot replace lifecycle control with an
# arbitrary executable, even when all destinations themselves are temporary.
if env -u HITW_INSTALL_TEST_MODE \
    HITW_INSTALL_APPLICATIONS_DIR="$applications_directory" \
    HITW_INSTALL_STATE_ROOT="$state_root" \
    HITW_INSTALL_HOOKS_FILE="$hooks_file" \
    HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
        "$installer" >/dev/null 2>&1
then
    fail "Installer accepted a lifecycle adapter outside explicit test mode."
fi

# A test seam cannot redirect even one mutation boundary outside its canonical
# /private/tmp fixture, regardless of where the adapter and other roots live.
nonisolated_root="/private/var/tmp/hitw-local-controls-negative.$$"

# Hard-disable must reject test mode with nonisolated roots and no adapter
# before executing even a fixture control binary.
hard_disable_nonisolated_root="/private/var/tmp/hitw-hard-disable-negative.$$"
nonisolated_disable_stderr="$test_root/nonisolated-disable.stderr"
mkdir -p "$hard_disable_nonisolated_root/state/bin" "$hard_disable_nonisolated_root/Applications" "$hard_disable_nonisolated_root/hooks"
cp "$recording_control_source" "$hard_disable_nonisolated_root/state/bin/hitwctl"
chmod 755 "$hard_disable_nonisolated_root/state/bin/hitwctl"
if HITW_INSTALL_TEST_MODE=1 \
    HITW_INSTALL_STATE_ROOT="$hard_disable_nonisolated_root/state" \
    HITW_INSTALL_APPLICATIONS_DIR="$hard_disable_nonisolated_root/Applications" \
    HITW_INSTALL_HOOKS_FILE="$hard_disable_nonisolated_root/hooks/hooks.json" \
    HITW_LIFECYCLE_TIMEOUT_SECONDS=0 \
        "$hard_disable" >/dev/null 2>"$nonisolated_disable_stderr"
then
    fail "Hard-disable accepted nonisolated test mode without an adapter."
fi
grep -Fq "HITW_LIFECYCLE_ADAPTER" "$nonisolated_disable_stderr" \
    || fail "Hard-disable did not reject the omitted test adapter upfront."
if grep -Fq 'hitwctl|' "$lifecycle_log"; then fail "Rejected hard-disable test mode executed hitwctl."; fi

# A canonical temporary root is still unsafe when SQLite would follow a leaf
# symlink. Reject it before the fixture control binary can run.
for database_leaf in state.sqlite3 state.sqlite3-wal state.sqlite3-shm; do
    unsafe_disable_root="$test_root/unsafe-hard-disable-$database_leaf"
    unsafe_disable_state="$unsafe_disable_root/state"
    unsafe_disable_apps="$unsafe_disable_root/Applications"
    unsafe_disable_hooks="$unsafe_disable_root/hooks/hooks.json"
    unsafe_disable_sentinel="$unsafe_disable_root/outside.sqlite3"
    mkdir -p "$unsafe_disable_state/bin" "$unsafe_disable_apps" "$(dirname "$unsafe_disable_hooks")"
    cp "$recording_control_source" "$unsafe_disable_state/bin/hitwctl"
    chmod 755 "$unsafe_disable_state/bin/hitwctl"
    printf '%s\n' outside-sqlite-sentinel > "$unsafe_disable_sentinel"
    ln -s "$unsafe_disable_sentinel" "$unsafe_disable_state/$database_leaf"
    if HITW_INSTALL_TEST_MODE=1 \
        HITW_INSTALL_STATE_ROOT="$unsafe_disable_state" \
        HITW_INSTALL_APPLICATIONS_DIR="$unsafe_disable_apps" \
        HITW_INSTALL_HOOKS_FILE="$unsafe_disable_hooks" \
        HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
            "$hard_disable" >/dev/null 2>&1
    then
        fail "Hard-disable accepted a symlinked test database leaf $database_leaf."
    fi
    if grep -Fq 'hitwctl|' "$lifecycle_log"; then fail "Symlinked $database_leaf executed hitwctl."; fi
    [[ "$(sed -n '1p' "$unsafe_disable_sentinel")" == outside-sqlite-sentinel ]] \
        || fail "Hard-disable changed the $database_leaf symlink referent."
done

expect_install_test_roots_rejected() {
    local label="$1"; local applications="$2"; local state="$3"; local hooks="$4"; local package_cache="$5"
    if HITW_INSTALL_APPLICATIONS_DIR="$applications" \
        HITW_INSTALL_STATE_ROOT="$state" \
        HITW_INSTALL_HOOKS_FILE="$hooks" \
        HITW_PACKAGE_CACHE_ROOT="$package_cache" \
        HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
            "$installer" >/dev/null 2>&1
    then
        fail "Installer accepted a nonisolated $label boundary in test mode."
    fi
}
expect_install_test_roots_rejected Applications "$nonisolated_root/Applications" "$state_root" "$hooks_file" "$package_cache_root"
expect_install_test_roots_rejected state "$applications_directory" "$nonisolated_root/state" "$hooks_file" "$package_cache_root"
expect_install_test_roots_rejected hooks "$applications_directory" "$state_root" "$nonisolated_root/hooks.json" "$package_cache_root"
expect_install_test_roots_rejected package "$applications_directory" "$state_root" "$hooks_file" "$nonisolated_root/package"
[[ ! -e "$nonisolated_root" ]] || fail "Rejected nonisolated test roots were mutated."

artifact_snapshot() {
    local app_hash control_hash hook_hash
    app_hash="$(find "$installed_app" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')"
    control_hash="$(shasum -a 256 "$installed_control" | awk '{print $1}')"
    hook_hash="$(shasum -a 256 "$installed_hook" | awk '{print $1}')"
    printf '%s|%s|%s\n' "$app_hash" "$control_hash" "$hook_hash"
}

# Static nested symlink traversal is refused before build/install writes.
protected_destination="$test_root/protected-destination"
linked_parent="$test_root/linked-parent"
mkdir -p "$protected_destination"
ln -s "$protected_destination" "$linked_parent"
if HITW_INSTALL_APPLICATIONS_DIR="$linked_parent/nested/Applications" \
    HITW_INSTALL_STATE_ROOT="$test_root/symlink-check-state" \
    HITW_INSTALL_HOOKS_FILE="$test_root/symlink-check-hooks/hooks.json" \
    HITW_PACKAGE_CACHE_ROOT="$package_cache_root" \
    HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
        "$installer" >/dev/null 2>&1
then
    fail "Installer accepted an intermediate symbolic-link destination."
fi
[[ -z "$(find "$protected_destination" -mindepth 1 -print -quit)" ]] || fail "Installer wrote through an intermediate symlink."

run_install >/dev/null
[[ -d "$installed_app" && ! -L "$installed_app" ]] || fail "Installer did not create a real app directory."
codesign --verify --deep --strict "$installed_app" || fail "Installed app signature is invalid."
[[ -x "$installed_control" && ! -L "$installed_control" ]] || fail "Installed hitwctl is unsafe."
[[ -x "$installed_hook" && ! -L "$installed_hook" ]] || fail "Installed hitw-hook is unsafe."
installed_status="$(HITW_STATE_ROOT="$state_root" "$installed_control" status --json)"
[[ "$installed_status" == *'"feature":"off"'* ]] || fail "Installer did not leave Soft Off."
[[ "$(sed -n '1p' "$lifecycle_state")" == "running|$installed_app" ]] || fail "Installer did not verify exact installed app launch."
rg -q '"PreToolUse"' "$hooks_file" || fail "Installer removed an unrelated hook event."
rg -q '"future"[[:space:]]*:[[:space:]]*true' "$hooks_file" || fail "Installer removed an unknown field."
handler_count="$(rg -F -o "$installed_hook" "$hooks_file" | wc -l | tr -d ' ')"
[[ "$handler_count" == 1 ]] || fail "Installer did not add exactly one handler."
[[ "$(shasum -a 256 "$config_file" | awk '{print $1}')" == "$config_checksum" ]] || fail "Installer changed config.toml."

# Upgrade must terminate the exact old installed app, wait, and relaunch the new one.
: > "$lifecycle_log"
run_install >/dev/null
grep -Fq "terminate|com.randyhaddad.human-in-the-whoop|$installed_app|" "$lifecycle_log" || fail "Upgrade did not terminate exact installed app."
grep -Fq "launch|com.randyhaddad.human-in-the-whoop|$installed_app|" "$lifecycle_log" || fail "Upgrade did not launch exact installed app."

# Refused and slow/refused termination abort before any installed artifact changes.
before_refusal="$(artifact_snapshot)"
for mode in refuse-terminate slow-refuse-terminate; do
    export HITW_TEST_LIFECYCLE_MODE="$mode"
    if [[ "$mode" == slow-refuse-terminate ]]; then export HITW_TEST_INSTALL_TIMEOUT=1; fi
    if run_install >/dev/null 2>&1; then fail "Installer accepted $mode."; fi
    [[ "$(artifact_snapshot)" == "$before_refusal" ]] || fail "$mode changed installed artifacts."
    unset HITW_TEST_INSTALL_TIMEOUT || true
done
export HITW_TEST_LIFECYCLE_MODE=normal

# If termination reports an error after the old process has already exited,
# the already-armed trap must restore its running state.
export HITW_TEST_LIFECYCLE_MODE=terminate-then-error
if run_install >/dev/null 2>&1; then fail "Termination-error-after-exit unexpectedly succeeded."; fi
[[ "$(artifact_snapshot)" == "$before_refusal" ]] || fail "Termination-error-after-exit changed installed artifacts."
[[ "$(sed -n '1p' "$lifecycle_state")" == "running|$installed_app" ]] || fail "Termination-error-after-exit left prior app stopped."
export HITW_TEST_LIFECYCLE_MODE=normal

# A coordinator failure plus refused relaunch must report incomplete
# compensation instead of claiming exact restoration.
compensation_stderr="$test_root/compensation-refused.stderr"
export HITW_TEST_LIFECYCLE_MODE=refuse-launch
if run_install after-disable >/dev/null 2>"$compensation_stderr"; then fail "Refused compensation relaunch unexpectedly succeeded."; fi
grep -Fq "compensation is incomplete" "$compensation_stderr" || fail "Refused relaunch did not report incomplete compensation."
[[ "$(sed -n '1p' "$lifecycle_state")" == stopped ]] || fail "Refused relaunch fixture did not leave an observable stopped state."
export HITW_TEST_LIFECYCLE_MODE=normal
"$lifecycle_adapter" launch "com.randyhaddad.human-in-the-whoop" "$installed_app" 5 >/dev/null

# Coordinator-level ledger/hook compensation is distinct from the shell's
# app/binary/lifecycle compensation and must remain explicit through the shell.
coordinator_compensation_stderr="$test_root/coordinator-compensation.stderr"
set +e
run_install compensation-conflict >/dev/null 2>"$coordinator_compensation_stderr"
coordinator_compensation_status=$?
set -e
[[ "$coordinator_compensation_status" == 3 ]] \
    || fail "Coordinator compensation conflict did not propagate exit 3."
grep -Fq "Installation compensation is incomplete" "$coordinator_compensation_stderr" \
    || fail "CLI did not state incomplete coordinator compensation."
grep -Fq "Ledger/hook compensation is incomplete" "$coordinator_compensation_stderr" \
    || fail "Installer did not distinguish coordinator compensation."
if grep -Fq "App/binary/lifecycle compensation is incomplete" "$coordinator_compensation_stderr"; then
    fail "Successful shell compensation was mislabeled as incomplete."
fi
[[ "$(sed -n '1p' "$lifecycle_state")" == "running|$installed_app" ]] \
    || fail "Shell did not restore the prior running companion after coordinator compensation failure."

# Failure immediately after Soft Off restores the exact prior enabled state,
# existing hook, app, binaries, and prior running lifecycle without WHOOP.
HITW_STATE_ROOT="$state_root" "$installed_control" _test-set-enabled-local --yes --value on >/dev/null
status_before="$(HITW_STATE_ROOT="$state_root" "$installed_control" status --json)"
printf '%s\n' rollback-app-marker > "$installed_app/Contents/Resources/rollback-marker"
printf '%s' rollback-control-marker >> "$installed_control"
printf '%s' rollback-hook-marker >> "$installed_hook"
artifacts_before="$(artifact_snapshot)"
hooks_before="$(shasum -a 256 "$hooks_file" | awk '{print $1}')"
if run_install after-disable >/dev/null 2>&1; then fail "Injected after-disable failure succeeded."; fi
[[ "$(artifact_snapshot)" == "$artifacts_before" ]] || fail "After-disable rollback did not restore app/binaries."
[[ "$(shasum -a 256 "$hooks_file" | awk '{print $1}')" == "$hooks_before" ]] || fail "After-disable rollback changed hooks."
[[ "$(HITW_STATE_ROOT="$state_root" "$installed_control" status --json)" == "$status_before" ]] || fail "After-disable rollback did not restore prior enabled ledger."
[[ "$(sed -n '1p' "$lifecycle_state")" == "running|$installed_app" ]] || fail "After-disable rollback did not restore running app."

# Reinstall clean artifacts, then prove a failure after hook commit restores
# hook absence, full prior ledger, and all prior app/binary bytes.
run_install >/dev/null
HITW_STATE_ROOT="$state_root" "$installed_control" _test-set-enabled-local --yes --value on >/dev/null
HITW_STATE_ROOT="$state_root" "$installed_control" uninstall-hook --hooks-file "$hooks_file" --hook-binary "$installed_hook" >/dev/null
status_before="$(HITW_STATE_ROOT="$state_root" "$installed_control" status --json)"
hooks_before="$(shasum -a 256 "$hooks_file" | awk '{print $1}')"
printf '%s\n' rollback-app-marker-2 > "$installed_app/Contents/Resources/rollback-marker-2"
printf '%s' rollback-control-marker-2 >> "$installed_control"
printf '%s' rollback-hook-marker-2 >> "$installed_hook"
artifacts_before="$(artifact_snapshot)"
if run_install after-hook-commit >/dev/null 2>&1; then fail "Injected after-hook-commit failure succeeded."; fi
[[ "$(artifact_snapshot)" == "$artifacts_before" ]] || fail "Post-hook rollback did not restore app/binaries."
[[ "$(shasum -a 256 "$hooks_file" | awk '{print $1}')" == "$hooks_before" ]] || fail "Post-hook rollback did not restore exact hooks bytes."
[[ "$(HITW_STATE_ROOT="$state_root" "$installed_control" status --json)" == "$status_before" ]] || fail "Post-hook rollback did not restore prior ledger."
if rg -Fq "$installed_hook" "$hooks_file"; then fail "Post-hook rollback retained newly owned hook."; fi

# Deterministic observed ancestor swap aborts before install mutation and never
# writes into the replacement symlink referent.
swap_root="$test_root/swap"
swap_parent="$swap_root/parent"
swap_original="$swap_root/parent-original"
swap_outside="$swap_root/outside"
swap_barrier="$swap_root/barrier"
mkdir -p "$swap_parent/Applications" "$swap_outside" "$swap_barrier" "$test_root/swap-state" "$test_root/swap-hooks"
HITW_INSTALL_APPLICATIONS_DIR="$swap_parent/Applications" \
HITW_INSTALL_STATE_ROOT="$test_root/swap-state" \
HITW_INSTALL_HOOKS_FILE="$test_root/swap-hooks/hooks.json" \
HITW_PACKAGE_CACHE_ROOT="$package_cache_root" \
HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
HITW_INSTALL_TEST_BARRIER_DIR="$swap_barrier" \
    "$installer" >"$swap_root/stdout" 2>"$swap_root/stderr" &
swap_pid=$!
for _ in $(seq 1 200); do [[ -e "$swap_barrier/ready" ]] && break; sleep 0.05; done
[[ -e "$swap_barrier/ready" ]] || fail "Swap barrier was not reached."
mv "$swap_parent" "$swap_original"
ln -s "$swap_outside" "$swap_parent"
touch "$swap_barrier/continue"
if wait "$swap_pid"; then fail "Installer accepted deterministic ancestor swap."; fi
[[ -z "$(find "$swap_outside" -mindepth 1 -print -quit)" ]] || fail "Ancestor swap caused an out-of-scope write."

# Return to a clean successful install for hard-disable lifecycle checks.
run_install >/dev/null
if HITW_INSTALL_APPLICATIONS_DIR="$nonisolated_root/Applications" \
    HITW_INSTALL_STATE_ROOT="$state_root" \
    HITW_INSTALL_HOOKS_FILE="$hooks_file" \
    HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
        "$hard_disable" >/dev/null 2>&1
then
    fail "Hard-disable accepted a nonisolated Applications boundary in test mode."
fi
[[ ! -e "$nonisolated_root" ]] || fail "Hard-disable mutated a rejected nonisolated test root."
if env -u HITW_INSTALL_TEST_MODE \
    HITW_INSTALL_APPLICATIONS_DIR="$applications_directory" \
    HITW_INSTALL_STATE_ROOT="$state_root" \
    HITW_INSTALL_HOOKS_FILE="$hooks_file" \
    HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
        "$hard_disable" >/dev/null 2>&1
then
    fail "Hard-disable accepted a lifecycle adapter outside explicit test mode."
fi
export HITW_TEST_LIFECYCLE_MODE=slow-refuse-terminate
hard_disable_stderr="$test_root/hard-disable-incomplete.stderr"
hard_disable_stdout="$test_root/hard-disable-incomplete.stdout"
if HITW_INSTALL_APPLICATIONS_DIR="$applications_directory" \
    HITW_INSTALL_STATE_ROOT="$state_root" \
    HITW_INSTALL_HOOKS_FILE="$hooks_file" \
    HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
    HITW_LIFECYCLE_TIMEOUT_SECONDS=1 \
        "$hard_disable" >"$hard_disable_stdout" 2>"$hard_disable_stderr"
then
    fail "Hard-disable accepted slow/refused termination."
fi
grep -Fq "Hard-disable is incomplete" "$hard_disable_stderr" || fail "Hard-disable failure printed no incomplete result."
grep -Fq "Companion termination was not confirmed" "$hard_disable_stderr" || fail "Hard-disable did not identify companion boundary."
if grep -Fq "Human in the Whoop is hard-disabled" "$hard_disable_stderr" "$hard_disable_stdout"; then fail "Hard-disable failure printed success."; fi
if grep -Fq "Restart Codex" "$hard_disable_stderr" "$hard_disable_stdout"; then fail "Hard-disable failure printed restart success guidance."; fi
export HITW_TEST_LIFECYCLE_MODE=normal
HITW_INSTALL_APPLICATIONS_DIR="$applications_directory" \
HITW_INSTALL_STATE_ROOT="$state_root" \
HITW_INSTALL_HOOKS_FILE="$hooks_file" \
HITW_LIFECYCLE_ADAPTER="$lifecycle_adapter" \
    "$hard_disable" >/dev/null

path_exists "$state_root/state.sqlite3" || fail "Hard disable deleted the database."
path_exists "$installed_app" || fail "Hard disable uninstalled the companion."
rg -q '"PreToolUse"' "$hooks_file" || fail "Hard disable removed unrelated hooks."
if rg -Fq "$installed_hook" "$hooks_file"; then fail "Hard disable retained owned hook."; fi
[[ "$(sed -n '1p' "$lifecycle_state")" == stopped ]] || fail "Hard disable did not terminate exact app."
[[ "$(shasum -a 256 "$config_file" | awk '{print $1}')" == "$config_checksum" ]] || fail "Hard disable changed config.toml."

echo "Local install, rollback, lifecycle, and hard-disable fixture checks passed."
