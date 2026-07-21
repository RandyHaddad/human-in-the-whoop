#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
packager="$script_directory/package-app.sh"
repo_artifact="$repository_root/.build/release/Human in the Whoop.app"
test_root="$(mktemp -d /tmp/hitw-package-test.XXXXXX)"
test_cache_root="$test_root/package-cache"
protected_target="$test_root/protected-target"

fail() {
    echo "$1" >&2
    exit 1
}

require_symlink() {
    if [[ ! -L "$1" ]]; then
        fail "Expected package artifact to be a symlink: $1"
    fi
}

require_equal() {
    if [[ "$1" != "$2" ]]; then
        fail "Package assertion failed: expected '$2', got '$1'."
    fi
}

require_valid_signature() {
    if ! codesign --verify --deep --strict "$1"; then
        fail "Package artifact failed strict signature verification: $1"
    fi
}

cleanup() {
    local status=$?
    trap - EXIT
    set +e

    # Always leave the repository artifact pointing at the normal package
    # cache, even if the adversarial symlink assertion fails.
    "$packager" >/dev/null
    chflags nouchg "$protected_target" 2>/dev/null || true
    rm -rf "$test_root"
    exit "$status"
}
trap cleanup EXIT

# Establish the normal package artifact before replacing only its symlink.
"$packager" >/dev/null
require_symlink "$repo_artifact"

mkdir -p "$protected_target"
chflags uchg "$protected_target"
rm -f "$repo_artifact"
ln -s "$protected_target" "$repo_artifact"

HITW_PACKAGE_CACHE_ROOT="$test_cache_root" "$packager" >/dev/null
resolved_test_cache_root="$(cd "$test_cache_root" && pwd -P)"

flags="$(stat -f '%Sf' "$protected_target")"
case ",$flags," in
    *,uchg,*) ;;
    *)
        echo "Packager followed the repository symlink and cleared target flags." >&2
        exit 1
        ;;
esac

require_symlink "$repo_artifact"
expected_target="$resolved_test_cache_root/Human in the Whoop.app"
if [[ "${HITW_PACKAGE_TEST_FORCE_WRONG_EXPECTATION:-0}" == 1 ]]; then
    expected_target="$resolved_test_cache_root/deliberately-wrong.app"
fi
require_equal "$(readlink "$repo_artifact")" "$expected_target"
require_valid_signature "$repo_artifact"
