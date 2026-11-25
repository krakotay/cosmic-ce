#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export DEB_BUILD_OPTIONS='parallel=2 noautodbgsym'
export CARGO_BUILD_JOBS=2

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gpg build-essential dpkg-dev git
curl --fail --silent --show-error --location \
    'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x63C46DF0140D738961429F4E204DD8AEC33A7AFF' \
    --output /tmp/pop-archive.asc
pop_fingerprint=$(gpg --batch --show-keys --with-colons /tmp/pop-archive.asc | awk -F: '$1 == "fpr" && !seen++ {print $10}')
test "$pop_fingerprint" = 63C46DF0140D738961429F4E204DD8AEC33A7AFF
install -m 0644 /tmp/pop-archive.asc /etc/apt/keyrings/pop-archive.asc
cat > /etc/apt/sources.list.d/pop-release.sources <<'APT'
Types: deb
URIs: https://apt.pop-os.org/release
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/pop-archive.asc 63C46DF0140D738961429F4E204DD8AEC33A7AFF
APT
apt-get update

cd "/src/${COMPONENT:?}"
git config --system --add safe.directory "$PWD"
if [[ "$COMPONENT" == cosmic-sound-theme ]]; then
    cp -r /src/packaging/cosmic-sound-theme/debian .
    cp LICENSE debian/copyright
fi

version=$(dpkg-parsechangelog --show-field Version)
canary_version="${version}+cosmicce0.build${GITHUB_RUN_NUMBER:?}.${GITHUB_RUN_ATTEMPT:?}"
{
    printf '%s (%s) noble; urgency=medium\n\n' "$(dpkg-parsechangelog --show-field Source)" "$canary_version"
    printf '  * COSMIC CE Canary build of %s.\n\n' "$(git rev-parse --short HEAD)"
    printf ' -- COSMIC CE <cosmic-ce@users.noreply.github.com>  %s\n\n' "$(date -R)"
    cat debian/changelog
} > debian/changelog.canary
mv debian/changelog.canary debian/changelog

apt-get build-dep -y --no-install-recommends ./
dpkg-buildpackage -b -us -uc

mkdir -p /src/canary-debs
for package in ../*.deb; do
    test "$(dpkg-deb --field "$package" Version)" = "$canary_version"
    install -m 0644 "$package" /src/canary-debs/
done
