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
archive_fingerprint=C2B3CDB20A6BCFEB5670837ED634B5AEF7925B08
package_state='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n'

confirm_apt_transaction() {
    if [[ -t 0 ]]; then
        apt-get "$@"
    elif ( : </dev/tty ) 2>/dev/null; then
        apt-get "$@" </dev/tty
    else
        echo "An interactive terminal is required to confirm the APT transaction." >&2
        return 1
    fi
}

install_archive_key() (
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    curl -fsSL "$archive/cosmic-ce-archive.asc" -o "$work/key.asc"
    curl -fsSL "$archive/dists/noble/InRelease" -o "$work/InRelease"
    fingerprint=$(gpg --batch --show-keys --with-colons "$work/key.asc" |
        awk -F: '$1 == "pub" { keys++; primary=1 } $1 == "fpr" && primary { fingerprint=$10; primary=0 } END { if (keys == 1) print fingerprint }')
    if [[ "$fingerprint" != "$archive_fingerprint" ]]; then
        echo "Unexpected COSMIC CE archive signing key." >&2
        exit 1
    fi
    gpg --batch --dearmor --output "$work/key.gpg" "$work/key.asc"
    gpgv --keyring "$work/key.gpg" "$work/InRelease"

    install -d -m 0755 /etc/apt/keyrings
    install -m 0644 "$work/key.asc" "$keyring"
)

enable_canary() {
    install_archive_key
    cat > "$source_file" <<APT
Types: deb
URIs: $archive
Suites: noble
Components: main
Architectures: amd64
Signed-By: $keyring $archive_fingerprint
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
    for package in "${packages[@]}"; do
        candidate=$(LC_ALL=C apt-cache policy "$package" | awk '$1 == "Candidate:" {print $2}')
        if [[ "$candidate" != *+cosmicce0.build* ]]; then
            printf 'APT does not have a COSMIC CE Canary candidate for %s.\n' "$package" >&2
            return 1
        fi
    done

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
    confirm_apt_transaction --no-remove install "${packages[@]}"
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
        confirm_apt_transaction --allow-downgrades install "${originals[@]}"
    fi
    rm -f "$keyring"
}

install_channel() {
    local argument channel= add_archive=0 repository_only=0
    for argument in "$@"; do
        case "$argument" in
            --canary|--stable)
                if [[ -n "$channel" ]]; then
                    echo "Choose one release channel." >&2
                    return 2
                fi
                channel=${argument#--}
                ;;
            --add-apt-repository) add_archive=1 ;;
            --repository-only) repository_only=1 ;;
            *)
                printf 'Unknown option: %s\n' "$argument" >&2
                return 2
                ;;
        esac
    done

    case "$channel" in
        stable)
            echo "COSMIC CE Stable has no published build yet." >&2
            return 1
            ;;
        canary) ;;
        *)
            echo "Usage: install.sh --canary --add-apt-repository [--repository-only]" >&2
            return 2
            ;;
    esac

    if (( add_archive )); then
        enable_canary
    elif [[ ! -f "$source_file" ]]; then
        echo "Add --add-apt-repository to configure the canary archive." >&2
        return 2
    else
        apt-get update
    fi

    if (( ! repository_only )); then
        switch_to_canary
    fi
}

case "${1:-}" in
    enable) enable_canary ;;
    switch)
        enable_canary
        switch_to_canary
        ;;
    rollback) restore_upstream ;;
    *) install_channel "$@" ;;
esac
