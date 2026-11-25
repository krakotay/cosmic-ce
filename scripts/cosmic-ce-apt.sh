#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
    echo "Run this command with sudo." >&2
    exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != pop || "${VERSION_CODENAME:-}" != noble || "$(dpkg --print-architecture)" != amd64 ]]; then
    echo "COSMIC CE Canary supports Pop!_OS 24.04 (amd64)." >&2
    exit 1
fi

source_file=/etc/apt/sources.list.d/cosmic-ce-canary.sources
preferences_file=/etc/apt/preferences.d/cosmic-ce-canary
keyring=/etc/apt/keyrings/cosmic-ce-archive.asc
archive=https://krakotay.github.io/cosmic-ce/apt
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
package_state='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n'

enable_canary() {
    local release binary_keyring verified=0
    release=$(mktemp)
    if ! curl --fail --silent --show-error --location "$archive/dists/noble/InRelease" --output "$release"; then
        rm -f "$release"
        return 1
    fi
    binary_keyring=$(mktemp)
    if gpg --batch --yes --dearmor --output "$binary_keyring" "$project_root/packaging/cosmic-ce-archive.asc" &&
        gpgv --keyring "$binary_keyring" "$release"; then
        verified=1
    fi
    rm -f "$release" "$binary_keyring"
    (( verified )) || return 1

    install -d -m 0755 /etc/apt/keyrings
    install -m 0644 "$project_root/packaging/cosmic-ce-archive.asc" "$keyring"
    cat > "$source_file" <<APT
Types: deb
URIs: $archive
Suites: noble
Components: main
Architectures: amd64
Signed-By: $keyring
APT
    cat > "$preferences_file" <<'APT'
Package: *
Pin: release o=cosmic-ce-canary
Pin-Priority: 1001
APT
    apt-get update
}

switch_to_canary() {
    local installed candidate package
    local -a packages=(cosmic-session cosmic-sound-theme)
    installed=$(dpkg-query -W -f="$package_state")
    while IFS=$'\t' read -r state package _; do
        [[ "$state" == ii* ]] || continue
        case "$package" in
            cosmic-session|cosmic-sound-theme) continue ;;
            cosmic-*|pop-launcher|pop-launcher:*|pop-launcher-system76-power|xdg-desktop-portal-cosmic|xdg-desktop-portal-cosmic:*) ;;
            *) continue ;;
        esac
        candidate=$(LC_ALL=C apt-cache policy "$package" | awk '$1 == "Candidate:" {print $2}')
        if [[ "$candidate" == *+cosmicce0.build* ]]; then
            packages+=("$package")
        fi
    done <<< "$installed"

    apt-get --simulate --no-remove install "${packages[@]}"
    apt-get --no-remove install "${packages[@]}"
}

restore_upstream() {
    local installed state package version preview
    local -a originals=()
    rm -f "$source_file" "$preferences_file"
    apt-get update

    installed=$(dpkg-query -W -f="$package_state")
    while IFS=$'\t' read -r state package version; do
        [[ "$state" =~ ^.[HiUFWt] ]] || continue
        [[ "$version" == *+cosmicce0.build* ]] || continue
        if [[ "$package" == cosmic-sound-theme ]]; then
            originals+=("cosmic-sound-theme-")
            continue
        fi
        version=$(LC_ALL=C apt-cache madison "$package" |
            awk -F ' *\\| *' '$3 ~ /apt[.]pop-os[.]org\/release\/? noble\/main / && !found++ {print $2}')
        if [[ -z "$version" ]]; then
            printf 'No version of %s found in the official Pop!_OS Noble archive.\n' "$package" >&2
            return 1
        fi
        originals+=("$package=$version")
    done <<< "$installed"

    if (( ${#originals[@]} )); then
        preview=$(LC_ALL=C apt-get --simulate --allow-downgrades install "${originals[@]}")
        printf '%s\n' "$preview"
        if awk '$1 == "Remv" && $2 != "cosmic-sound-theme" {unexpected=1} END {exit !unexpected}' <<< "$preview"; then
            echo "Rollback would remove additional packages. No package changes were applied." >&2
            return 1
        fi
        apt-get --allow-downgrades install "${originals[@]}"
    fi
    rm -f "$keyring"
}

case "${1:-}" in
    enable) enable_canary ;;
    switch)
        enable_canary
        switch_to_canary
        ;;
    rollback) restore_upstream ;;
    *) echo "Usage: $0 {enable|switch|rollback}" >&2; exit 2 ;;
esac
