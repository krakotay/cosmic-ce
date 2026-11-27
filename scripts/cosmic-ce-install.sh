#!/usr/bin/env bash
set -euo pipefail

signing_fingerprint=C2B3CDB20A6BCFEB5670837ED634B5AEF7925B08
release_root=https://github.com/krakotay/cosmic-ce/releases/download

usage() {
    cat <<'HELP'
Usage: install.sh (--canary|--stable) [--package NAME ...]
                  [--list-packages | --download-only]
       install.sh --canary --add-apt-repository [--package NAME ...] [--repository-only]

Without --package, install the desktop. Repeat --package to choose several packages.
--list-packages shows the release packages for this system.
--download-only saves the chosen packages to the current directory without installing.
--add-apt-repository enables canary updates on Pop!_OS.
--repository-only configures the repository without installing packages.
HELP
}

verify_signing_key() (
    local fingerprint
    export GNUPGHOME="${1%/*}/gnupg"
    mkdir -m 0700 "$GNUPGHOME"
    fingerprint=$(gpg --batch --show-keys --with-colons "$1" |
        awk -F: '$1 == "pub" { keys++; primary=1 } $1 == "fpr" && primary { fingerprint=$10; primary=0 } END { if (keys == 1) print fingerprint }')
    if [[ "$fingerprint" != "$signing_fingerprint" ]]; then
        echo "Unexpected COSMIC CE signing key." >&2
        return 1
    fi
    gpg --batch --dearmor --output "$2" "$1"
)

confirm_transaction() {
    if [[ -t 0 ]]; then
        "$@"
    elif ( : </dev/tty ) 2>/dev/null; then
        "$@" </dev/tty
    else
        echo "An interactive terminal is required to confirm the package transaction." >&2
        return 1
    fi
}

