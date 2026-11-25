#!/usr/bin/env bash
set -euo pipefail

packages=$(realpath "${1:?package artifact directory}")
site=$(realpath -m "${2:?APT archive output directory}")
keyring=$(realpath packaging/cosmic-ce-archive.asc)
export GNUPGHOME
GNUPGHOME=$(mktemp -d)
trap 'gpgconf --kill gpg-agent; rm -rf "$GNUPGHOME"' EXIT

gpg --batch --import "$keyring"
printf '%s\n' "${APT_SIGNING_KEY:?missing APT signing key}" | gpg --batch --import
unset APT_SIGNING_KEY
fingerprint=$(gpg --batch --show-keys --with-colons "$keyring" | awk -F: '$1 == "fpr" && !seen++ {print $10}')

apt_site="$site/apt"
index=dists/noble/main/binary-amd64
mkdir -p "$apt_site/pool" "$apt_site/$index"
install -m 0644 "$keyring" "$apt_site/cosmic-ce-archive.asc"

shopt -s nullglob
artifacts=("$packages"/deb-*/*.deb)
test "${#artifacts[@]}" -gt 0
declare -A package_names
for artifact in "${artifacts[@]}"; do
    name=$(dpkg-deb --field "$artifact" Package)
    version=$(dpkg-deb --field "$artifact" Version)
    architecture=$(dpkg-deb --field "$artifact" Architecture)
    [[ "$version" == *+cosmicce0.build* && "$architecture" =~ ^(amd64|all)$ ]]
    if [[ -v package_names[$name] ]]; then
        printf 'Multiple artifacts provide %s\n' "$name" >&2
        exit 1
    fi
    package_names[$name]=1
    install -m 0644 "$artifact" "$apt_site/pool/${artifact##*/}"
done
[[ -v package_names[cosmic-session] && -v package_names[cosmic-comp] ]]
printf '%s\n' "${!package_names[@]}" | LC_ALL=C sort > "$apt_site/packages.txt"

git rev-parse HEAD > "$apt_site/source-commit.txt"
git ls-files --stage | awk '$1 == "160000" {print $2, $4}' > "$apt_site/source-components.txt"

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
gpg --batch --dearmor --output "$GNUPGHOME/cosmic-ce.gpg" "$keyring"
gpgv --keyring "$GNUPGHOME/cosmic-ce.gpg" dists/noble/InRelease
