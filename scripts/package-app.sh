#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
product_name="human-in-the-whoop-menubar"
app_name="Human in the Whoop.app"
default_cache_root="$HOME/Library/Caches/com.randyhaddad.human-in-the-whoop/package"
package_cache_root="${HITW_PACKAGE_CACHE_ROOT:-$default_cache_root}"

reject_cache_root() {
    echo "Refusing unsafe HITW_PACKAGE_CACHE_ROOT: $package_cache_root" >&2
    exit 2
}

if [[ -z "$package_cache_root" ]]; then
    reject_cache_root
fi
if [[ "$package_cache_root" != /* ]]; then
    reject_cache_root
fi
case "$package_cache_root" in
    *//*|*/../*|*/..|*/./*|*/.|*/)
        reject_cache_root
        ;;
esac

case "$package_cache_root" in
    /|/Users|/Library|/System|/Applications|/tmp|/private|/private/tmp|"$HOME")
        reject_cache_root
        ;;
esac

cd "$repository_root"
swift build -c release --product "$product_name"
binary_directory="$(swift build -c release --show-bin-path)"
output_directory="$repository_root/.build/release"
repo_artifact="$output_directory/$app_name"
mkdir -p "$output_directory" "$package_cache_root"
package_cache_root="$(cd "$package_cache_root" && pwd -P)"
resolved_output_directory="$(cd "$output_directory" && pwd -P)"
case "$package_cache_root" in
    /|/Users|/Library|/System|/Applications|/tmp|/private|/private/tmp|"$HOME"|"$repository_root"|"$output_directory"|"$resolved_output_directory")
        reject_cache_root
        ;;
esac
physical_destination="$package_cache_root/$app_name"

# Stage beside the physical destination so its final rename stays on one
# filesystem and outside a Documents/FileProvider-managed tree.
staging_root="$(mktemp -d "$package_cache_root/.hitw-package.XXXXXX")"
staged_app="$staging_root/$app_name"
physical_backup="$package_cache_root/.Human in the Whoop.app.backup.$$"
repo_backup="$output_directory/.Human in the Whoop.app.backup.$$"
staged_link="$output_directory/.human-in-the-whoop-app-link.$$"

physical_prior_moved=false
physical_new_installed=false
repo_prior_moved=false
repo_new_installed=false
completed=false

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

require_valid_signature() {
    local artifact="$1"
    if ! codesign --verify --deep --strict "$artifact"; then
        echo "Packaged app failed strict signature verification: $artifact" >&2
        exit 1
    fi
}

remove_artifact() {
    local artifact="$1"
    case "$artifact" in
        "$package_cache_root"/*|"$output_directory"/*) ;;
        *)
            echo "Refusing to remove unexpected package path: $artifact" >&2
            return 1
            ;;
    esac

    if [[ -L "$artifact" || -f "$artifact" ]]; then
        rm -f "$artifact"
    elif [[ -d "$artifact" ]]; then
        rm -rf "$artifact"
    fi
}

restore_previous_artifacts() {
    # Restore the repository artifact first. A prior symlink may briefly point
    # at the new physical bundle until the physical rollback below completes.
    if [[ "$repo_new_installed" == true ]] && path_exists "$repo_artifact"; then
        remove_artifact "$repo_artifact" || true
    fi
    if [[ "$repo_prior_moved" == true ]] && path_exists "$repo_backup" \
        && ! path_exists "$repo_artifact"; then
        if mv "$repo_backup" "$repo_artifact"; then
            repo_prior_moved=false
        else
            echo "Packaging failed; the prior repository artifact remains at: $repo_backup" >&2
        fi
    fi

    if [[ "$physical_new_installed" == true ]] && path_exists "$physical_destination"; then
        remove_artifact "$physical_destination" || true
    fi
    if [[ "$physical_prior_moved" == true ]] && path_exists "$physical_backup" \
        && ! path_exists "$physical_destination"; then
        if mv "$physical_backup" "$physical_destination"; then
            physical_prior_moved=false
        else
            echo "Packaging failed; the prior physical bundle remains at: $physical_backup" >&2
        fi
    fi
}

cleanup() {
    local status=$?
    trap - EXIT
    set +e

    if [[ "$completed" != true ]]; then
        restore_previous_artifacts
    fi
    remove_artifact "$staged_link" || true
    remove_artifact "$staging_root" || true
    exit "$status"
}
trap cleanup EXIT

if path_exists "$physical_backup"; then
    echo "Refusing to overwrite package backup: $physical_backup" >&2
    exit 1
fi
if path_exists "$repo_backup"; then
    echo "Refusing to overwrite package backup: $repo_backup" >&2
    exit 1
fi
if path_exists "$staged_link"; then
    echo "Refusing to overwrite staged package link: $staged_link" >&2
    exit 1
fi

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
install -m 0755 "$binary_directory/$product_name" "$staged_app/Contents/MacOS/Human in the Whoop"
install -m 0644 "$repository_root/Packaging/Info.plist" "$staged_app/Contents/Info.plist"

xattr -cr "$staged_app"
codesign --force --deep --sign - "$staged_app"
require_valid_signature "$staged_app"

# Replace the physical cache bundle first, but retain its prior version until
# the final repository symlink has also passed strict verification.
if path_exists "$physical_destination"; then
    mv "$physical_destination" "$physical_backup"
    physical_prior_moved=true
fi
mv "$staged_app" "$physical_destination"
physical_new_installed=true
require_valid_signature "$physical_destination"

# The repository artifact is a symlink because File Provider may attach
# FinderInfo to a real .app root under Documents after signing. `codesign`
# follows this link to the stable physical bundle outside File Provider.
ln -s "$physical_destination" "$staged_link"
require_valid_signature "$staged_link"

if path_exists "$repo_artifact"; then
    # Remove a legacy root-only immutable flag only from a real local bundle.
    # Never follow an existing symlink to mutate an out-of-scope target.
    if [[ -d "$repo_artifact" && ! -L "$repo_artifact" ]]; then
        chflags nouchg "$repo_artifact" 2>/dev/null || true
    fi
    mv "$repo_artifact" "$repo_backup"
    repo_prior_moved=true
fi
mv "$staged_link" "$repo_artifact"
repo_new_installed=true
require_valid_signature "$repo_artifact"

completed=true
if path_exists "$repo_backup"; then
    if remove_artifact "$repo_backup"; then
        repo_prior_moved=false
    else
        echo "Packaged successfully; remove stale backup manually: $repo_backup" >&2
    fi
fi
if path_exists "$physical_backup"; then
    if remove_artifact "$physical_backup"; then
        physical_prior_moved=false
    else
        echo "Packaged successfully; remove stale backup manually: $physical_backup" >&2
    fi
fi

echo "$repo_artifact"