restore_fedora() {
    local installed available package
    local -a installed_names=() originals=() extras=()
    installed=$(rpm -qa --qf '%{NAME}\t%{RELEASE}\n')
    installed=$(awk '$2 ~ /[.]cosmicce[.]/ {print $1}' <<< "$installed")
    [[ -n "$installed" ]] || return 0
    mapfile -t installed_names <<< "$installed"

    available=$(dnf5 repoquery --quiet --available --qf $'%{name}\n' --repo=fedora --repo=updates --refresh "${installed_names[@]}")
    for package in "${installed_names[@]}"; do
        if grep -Fxq -- "$package" <<< "$available"; then
            originals+=("$package")
        else
            extras+=("$package")
        fi
    done

    if (( ${#originals[@]} )); then
        confirm_transaction dnf5 --repo=fedora --repo=updates distro-sync "${originals[@]}"
    fi
    if (( ${#extras[@]} )); then
        printf 'These COSMIC CE packages have no Fedora replacement: %s\n' "${extras[*]}"
        confirm_transaction dnf5 remove --no-autoremove "${extras[@]}"
    fi
}

use_release_packages() (
    local work platform name file selected package attempt fresh
    local -a downloads=()
    local -A files=() hashes=()
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    if [[ "$format" == deb ]]; then
        platform=pop24.04
        chmod 0755 "$work" # Allow the APT sandbox to read the local .deb files.
    else
        platform=fedora45
    fi

    local release_url="$release_root/$channel"
    curl -fsSL "$release_url/cosmic-ce-archive.asc" -o "$work/key.asc"
    verify_signing_key "$work/key.asc" "$work/key.gpg"
    read_release_manifest() {
        local target name arch file hash header
        fresh="?publication=$(date +%s%N)"
        curl -fsSL --retry 3 --retry-all-errors --retry-delay 1 \
            "$release_url/packages.tsv.asc$fresh" -o "$work/packages.tsv.asc" || return
        rm -f "$work/verified.tsv"
        gpgv --keyring "$work/key.gpg" --output "$work/verified.tsv" "$work/packages.tsv.asc" || return
        files=()
        hashes=()
        {
            read -r header
            [[ "$header" == "COSMIC CE $channel packages v1" ]] || return 1
            while IFS=$'\t' read -r target name arch file hash; do
                [[ "$target" == "$platform" ]] || continue
                [[ "$name" =~ ^[a-z0-9][a-z0-9+.-]+$ &&
                   "$file" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]+[.](deb|rpm)$ && "$file" == *."$format" &&
                   "$hash" =~ ^[a-f0-9]{64}$ && ! -v "files[$name]" ]] || return 1
                case "$format:$arch" in
                    deb:amd64|deb:all|rpm:x86_64|rpm:noarch) ;;
                    *) return 1 ;;
                esac
                files["$name"]=$file
                hashes["$name"]=$hash
            done
        } < "$work/verified.tsv"
    }
    read_release_manifest
    if (( ! ${#files[@]} )); then
        printf 'No packages for %s in this release.\n' "$platform" >&2
        exit 1
    fi

    if (( list_only )); then
        printf '%s\n' "${!files[@]}" | LC_ALL=C sort
        exit 0
    fi

    if (( ${#packages[@]} == 0 )); then
        while read -r name; do
            if (( ! download_only )) && [[ "$format" == deb ]]; then
                case "$name" in
                    cosmic-initial-setup-casper|pop-launcher-system76-power)
                        [[ "$(dpkg-query -W -f='${db:Status-Status}' "$name" 2>/dev/null)" == installed ]] || continue
                        ;;
                esac
            fi
            packages+=("$name")
        done < <(printf '%s\n' "${!files[@]}" | LC_ALL=C sort)
    fi
    for selected in "${packages[@]}"; do
        if [[ ! -v "files[$selected]" ]]; then
            printf 'Package %s is unavailable for %s. Use --list-packages to see the package names.\n' "$selected" "$platform" >&2
            exit 1
        fi
    done
    for selected in "${packages[@]}"; do
        for attempt in {1..5}; do
            file=${files[$selected]}
            package="$work/$file"
            if curl -fsSL "$release_url/$file$fresh" -o "$package" &&
                printf '%s  %s\n' "${hashes[$selected]}" "$package" | sha256sum --check --status; then
                downloads+=("$package")
                break
            fi
            if [[ "$channel" != canary || "$attempt" == 5 ]]; then
                printf 'Could not download and verify %s.\n' "$file" >&2
                exit 1
            fi
            # The package and its signed entry can change during a download.
            sleep 2
            read_release_manifest
            [[ -v "files[$selected]" ]]
        done
    done
    if (( download_only )); then
        install -m 0644 -t . -- "${downloads[@]}"
        printf '%s\n' "${downloads[@]##*/}"
    elif [[ "$format" == deb ]]; then
        apt-get --simulate --no-remove "${dependency_options[@]}" install "${downloads[@]}"
        confirm_transaction apt-get --no-remove "${dependency_options[@]}" install "${downloads[@]}"
    else
        confirm_transaction dnf5 "${dependency_options[@]}" install "${downloads[@]}"
    fi
)

main() {
    local channel= add_archive=0 repository_only=0 download_only=0 list_only=0 format= rollback=0
    local -a packages=() dependency_options=()
    local -A requested=()

    if [[ "${1:-}" == rollback && $# == 1 ]]; then
        rollback=1
        shift
    fi
    while (( $# )); do
        case "$1" in
            --canary|--stable)
                [[ -z "$channel" ]] || { echo "Choose one release channel." >&2; return 2; }
                channel=${1#--}
                ;;
            --package)
                if [[ ! "${2:-}" =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; then
                    echo "--package requires an exact package name." >&2
                    return 2
                fi
                if [[ ! -v "requested[$2]" ]]; then
                    requested["$2"]=1
                    packages+=("$2")
                fi
                shift
                ;;
            --add-apt-repository) add_archive=1 ;;
            --repository-only) repository_only=1 ;;
            --download-only) download_only=1 ;;
            --list-packages) list_only=1 ;;
            -h|--help) usage; return ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; return 2 ;;
        esac
        shift
    done

    if (( ! rollback )) && [[ -z "$channel" ]]; then
        usage >&2
        return 2
    fi
    if (( download_only + list_only + repository_only > 1 || (list_only && ${#packages[@]}) ||
          (add_archive && (download_only || list_only)) || (repository_only && ! add_archive) )); then
        usage >&2
        return 2
    fi

    source /etc/os-release
    if [[ "$ID" == pop && "${VERSION_CODENAME:-}" == noble && "$(dpkg --print-architecture)" == amd64 ]]; then
        format=deb
        if (( ${#packages[@]} )); then
            dependency_options=(--no-install-recommends)
        fi
    elif [[ "$ID" == fedora && "$VERSION_ID" == 45 && "$(uname -m)" == x86_64 && ! -e /run/ostree-booted ]]; then
        format=rpm
        if (( ${#packages[@]} )); then
            dependency_options=(--setopt=install_weak_deps=False)
        fi
    else
        echo "Supported systems are Pop!_OS 24.04 (amd64) and non-Atomic Fedora 45 (x86_64)." >&2
        return 1
    fi

    if (( ! download_only && ! list_only && EUID != 0 )); then
        echo "Run installation and rollback with sudo." >&2
        return 1
    fi
    if (( rollback )); then
        if [[ "$format" == deb ]]; then
            restore_upstream
        else
            restore_fedora
        fi
        return
    fi

    if (( add_archive )); then
        if [[ "$format:$channel" != deb:canary ]]; then
            echo "The APT repository is available for Pop!_OS Canary." >&2
            return 2
        fi
        enable_canary "${packages[@]}"
        if (( ! repository_only )); then
            if (( ${#packages[@]} )); then
                install_apt_selection "${packages[@]}"
            else
                switch_to_canary
            fi
        fi
    elif [[ "$format:$channel" == deb:canary && -f "$source_file" ]] &&
         (( ! list_only && ! download_only && ! ${#packages[@]} )); then
        apt-get update
        switch_to_canary
    else
        use_release_packages
    fi
}
