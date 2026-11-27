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
trap 'gpgconf --kill gpg-agent; rm -rf -- "$work"' EXIT
mkdir "$work/assets" "$work/bundles"
assets="$work/assets"

shopt -s nullglob
debs=("$packages"/deb-*/*.deb)
rpms=("$packages"/rpm-*/*.rpm)
if (( !${#debs[@]} && !${#rpms[@]} )); then
    echo 'No packages to publish.'
    exit 0
fi
declare -A names=() previous_files=()
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
    file="${name//+/.}_${platform}_${arch}_${build_number}.$format"
    [[ ! -e "$assets/$file" ]]
    package_assets+=("$assets/$file")
    ln "$artifact" "$assets/$file" 2>/dev/null || install -m 0644 "$artifact" "$assets/$file"
    checksum=$(sha256sum -- "$assets/$file")
    printf -v row '%s\t%s\t%s\t%s\t%s' "$platform" "$name" "$arch" "$file" "${checksum%% *}"
    names["$platform:$name"]=$row
    mkdir -p "$work/bundles/${format}-$name"
    ln "$assets/$file" "$work/bundles/${format}-$name/${artifact##*/}"
done

upload_canary_assets() {
    local asset digest existing checksums='' filename
    if ! gh release view canary --repo "$repository" >/dev/null 2>&1; then
        gh release create canary --repo "$repository" --target "$build_sha" \
            --title "$title" --prerelease --latest=false --notes 'Canary packages appear as their builds finish.' ||
            gh release view canary --repo "$repository" >/dev/null
    fi
    if [[ "$mode" == release ]]; then
        checksums=$(published_assets)
    fi
    for asset in "$@"; do
        filename=${asset##*/}
        digest=$(sha256sum -- "$asset")
        if grep -Fxq "$filename"$'\t'"sha256:${digest%% *}" <<< "$checksums"; then
            continue
        fi
        if gh release upload canary "$asset" --repo "$repository"; then
            continue
        fi
        # A retry may find the same asset. Leave the published bytes in place.
        existing=$(published_assets)
        grep -Fxq "$filename"$'\t'"sha256:${digest%% *}" <<< "$existing" || return 1
    done
}

published_assets() {
    local release_id
    release_id=$(gh api "repos/$repository/releases/tags/canary" --jq .id)
    gh api --paginate "repos/$repository/releases/$release_id/assets?per_page=100" --jq \
        '.[] | [.name, .digest] | @tsv'
}

if [[ "$mode" == upload ]]; then
    upload_canary_assets "${package_assets[@]}"
    exit
fi

bundle_script() {
    printf "#!/bin/sh\nset -eu\ninstaller=\$(cat <<'COSMIC_CE_INSTALL_PAYLOAD'\n"
    cat "$root/scripts/cosmic-ce-install.sh" "$root/scripts/cosmic-ce-apt.sh"
    printf '\nmain "$@"\nCOSMIC_CE_INSTALL_PAYLOAD\n)\n'
    printf 'exec bash -c "$installer" %s %s\n' "$1" "$2"
}

bundle_script install.sh '"$@"' > "$assets/install.sh"
bundle_script rollback.sh 'rollback' > "$assets/rollback.sh"
sh -n "$assets/install.sh"
sh -n "$assets/rollback.sh"
sh "$assets/install.sh" --help >/dev/null

cp "$root/packaging/cosmic-ce-archive.asc" "$assets/"
gpg --batch --import "$assets/cosmic-ce-archive.asc"
printf '%s\n' "${APT_SIGNING_KEY:?missing release signing key}" | gpg --batch --import
unset APT_SIGNING_KEY
fingerprint=$(gpg --batch --show-keys --with-colons "$assets/cosmic-ce-archive.asc" |
    awk -F: '$1 == "fpr" && !seen++ {print $10}')
gpg --batch --dearmor --output "$work/key.gpg" "$assets/cosmic-ce-archive.asc"

asset_build() {
    local pattern='_([0-9]+[.][0-9]+)[.](deb|rpm)$'
    [[ "$1" =~ $pattern ]]
    printf '%s\n' "${BASH_REMATCH[1]}"
}

if [[ "$channel" == canary ]]; then
    # Merge only from the last signed manifest. Another run may already be
    # uploading newer assets, and a partial run can finish out of order.
    if old_files=$(gh release view canary --repo "$repository" --json assets --jq '.assets[].name'); then
        if grep -Fxq packages.tsv.asc <<< "$old_files"; then
            gh release download canary --repo "$repository" --pattern packages.tsv.asc --dir "$work"
            gpgv --keyring "$work/key.gpg" --output "$work/previous.tsv" "$work/packages.tsv.asc"
            {
                read -r header
                [[ "$header" == 'COSMIC CE canary packages v1' ]]
                while IFS=$'\t' read -r platform name arch file hash; do
                    [[ "$name" =~ ^[a-z0-9][a-z0-9+.-]+$ && "$hash" =~ ^[0-9a-f]{64}$ ]]
                    case "$platform:$arch" in
                        pop24.04:amd64|pop24.04:all) format=deb ;;
                        fedora45:x86_64|fedora45:noarch) format=rpm ;;
                        *) exit 1 ;;
                    esac
                    prefix="${name//+/.}_${platform}_${arch}_"
                    [[ "${file#"$prefix"}" =~ ^[0-9]+[.][0-9]+[.]$format$ && "$file" == "$prefix"* ]]
                    key="$platform:$name"
                    previous_files["$key"]=$file
                    if [[ -v "names[$key]" ]]; then
                        IFS=$'\t' read -r _ _ _ current _ <<< "${names[$key]}"
                        if dpkg --compare-versions "$(asset_build "$current")" ge "$(asset_build "$file")"; then
                            continue
                        fi
                        rm -rf -- "$work/bundles/${format}-$name"
                    fi
                    saved="$work/bundles/${format}-$name"
                    mkdir "$saved"
                    gh release download canary --repo "$repository" --pattern "$file" --dir "$saved"
                    printf '%s  %s\n' "$hash" "$file" | (cd "$saved" && sha256sum --check --status)
                    printf -v row '%s\t%s\t%s\t%s\t%s' "$platform" "$name" "$arch" "$file" "$hash"
                    names["$key"]=$row
                done
            } < "$work/previous.tsv"
        fi
    fi
else
    for platform in pop24.04 fedora45; do
        [[ -v "names[$platform:cosmic-session]" && -v "names[$platform:cosmic-comp]" &&
           -v "names[$platform:cosmic-viewer]" ]]
    done
fi

{
    printf 'COSMIC CE %s packages v1\n' "$channel"
    printf '%s\n' "${names[@]}" | LC_ALL=C sort
} > "$work/packages.tsv"
gpg --batch --local-user "$fingerprint" --clearsign --output "$assets/packages.tsv.asc" "$work/packages.tsv"
gpgv --keyring "$work/key.gpg" --output "$work/verified.tsv" "$assets/packages.tsv.asc"
cmp "$work/packages.tsv" "$work/verified.tsv"

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
    sha256sum install.sh rollback.sh cosmic-ce-archive.asc packages.tsv.asc "${bundles[@]}"
    tail -n +2 "$work/packages.tsv" | awk -F '\t' '{print $5 "  " $4}'
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
        if [[ "$current_sha" != "$build_sha" ]] &&
            [[ "$channel" == stable || "$(gh api "repos/$repository/compare/$current_sha...$build_sha" --jq .status)" == ahead ]]; then
            gh api --method PATCH "$ref" -f sha="$build_sha" -F force=true --silent
        fi
    else
        gh api --method POST "repos/$repository/git/refs" -f "ref=refs/tags/$channel" -f sha="$build_sha" --silent
    fi
}

