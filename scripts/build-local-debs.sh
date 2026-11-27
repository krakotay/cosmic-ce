#!/usr/bin/env bash
set -euo pipefail

components=(cosmic-applets cosmic-files cosmic-viewer xdg-desktop-portal-cosmic)
requested=${1:-}
if [[ "$requested" != all ]]; then
    selected=()
    for component in "${components[@]}"; do
        [[ "$component" != "$requested" ]] || selected+=("$component")
    done
    if ((${#selected[@]} == 0)); then
        printf 'Choose a package from: %s, or all.\n' "${components[*]}" >&2
        exit 2
    fi
    components=("${selected[@]}")
fi

for tool in cargo dh dpkg-buildpackage dpkg-deb; do
    if ! command -v "$tool" >/dev/null; then
        printf 'Local Debian builds require %s.\n' "$tool" >&2
        exit 1
    fi
done

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/build"
mkdir -p "$out"
work=$(mktemp -d "$out/.deb-build.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
exec 9>"$out/.deb-build.lock"
flock 9

unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
export CARGO_NET_GIT_FETCH_WITH_CLI=true
export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:+$DEB_BUILD_OPTIONS }noautodbgsym"
build_date=$(date +%Y%m%d)
shopt -s nullglob

for component in "${components[@]}"; do
    source_dir="$root/$component"
    if [[ ! -f "$source_dir/debian/changelog" ]]; then
        printf 'Initialize the %s submodule before building it.\n' "$component" >&2
        exit 1
    fi

    # Build current working files in a fresh Debian staging tree while reusing Cargo outputs.
    stage="$work/$component"
    mkdir -p "$stage"
    (
        cd "$source_dir"
        git ls-files -z --cached --others --exclude-standard |
            while IFS= read -r -d '' path; do
                if [[ -e "$path" || -L "$path" ]]; then
                    printf '%s\0' "$path"
                fi
            done |
            tar -c --null -T -
    ) | tar -x -C "$stage"

    (
        cd "$stage"
        source=$(dpkg-parsechangelog --show-field Source)
        version=$(dpkg-parsechangelog --show-field Version)
        serial=1
        while :; do
            local_version="${version}+cosmicce0.build${build_date}.${serial}"
            existing=("$out/${source}_${local_version}_"*.deb)
            ((${#existing[@]} == 0)) && break
            ((serial += 1))
        done

        cp debian/changelog "$work/changelog.original"
        {
            printf '%s (%s) noble; urgency=medium\n\n' "$source" "$local_version"
            printf '  * COSMIC CE local build based on %s.\n\n' "$(git -C "$source_dir" rev-parse --short HEAD)"
            printf ' -- COSMIC CE <cosmic-ce@users.noreply.github.com>  %s\n\n' "$(date -R)"
            cat "$work/changelog.original"
        } > debian/changelog

        export CARGO_TARGET_DIR="$source_dir/target"
        case "$component" in
            cosmic-applets) export VENDOR=0 ;;
            cosmic-files|cosmic-viewer) just vendor ;;
        esac
        # Local tools such as Cargo from rustup may be outside dpkg's package inventory.
        dpkg-buildpackage -d -b -us -uc --no-pre-clean

        packages=("$work/"*"_${local_version}_"*.deb)
        if ((${#packages[@]} == 0)); then
            printf 'The %s build produced no Debian packages.\n' "$component" >&2
            exit 1
        fi
        for package in "${packages[@]}"; do
            installed_path="$out/${package##*/}"
            mv -- "$package" "$installed_path"
            printf '%s\n' "$installed_path"
        done
    )
done
