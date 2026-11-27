#!/usr/bin/env bash
set -euo pipefail

packages=$(realpath "${1:?package artifact directory}")
site=$(realpath -m "${2:?APT archive output directory}")
keyring=$(realpath packaging/cosmic-ce-archive.asc)
run_id=${GITHUB_RUN_ID:?}
archive=${CANARY_APT_ARCHIVE:-https://krakotay.github.io/cosmic-ce/apt}
[[ "$run_id" =~ ^[0-9]+$ ]]
package_build="$run_id[.][1-9][0-9]*"
shopt -s nullglob
artifacts=("$packages"/deb-*/*.deb)
if (( !${#artifacts[@]} )); then
    echo 'No DEBs to add to the APT archive.'
    exit 0
fi

export GNUPGHOME
GNUPGHOME=$(mktemp -d)
trap 'gpgconf --kill gpg-agent; rm -rf "$GNUPGHOME"' EXIT

gpg --batch --import "$keyring"
printf '%s\n' "${APT_SIGNING_KEY:?missing APT signing key}" | gpg --batch --import
unset APT_SIGNING_KEY
fingerprint=$(gpg --batch --show-keys --with-colons "$keyring" | awk -F: '$1 == "fpr" && !seen++ {print $10}')
gpg --batch --dearmor --output "$GNUPGHOME/cosmic-ce.gpg" "$keyring"

apt_site="$site/apt"
index=dists/noble/main/binary-amd64
mkdir -p "$apt_site/pool" "$apt_site/$index"
install -m 0644 "$keyring" "$apt_site/cosmic-ce-archive.asc"

declare -A package_paths package_versions
for artifact in "${artifacts[@]}"; do
    name=$(dpkg-deb --field "$artifact" Package)
    version=$(dpkg-deb --field "$artifact" Version)
    architecture=$(dpkg-deb --field "$artifact" Architecture)
    [[ "$name" =~ ^[a-z0-9][a-z0-9+.-]+$ && "$version" =~ [+]cosmicce0[.]build$package_build$ &&
        "$architecture" =~ ^(amd64|all)$ && "${artifact##*/}" =~ ^[a-zA-Z0-9+._~:-]+[.]deb$ ]]
    if [[ -v "package_paths[$name]" ]]; then
        printf 'Multiple artifacts provide %s\n' "$name" >&2
        exit 1
    fi
    package_paths[$name]=$artifact
    package_versions[$name]=$version
done

# Carry forward DEBs that failed, were omitted, or came from a newer run.
# Verify the previous index and package hashes before using the public archive.
curl_args=(--noproxy '*' --silent --show-error --location --retry 3)
fresh="?publication=$run_id.${GITHUB_RUN_ATTEMPT:-1}.$(date +%s%N)"
status=$(curl "${curl_args[@]}" --write-out '%{http_code}' --output "$GNUPGHOME/InRelease" \
    "$archive/dists/noble/InRelease$fresh")
case "$status" in
    200)
        gpgv --keyring "$GNUPGHOME/cosmic-ce.gpg" --output "$GNUPGHOME/Release" "$GNUPGHOME/InRelease"
        curl "${curl_args[@]}" --fail "$archive/$index/Packages$fresh" --output "$GNUPGHOME/Packages"
        expected=$(awk '
            /^SHA256:$/ {sha256=1; next}
            /^[^ ]/ {sha256=0}
            sha256 && $3 == "main/binary-amd64/Packages" {print $1}
        ' "$GNUPGHOME/Release")
        [[ "$expected" =~ ^[0-9a-f]{64}$ ]]
        printf '%s  %s\n' "$expected" "$GNUPGHOME/Packages" | sha256sum --check --status
        awk -v RS='' -F '\n' '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^Package: /) name = substr($i, 10)
                    if ($i ~ /^Version: /) version = substr($i, 10)
                    if ($i ~ /^Filename: /) file = substr($i, 11)
                    if ($i ~ /^SHA256: /) hash = substr($i, 9)
                }
                if (!(name && version && file && hash)) exit 1
                print name, version, file, hash
                name = version = file = hash = ""
            }
        ' "$GNUPGHOME/Packages" > "$GNUPGHOME/previous"
        while read -r name version file hash; do
            [[ "$name" =~ ^[a-z0-9][a-z0-9+.-]+$ && "$file" =~ ^pool/[a-zA-Z0-9+._~:-]+[.]deb$ &&
                "$hash" =~ ^[0-9a-f]{64}$ ]]
            if [[ -v "package_versions[$name]" ]] &&
                dpkg --compare-versions "${package_versions[$name]}" ge "$version"; then
                continue
            fi
            saved="$GNUPGHOME/${file##*/}"
            curl "${curl_args[@]}" --fail "$archive/$file" --output "$saved"
            printf '%s  %s\n' "$hash" "$saved" | sha256sum --check --status
            package_paths[$name]=$saved
            package_versions[$name]=$version
        done < "$GNUPGHOME/previous"
        ;;
    404) ;;
    *) printf 'Could not read previous APT archive (HTTP %s).\n' "$status" >&2; exit 1 ;;
esac

for artifact in "${package_paths[@]}"; do
    install -m 0644 "$artifact" "$apt_site/pool/${artifact##*/}"
done
printf '%s\n' "${!package_paths[@]}" | LC_ALL=C sort > "$apt_site/packages.txt"

git rev-parse HEAD > "$apt_site/source-commit.txt"
git ls-files --stage | awk '$1 == "160000" {print $2, $4}' > "$apt_site/source-components.txt"

cat > "$site/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>COSMIC CE Canary APT archive</title>
<h1>COSMIC CE Canary APT archive</h1>
<p>This archive serves signed Canary updates to APT on Pop!_OS 24.04 (amd64).</p>
<ul>
  <li><a href="https://github.com/krakotay/cosmic-ce#keep-selected-canary-packages-updated-on-popos">Configure APT for selected packages</a></li>
  <li><a href="apt/packages.txt">List packages in the APT archive</a></li>
  <li><a href="https://github.com/krakotay/cosmic-ce/releases/tag/canary">Download individual DEBs and RPMs</a></li>
</ul>
</html>
HTML

cd "$apt_site"
apt-ftparchive packages pool > "$index/Packages"
gzip -n -9 -c "$index/Packages" > "$index/Packages.gz"
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=cosmic-ce-canary \
    -o 'APT::FTPArchive::Release::Label=COSMIC CE Canary' \
    -o APT::FTPArchive::Release::Suite=canary \
    -o APT::FTPArchive::Release::Codename=noble \
    -o APT::FTPArchive::Release::Architectures=amd64 \
    -o APT::FTPArchive::Release::Components=main \
    release dists/noble > dists/noble/Release

gpg --batch --local-user "$fingerprint" --clearsign --output dists/noble/InRelease dists/noble/Release
gpg --batch --local-user "$fingerprint" --armor --detach-sign --output dists/noble/Release.gpg dists/noble/Release
gpgv --keyring "$GNUPGHOME/cosmic-ce.gpg" dists/noble/InRelease