files=("$assets/install.sh" "$assets/rollback.sh" "$assets/cosmic-ce-archive.asc" "$assets/SHA256SUMS")
for file in "${bundles[@]}"; do files+=("$assets/$file"); done
manifest="$assets/packages.tsv.asc"
if [[ "$channel" == canary ]]; then
    # Also covers artifacts from before immediate uploads, or a failed upload.
    upload_canary_assets "${package_assets[@]}"
    gh release upload canary "${files[@]}" --repo "$repository" --clobber
    gh release upload canary "$manifest" --repo "$repository" --clobber
    update_tag
    gh release edit canary --repo "$repository" --title "$title" \
        "${release_flags[@]}" --notes-file "$work/notes.md"
    # Keep the previous manifest's assets during the transition. Never remove
    # assets uploaded by a newer build that has yet to update the manifest.
    for key in "${!previous_files[@]}"; do
        previous=${previous_files[$key]}
        prefix=${previous%_*}
        while read -r file; do
            if [[ "$file" == "$prefix"_* && "${file#"$prefix"_}" =~ ^[0-9]+[.][0-9]+[.](deb|rpm)$ ]] &&
                dpkg --compare-versions "$(asset_build "$file")" lt "$(asset_build "$previous")"; then
                gh release delete-asset canary "$file" --repo "$repository" --yes
            fi
        done <<< "$old_files"
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
