#!/usr/bin/env bash
set -euo pipefail

packages=$(realpath "${1:?package artifact directory}")
build_sha=${2:?build commit}
run_id=${3:?build run ID}
repository=${4:?GitHub repository}
channel=${5:?release channel}
mode=${6:-release}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

case "$channel" in
    canary) title='COSMIC CE Canary'; release_flags=(--prerelease --latest=false) ;;
    stable) title='COSMIC CE Stable'; release_flags=(--prerelease=false --latest) ;;
    *) exit 2 ;;
esac
[[ "$run_id" =~ ^[0-9]+$ ]]
[[ "$mode" == release || ( "$mode" == upload && "$channel" == canary ) ]]
# Rerunning failed jobs can reuse packages from earlier attempts of this run.
package_build="($run_id[.][1-9][0-9]*)"

work=$(mktemp -d)
export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
declare -A asset_ids=() asset_hashes=() backup_ids=() staged_ids=()
committed=false
cleanup() {
    local status=$? file
    set +e
    if "$committed"; then
        for file in "${!backup_ids[@]}"; do
            delete_asset "${backup_ids[$file]}" || status=1
        done
    else
        for file in "${!staged_ids[@]}"; do
            delete_asset "${staged_ids[$file]}" || status=1
        done
        for file in "${!backup_ids[@]}"; do
            rename_asset "${backup_ids[$file]}" "$file" || status=1
        done
    fi
    gpgconf --kill gpg-agent
    rm -rf -- "$work"
    exit "$status"
}
trap cleanup EXIT
mkdir "$work/assets" "$work/bundles"
assets="$work/assets"

