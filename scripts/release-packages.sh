#!/usr/bin/env bash
set -euo pipefail

packages=$(realpath "${1:?package artifact directory}")
build_sha=${2:?build commit}
run_id=${3:?build run ID}
repository=${4:?GitHub repository}
channel=${5:?release channel}
build_number="$run_id.${GITHUB_RUN_ATTEMPT:?}"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

case "$channel" in
    canary) title='COSMIC CE Canary'; release_flags=(--prerelease --latest=false) ;;
    stable) title='COSMIC CE Stable'; release_flags=(--prerelease=false --latest) ;;
    *) exit 2 ;;
esac
[[ "$build_number" =~ ^[0-9]+[.][0-9]+$ ]]
# Rerunning failed jobs can reuse packages from earlier attempts of this run.
package_build="$run_id[.][1-9][0-9]*"

work=$(mktemp -d)
export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
trap 'gpgconf --kill gpg-agent; rm -rf -- "$work"' EXIT
assets="$work/assets"
mkdir "$assets"

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

shopt -s nullglob
debs=("$packages"/deb-*/*.deb)
rpms=("$packages"/rpm-*/*.rpm)
[[ ${#debs[@]} -gt 0 && ${#rpms[@]} -gt 0 ]]
declare -A names=() current_files=()
package_assets=()
for artifact in "${debs[@]}" "${rpms[@]}"; do
    case "$artifact" in
        *.deb)
            format=deb
            platform=pop24.04
            name=$(dpkg-deb --field "$artifact" Package)
            arch=$(dpkg-deb --field "$artifact" Architecture)
            version=$(dpkg-deb --field "$artifact" Version)
            [[ "$version" =~ [+]cosmicce0[.]build$package_build$ && "$arch" =~ ^(amd64|all)$ ]]
            ;;
        *.rpm)
            format=rpm
            platform=fedora45
            metadata=$(rpm -qp --qf '%{NAME} %{ARCH} %{RELEASE}' "$artifact")
            read -r name arch version <<< "$metadata"
            [[ "$version" =~ [.]cosmicce[.]$package_build[.]fc45$ && "$arch" =~ ^(x86_64|noarch)$ ]]
            ;;
    esac
    [[ "$name" =~ ^[a-z0-9][a-z0-9+.-]+$ && ! -v "names[$platform:$name]" ]]
    names["$platform:$name"]=1
    file="${name//+/.}_${platform}_${arch}_${build_number}.$format"
    [[ ! -v "current_files[$file]" ]]
    current_files["$file"]=1
    package_assets+=("$assets/$file")
    install -m 0644 "$artifact" "$assets/$file"
    checksum=$(sha256sum -- "$assets/$file")
    printf '%s\t%s\t%s\t%s\t%s\n' "$platform" "$name" "$arch" "$file" "${checksum%% *}" >> "$work/packages"
done
for platform in pop24.04 fedora45; do
    [[ -v "names[$platform:cosmic-session]" && -v "names[$platform:cosmic-comp]" &&
       -v "names[$platform:cosmic-viewer]" ]]
done
{
    printf 'COSMIC CE %s packages v1\n' "$channel"
    LC_ALL=C sort "$work/packages"
} > "$work/packages.tsv"
gpg --batch --local-user "$fingerprint" --clearsign --output "$assets/packages.tsv.asc" "$work/packages.tsv"
gpg --batch --dearmor --output "$work/key.gpg" "$assets/cosmic-ce-archive.asc"
gpgv --keyring "$work/key.gpg" --output "$work/verified.tsv" "$assets/packages.tsv.asc"
cmp "$work/packages.tsv" "$work/verified.tsv"

deb_bundle="cosmic-ce-$channel-amd64.tar.gz"
rpm_bundle="cosmic-ce-$channel-fedora45-x86_64.tar.gz"
(
    cd "$packages"
    tar -czf "$assets/$deb_bundle" -- deb-*/*.deb
    tar -czf "$assets/$rpm_bundle" -- rpm-*/*.rpm
)
(
    cd "$assets"
    sha256sum install.sh rollback.sh cosmic-ce-archive.asc packages.tsv.asc "$deb_bundle" "$rpm_bundle" ./*.deb ./*.rpm > SHA256SUMS
)
cat > "$work/notes.md" <<NOTES
$title for Pop!_OS 24.04 (amd64) and Fedora 45 (x86_64).

Download a single DEB or RPM from Assets, or pass --package cosmic-viewer to install.sh.

- [Build run](https://github.com/$repository/actions/runs/$run_id)
- [Build source](https://github.com/$repository/tree/$build_sha)
- [Installation and rollback](https://github.com/$repository#install-cosmic-ce)
NOTES
if [[ "$channel" == canary ]]; then
    {
        printf '\nCanary uses faster Thin LTO in Cargo release profiles that normally use Fat LTO.\n\n'
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

files=("$assets/install.sh" "$assets/rollback.sh" "$assets/cosmic-ce-archive.asc"
    "$assets/$deb_bundle" "$assets/$rpm_bundle" "$assets/SHA256SUMS")
manifest="$assets/packages.tsv.asc"
if old_files=$(gh release view "$channel" --repo "$repository" --json assets --jq '.assets[].name'); then
    # Upload the new packages before making them visible to the installer.
    gh release upload "$channel" "${package_assets[@]}" "${files[@]}" --repo "$repository" --clobber
    gh release upload "$channel" "$manifest" --repo "$repository" --clobber
    update_tag
    gh release edit "$channel" --repo "$repository" --title "$title" \
        "${release_flags[@]}" --notes-file "$work/notes.md"
    while read -r file; do
        if [[ "$file" =~ _(pop24[.]04|fedora45)_(amd64|all|x86_64|noarch)_[0-9]+[.][0-9]+[.](deb|rpm)$ &&
              ! -v "current_files[$file]" ]]; then
            gh release delete-asset "$channel" "$file" --repo "$repository" --yes
        fi
    done <<< "$old_files"
else
    update_tag
    gh release create "$channel" "${package_assets[@]}" "${files[@]}" "$manifest" --repo "$repository" --verify-tag \
        --title "$title" "${release_flags[@]}" --notes-file "$work/notes.md"
fi
