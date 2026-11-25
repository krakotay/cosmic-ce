source_file=/etc/apt/sources.list.d/cosmic-ce-canary.sources
preferences_file=/etc/apt/preferences.d/cosmic-ce-canary
keyring=/etc/apt/keyrings/cosmic-ce-archive.asc
archive=https://krakotay.github.io/cosmic-ce/apt
package_state='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n'

install_archive_key() (
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    curl -fsSL "$archive/cosmic-ce-archive.asc" -o "$work/key.asc"
    curl -fsSL "$archive/dists/noble/InRelease" -o "$work/InRelease"
    verify_signing_key "$work/key.asc" "$work/key.gpg"
    gpgv --keyring "$work/key.gpg" "$work/InRelease"

    install -d -m 0755 /etc/apt/keyrings
    install -m 0644 "$work/key.asc" "$keyring"
)

configure_canary() {
    local priority=1001
    if (( $# )); then
        priority=-1
    fi
    {
        if (( $# )); then
            printf 'Package: %s\nPin: release o=cosmic-ce-canary\nPin-Priority: 1001\n\n' "$*"
        fi
        printf 'Package: *\nPin: release o=cosmic-ce-canary\nPin-Priority: %s\n' "$priority"
    } > "$preferences_file"
}

enable_canary() (
    local previous file package candidate
    previous=$(mktemp -d)
    trap 'rm -rf "$previous"' EXIT
    for file in "$source_file" "$preferences_file" "$keyring"; do
        if [[ -f "$file" ]]; then
            cp -p -- "$file" "$previous/"
        fi
    done
    restore_canary_config() {
        local status=$?
        if (( status )); then
            for file in "$source_file" "$preferences_file" "$keyring"; do
                if [[ -f "$previous/${file##*/}" ]]; then
                    cp -p -- "$previous/${file##*/}" "$file"
                else
                    rm -f -- "$file"
                fi
            done
        fi
        rm -rf "$previous"
    }
    install_archive_key
    trap restore_canary_config EXIT
    configure_canary "$@"
    cat > "$source_file" <<APT
Types: deb
URIs: $archive
Suites: noble
Components: main
Architectures: amd64
Signed-By: $keyring $signing_fingerprint
APT
    apt-get -o APT::Update::Error-Mode=any update
    for package in "$@"; do
        candidate=$(canary_candidate "$package")
        if [[ -z "$candidate" ]]; then
            printf 'APT does not have a COSMIC CE Canary candidate for %s.\n' "$package" >&2
            exit 1
        fi
    done
)

canary_candidate() {
    LC_ALL=C apt-cache policy "$1" | awk '$1 == "Candidate:" && $2 ~ /[+]cosmicce0[.]build/ {print $2}'
}

switch_to_canary() {
    local installed candidate package
    local -a packages=(cosmic-session cosmic-sound-theme)
    for package in "${packages[@]}"; do
        candidate=$(canary_candidate "$package")
        if [[ -z "$candidate" ]]; then
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
        candidate=$(canary_candidate "$package")
        if [[ -n "$candidate" ]]; then
            packages+=("$package")
        fi
    done <<< "$installed"

    apt-get --simulate --no-remove install "${packages[@]}"
    confirm_transaction apt-get --no-remove install "${packages[@]}"
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
        confirm_transaction apt-get --allow-downgrades install "${originals[@]}"
    fi
    rm -f "$keyring"
}

install_apt_selection() {
    local package candidate
    local -a versions=()
    for package in "$@"; do
        candidate=$(canary_candidate "$package")
        if [[ -z "$candidate" ]]; then
            printf 'APT does not have a COSMIC CE Canary candidate for %s.\n' "$package" >&2
            return 1
        fi
        versions+=("$package=$candidate")
    done
    apt-get --simulate --no-remove --no-install-recommends install "${versions[@]}"
    confirm_transaction apt-get --no-remove --no-install-recommends install "${versions[@]}"
}