shopt -s nullglob
debs=("$packages"/deb-*/*.deb)
rpms=("$packages"/rpm-*/*.rpm)
if (( !${#debs[@]} && !${#rpms[@]} )); then
    echo 'No packages to publish.'
    exit 0
fi
declare -A names=() versions=() sources=() canonical_names=()
package_assets=()
for artifact in "${debs[@]}" "${rpms[@]}"; do
    case "$artifact" in
        *.deb)
            format=deb
            platform=pop24.04
            name=$(dpkg-deb --field "$artifact" Package)
            arch=$(dpkg-deb --field "$artifact" Architecture)
            version=$(dpkg-deb --field "$artifact" Version)
            [[ "$arch" =~ ^(amd64|all)$ && "$version" =~ [+]cosmicce0[.]build$package_build$ ]]
            ;;
        *.rpm)
            format=rpm
            platform=fedora45
            metadata=$(rpm -qp --qf '%{NAME} %{ARCH} %{RELEASE}' "$artifact")
            read -r name arch version <<< "$metadata"
            [[ "$arch" =~ ^(x86_64|noarch)$ && "$version" =~ [.]cosmicce[.]$package_build[.]fc45$ ]]
            ;;
    esac
    build_number=${BASH_REMATCH[1]}
    [[ "$name" =~ ^[a-z0-9][a-z0-9+.-]+$ && ! -v "names[$platform:$name]" ]]
    key="$platform:$name"
    canonical_names["$platform:${name//+/.}"]=$name
    if [[ "$channel" == canary ]]; then
        file="${name//+/.}.$format"
    else
        file="${name//+/.}_${platform}_${arch}_${build_number}.$format"
    fi
    [[ ! -e "$assets/$file" ]]
    package_assets+=("$assets/$file")
    ln "$artifact" "$assets/$file" 2>/dev/null || install -m 0644 "$artifact" "$assets/$file"
    checksum=$(sha256sum -- "$assets/$file")
    printf -v row '%s\t%s\t%s\t%s\t%s' "$platform" "$name" "$arch" "$file" "${checksum%% *}"
    names["$key"]=$row
    versions["$key"]=$build_number
    sources["$key"]="$assets/$file"
    mkdir -p "$work/bundles/${format}-$name"
    ln "$assets/$file" "$work/bundles/${format}-$name/${artifact##*/}"
done

bundle_script() {
    printf "#!/bin/sh\nset -eu\ninstaller=\$(cat <<'COSMIC_CE_INSTALL_PAYLOAD'\n"
    cat "$root/scripts/cosmic-ce-install.sh" "$root/scripts/cosmic-ce-apt.sh"
    printf '\nmain "$@"\nCOSMIC_CE_INSTALL_PAYLOAD\n)\n'
    printf 'exec bash -c "$installer" %s %s\n' "$1" "$2"
}


cp "$root/packaging/cosmic-ce-archive.asc" "$assets/"
gpg --batch --import "$assets/cosmic-ce-archive.asc"
printf '%s\n' "${APT_SIGNING_KEY:?missing release signing key}" | gpg --batch --import
unset APT_SIGNING_KEY
fingerprint=$(gpg --batch --show-keys --with-colons "$assets/cosmic-ce-archive.asc" |
    awk -F: '$1 == "fpr" && !seen++ {print $10}')
gpg --batch --dearmor --output "$work/key.gpg" "$assets/cosmic-ce-archive.asc"

# GitHub replaces an asset in two operations. Stage the new bytes first and keep
# the previous asset until its replacement and signed manifest are in place.
rename_asset() {
    gh api --method PATCH "repos/$repository/releases/assets/$1" -f name="$2" --silent
}

delete_asset() {
    gh api --method DELETE "repos/$repository/releases/assets/$1" --silent
}

list_assets() {
    gh api --paginate "repos/$repository/releases/$release_id/assets?per_page=100" --jq \
        '.[] | select(.state == "uploaded") | [.name, .id, (.digest // "-")] | @tsv'
}

replace_asset() {
    local path=$1 file=$2 hash=$3 temporary id digest
    if [[ "${asset_hashes[$file]:-}" == "sha256:$hash" ]]; then
        return
    fi
    temporary="canary-upload-${GITHUB_RUN_ID:-$run_id}-$RANDOM-$file.asset"
    ln "$path" "$work/$temporary"
    gh release upload canary "$work/$temporary" --repo "$repository"
    read -r id digest <<< "$(list_assets | awk -F '\t' -v name="$temporary" '$1 == name {print $2, $3}')"
    [[ "$id" =~ ^[0-9]+$ ]]
    staged_ids["$file"]=$id
    [[ "$digest" == "sha256:$hash" ]]
    if [[ -v "asset_ids[$file]" ]]; then
        rename_asset "${asset_ids[$file]}" "canary-backup-$id-$file.asset"
        backup_ids["$file"]=${asset_ids[$file]}
    fi
    rename_asset "$id" "$file"
}

legacy='^([a-z0-9][a-z0-9.-]+)_(pop24[.]04|fedora45)_(amd64|all|x86_64|noarch)_([0-9]+[.][0-9]+)[.](deb|rpm)$'
temporary_asset='^canary-(upload-[0-9]+-[0-9]+|backup-[0-9]+)-.+[.]asset$'
if [[ "$channel" == canary ]]; then
    if ! gh release view canary --repo "$repository" >/dev/null 2>&1; then
        gh release create canary --repo "$repository" --target "$build_sha" \
            --title "$title" --prerelease --latest=false --notes 'Canary packages appear as their builds finish.'
        gh release upload canary "$assets/cosmic-ce-archive.asc" --repo "$repository"
    fi
    release_id=$(gh api "repos/$repository/releases/tags/canary" --jq .id)
    list_assets > "$work/release-assets"
    while IFS=$'\t' read -r file id digest; do
        asset_ids["$file"]=$id
        asset_hashes["$file"]=$digest
    done < "$work/release-assets"

    declare -A previous_rows=() previous_versions=()
    if [[ -v 'asset_ids[packages.tsv.asc]' ]]; then
        gh release download canary --repo "$repository" --pattern packages.tsv.asc --dir "$work"
        gpgv --keyring "$work/key.gpg" --output "$work/previous.tsv" "$work/packages.tsv.asc"
        {
            read -r header
            [[ "$header" == 'COSMIC CE canary packages v1' ]]
            while IFS=$'\t' read -r platform name arch file hash; do
                if [[ "$platform" == build ]]; then
                    [[ "$name" =~ ^(pop24[.]04|fedora45):[a-z0-9][a-z0-9+.-]+$ &&
                       "$arch" =~ ^[0-9]+[.][0-9]+$ ]]
                    previous_versions["$name"]=$arch
                    continue
                fi
                [[ "$name" =~ ^[a-z0-9][a-z0-9+.-]+$ && "$hash" =~ ^[0-9a-f]{64}$ ]]
                case "$platform:$arch" in
                    pop24.04:amd64|pop24.04:all) format=deb ;;
                    fedora45:x86_64|fedora45:noarch) format=rpm ;;
                    *) exit 1 ;;
                esac
                key="$platform:$name"
                canonical_names["$platform:${name//+/.}"]=$name
                if [[ "$file" != "${name//+/.}.$format" ]]; then
                    [[ "$file" =~ $legacy && "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:${BASH_REMATCH[5]}" == \
                        "${name//+/.}:$platform:$arch:$format" ]]
                    previous_versions["$key"]=${BASH_REMATCH[4]}
                fi
                printf -v row '%s\t%s\t%s\t%s\t%s' "$platform" "$name" "$arch" "$file" "$hash"
                previous_rows["$key"]=$row
            done
        } < "$work/previous.tsv"
    fi

    for key in "${!previous_rows[@]}"; do
        [[ -v "previous_versions[$key]" ]]
        if [[ ! -v "versions[$key]" ]] ||
            dpkg --compare-versions "${versions[$key]}" lt "${previous_versions[$key]}"; then
            names["$key"]=${previous_rows[$key]}
            versions["$key"]=${previous_versions[$key]}
            unset 'sources[$key]'
        fi
    done

    if [[ "$mode" == release ]]; then
        # Include numbered packages uploaded by older jobs even if their
        # aggregate publication never finished.
        for file in "${!asset_ids[@]}"; do
            if [[ "$file" =~ $legacy ]]; then
                normalized=${BASH_REMATCH[1]} platform=${BASH_REMATCH[2]} arch=${BASH_REMATCH[3]}
                build_number=${BASH_REMATCH[4]} format=${BASH_REMATCH[5]}
                name=${canonical_names[$platform:$normalized]:-$normalized}
                key="$platform:$name"
                hash=${asset_hashes[$file]#sha256:}
                [[ "$hash" =~ ^[0-9a-f]{64}$ ]]
                if [[ ! -v "versions[$key]" ]] ||
                    dpkg --compare-versions "$build_number" gt "${versions[$key]}"; then
                    printf -v row '%s\t%s\t%s\t%s\t%s' "$platform" "$name" "$arch" "$file" "$hash"
                    names["$key"]=$row
                    versions["$key"]=$build_number
                    unset 'sources[$key]'
                fi
            fi
        done
    fi

    for key in "${!names[@]}"; do
        IFS=$'\t' read -r platform name arch file hash <<< "${names[$key]}"
        format=${file##*.}
        canonical="${name//+/.}.$format"
        if [[ -v "sources[$key]" ]]; then
            replace_asset "${sources[$key]}" "$canonical" "$hash"
        elif [[ "$mode" == release ]]; then
            saved="$work/bundles/$format-$name"
            rm -rf -- "$saved"
            mkdir "$saved"
            download=$file
            if [[ "${asset_hashes[$download]:-}" != "sha256:$hash" ]]; then
                for backup in "${!asset_ids[@]}"; do
                    if [[ "$backup" =~ $temporary_asset && "$backup" == *-"$file".asset &&
                        "${asset_hashes[$backup]}" == "sha256:$hash" ]]; then
                        download=$backup
                        break
                    fi
                done
            fi
            gh release download canary --repo "$repository" --pattern "$download" --dir "$saved"
            if [[ "$download" != "$file" ]]; then
                mv "$saved/$download" "$saved/$file"
            fi
            printf '%s  %s\n' "$hash" "$saved/$file" | sha256sum --check --status
            replace_asset "$saved/$file" "$canonical" "$hash"
        else
            continue
        fi
        printf -v row '%s\t%s\t%s\t%s\t%s' "$platform" "$name" "$arch" "$canonical" "$hash"
        names["$key"]=$row
    done
else
    for platform in pop24.04 fedora45; do
        [[ -v "names[$platform:cosmic-session]" && -v "names[$platform:cosmic-comp]" &&
           -v "names[$platform:cosmic-viewer]" ]]
    done
fi

{
    printf 'COSMIC CE %s packages v1\n' "$channel"
    printf '%s\n' "${names[@]}" | LC_ALL=C sort
    if [[ "$channel" == canary ]]; then
        # Older installers skip rows for platforms they do not handle.
        for key in "${!versions[@]}"; do
            printf 'build	%s	%s
' "$key" "${versions[$key]}"
        done | LC_ALL=C sort
    fi
} > "$work/packages.tsv"
gpg --batch --local-user "$fingerprint" --clearsign --output "$assets/packages.tsv.asc" "$work/packages.tsv"
gpgv --keyring "$work/key.gpg" --output "$work/verified.tsv" "$assets/packages.tsv.asc"
cmp "$work/packages.tsv" "$work/verified.tsv"

manifest="$assets/packages.tsv.asc"
if [[ "$channel" == canary ]]; then
    checksum=$(sha256sum -- "$manifest")
    replace_asset "$manifest" packages.tsv.asc "${checksum%% *}"
    committed=true
    if [[ "$mode" == upload ]]; then
        exit
    fi
fi

bundle_script install.sh '"$@"' > "$assets/install.sh"
bundle_script rollback.sh 'rollback' > "$assets/rollback.sh"
sh -n "$assets/install.sh"
sh -n "$assets/rollback.sh"
sh "$assets/install.sh" --help >/dev/null

deb_bundle="cosmic-ce-$channel-amd64.tar.gz"
rpm_bundle="cosmic-ce-$channel-fedora45-x86_64.tar.gz"
bundles=()
cd "$work/bundles"
deb_files=(deb-*/*.deb)
rpm_files=(rpm-*/*.rpm)
if (( ${#deb_files[@]} )); then
    tar -czf "$assets/$deb_bundle" -- "${deb_files[@]}"
    bundles+=("$deb_bundle")
fi
if (( ${#rpm_files[@]} )); then
    tar -czf "$assets/$rpm_bundle" -- "${rpm_files[@]}"
    bundles+=("$rpm_bundle")
fi
(
    cd "$assets"
    if [[ "$channel" == canary ]]; then
        sha256sum install.sh rollback.sh cosmic-ce-archive.asc "${bundles[@]}"
    else
        sha256sum install.sh rollback.sh cosmic-ce-archive.asc packages.tsv.asc "${bundles[@]}"
        tail -n +2 "$work/packages.tsv" | awk -F '\t' '{print $5 "  " $4}'
    fi
) > "$assets/SHA256SUMS"
cat > "$work/notes.md" <<NOTES
$title for Pop!_OS 24.04 (amd64) and Fedora 45 (x86_64).

Download a single DEB or RPM from Assets, or pass --package cosmic-viewer to install.sh.

- [Build run](https://github.com/$repository/actions/runs/$run_id)
- [Build source](https://github.com/$repository/tree/$build_sha)
- [Installation and rollback](https://github.com/$repository#install-cosmic-ce)
NOTES
if [[ "$channel" == canary ]]; then
    {
        printf '\nCanary assets appear as their builds finish. The signed installer list and archives retain the last successful version of each package.\n\n'
        cat "$root/CHANGELOG.md"
    } >> "$work/notes.md"
fi

ref="repos/$repository/git/refs/tags/$channel"
update_tag() {
    local current_sha
    if current_sha=$(gh api "repos/$repository/git/ref/tags/$channel" --jq .object.sha 2>/dev/null); then
        if [[ "$current_sha" != "$build_sha" ]]; then
            gh api --method PATCH "$ref" -f sha="$build_sha" -F force=true --silent
        fi
    else
        gh api --method POST "repos/$repository/git/refs" -f "ref=refs/tags/$channel" -f sha="$build_sha" --silent
    fi
}

files=("$assets/install.sh" "$assets/rollback.sh" "$assets/cosmic-ce-archive.asc" "$assets/SHA256SUMS")
for file in "${bundles[@]}"; do files+=("$assets/$file"); done
if [[ "$channel" == canary ]]; then
    gh release upload canary "${files[@]}" --repo "$repository" --clobber
    gh release edit canary --repo "$repository" --title "$title" \
        "${release_flags[@]}" --notes-file "$work/notes.md"
    for file in "${!asset_ids[@]}"; do
        if [[ "$file" =~ $legacy || "$file" =~ $temporary_asset ]]; then
            delete_asset "${asset_ids[$file]}"
        fi
    done
elif old_files=$(gh release view "$channel" --repo "$repository" --json assets --jq '.assets[].name'); then
    # Upload the new packages before making them visible to the installer.
    gh release upload "$channel" "${package_assets[@]}" "${files[@]}" --repo "$repository" --clobber
    gh release upload "$channel" "$manifest" --repo "$repository" --clobber
    update_tag
    gh release edit "$channel" --repo "$repository" --title "$title" \
        "${release_flags[@]}" --notes-file "$work/notes.md"
    while read -r file; do
        if [[ "$file" =~ _(pop24[.]04|fedora45)_(amd64|all|x86_64|noarch)_[0-9]+[.][0-9]+[.](deb|rpm)$ &&
              ! -e "$assets/$file" ]]; then
            gh release delete-asset "$channel" "$file" --repo "$repository" --yes
        fi
    done <<< "$old_files"
else
    update_tag
    gh release create "$channel" "${package_assets[@]}" "${files[@]}" "$manifest" --repo "$repository" --verify-tag \
        --title "$title" "${release_flags[@]}" --notes-file "$work/notes.md"
fi
