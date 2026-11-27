#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_dir="$root/${COMPONENT:?}"
build_number="${GITHUB_RUN_ID:?}.${GITHUB_RUN_ATTEMPT:?}"
[[ "$build_number" =~ ^[0-9]+[.][0-9]+$ ]]
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-2}
export CARGO_NET_GIT_FETCH_WITH_CLI=true
export CMAKE_POLICY_VERSION_MINIMUM=3.5

source /etc/os-release
[[ "$ID" == fedora && "$VERSION_ID" == 45 && "$(uname -m)" == x86_64 ]]
tools=(git rpm-build tar)
if [[ -f "$source_dir/Cargo.lock" ]]; then
    tools+=(cargo cargo-rpm-macros cmake gcc-c++ make nasm systemd-rpm-macros)
    if [[ -n "${SCCACHE_DIR:-}" ]]; then
        tools+=(sccache)
        export RUSTC_WRAPPER=sccache CARGO_INCREMENTAL=0
    fi
fi
dnf5 -y --setopt=install_weak_deps=False install "${tools[@]}"
git config --system http.lowSpeedLimit 1000
git config --system http.lowSpeedTime 45

if [[ "${RUSTC_WRAPPER:-}" == sccache && -n "${SCCACHE_DIR:-}" ]]; then
    # Keep paths to RPM sources and vendored crates stable across CI containers.
    work=/var/tmp/cosmic-ce-rpm-build
    mkdir "$work"
else
    work=$(mktemp -d)
fi
trap 'rm -rf -- "$work"' EXIT
sources="$work/SOURCES"
mkdir "$sources"
git config --system --add safe.directory "$source_dir"
source_sha=$(git -C "$source_dir" rev-parse HEAD)
source_date=$(git -C "$source_dir" show -s --format=%cs HEAD)

name=$COMPONENT
case "$COMPONENT" in
    cosmic-icons) name=cosmic-icon-theme ;;
    cosmic-workspaces-epoch) name=cosmic-workspaces ;;
esac
spec="$work/$name.spec"

fetch_at_commit() {
    local url=$1 commit=$2 path=$3
    shift 3
    local -a fetch_args=(--no-tags --depth=1 "$url" "$commit")
    if (( $# )); then
        # Fedora dist-git serves branch history but rejects direct fetches of old commits.
        fetch_args=(--no-tags "$url" "$1")
    fi
    git init -q "$path"
    for attempt in 1 2 3; do
        if git -C "$path" fetch "${fetch_args[@]}"; then
            git -C "$path" checkout --quiet --detach "$commit"
            [[ "$(git -C "$path" rev-parse HEAD)" == "$commit" ]]
            return
        fi
    done
    return 1
}

fedora_packaging="$work/cosmic-packaging"
case "$name" in
    cosmic-bg|cosmic-initial-setup|cosmic-settings|cosmic-viewer|pop-launcher|xdg-desktop-portal-cosmic)
        # Fedora COSMIC SIG's nightly adjustments for these upstream sources.
        fetch_at_commit https://forge.fedoraproject.org/cosmic/cosmic-packaging.git \
            19ad5e84fbb7c4f175bf389559f5780398f683ff "$fedora_packaging"
        ;;
esac

case "$name" in
    cosmic-sound-theme)
        cp "$root/packaging/fedora/$name.spec" "$spec"
        ;;
    *)
        dist_git="$work/dist-git"
        if [[ "$name" == cosmic-viewer ]]; then
            cp -r "$fedora_packaging/staging/$name" "$dist_git"
        else
            commit=$(awk -v name="$name" '$1 == name {print $2}' "$root/packaging/fedora/dist-git.txt")
            [[ "$commit" =~ ^[0-9a-f]{40}$ ]]
            fetch_at_commit "https://src.fedoraproject.org/rpms/$name.git" "$commit" "$dist_git" refs/heads/f45
        fi
        for patch in "$fedora_packaging/patches/$name"/*.patch; do
            [[ ! -f "$patch" ]] || git -C "$dist_git" apply "$patch"
        done
        cp "$dist_git/$name.spec" "$spec"
        find "$dist_git" -maxdepth 1 -type f ! -name '.*' ! -name '*.spec' ! -name sources \
            -exec cp -t "$sources" -- {} +
        # Use the pinned component from this checkout, with the Fedora package layout.
        sed -Ei \
            -e 's/^Version:.*/Version: 1.12.0/' \
            -e "s/^%global commit .*/%global commit $source_sha/" \
            -e "s/^%global commitdatestring .*/%global commitdatestring $source_date/" \
            -e "s/^Source0:.*/Source0: $name.tar.gz/" \
            -e 's/^Source1:.*vendor-.*/Source1: vendor.tar.gz/' \
            -e 's/^Source2:.*vendor-config-.*/Source2: vendor-config.toml/' \
            -e "s/^(%autosetup .* -n |%autosetup -n )[^ ]+/\\1$name/" \
            -e "s/date --utc '%\{commitdatestring\}'/%{commitdatestring}/g" \
            "$spec"
        if [[ "$name" == cosmic-viewer ]]; then
            # Keep the pinned source's bundled codec, which also works without RPM Fusion.
            sed -i -e '/^Patch:.*Use-system-libheif/d' \
                -e '/^Requires:.*libheif-ffmpeg/d' \
                -e '/^License:/s/$/ AND LGPL-3.0-or-later/' \
                -e '/^%license LICENSE$/a %license vendor/libheif-sys/vendor/libheif/COPYING' "$spec"
        elif [[ "$name" == xdg-desktop-portal-cosmic ]]; then
            sed -i 's/^just build-release --bin /just build-release --offline --frozen --bin /' "$spec"
        elif [[ "$name" == cosmic-workspaces ]]; then
            sed -i \
                -e 's/^BuildRequires:[[:space:]]*make$/BuildRequires:  just/' \
                -e 's/^make$/just build-release --offline --frozen/' \
                -e 's/^make install DESTDIR=%{buildroot} prefix=%{_prefix}$/just rootdir=%{buildroot} prefix=%{_prefix} install/' \
                "$spec"
        fi
        ;;
esac
sed -i "s/^Release:.*/Release: 1000.cosmicce.$build_number%{?dist}/" "$spec"
sed -i '/^%changelog$/,$d' "$spec"
{
    printf '\n%%changelog\n* %s COSMIC CE <cosmic-ce@users.noreply.github.com>\n' "$(LC_ALL=C date -ud "$source_date" '+%a %b %d %Y')"
    printf -- '- Build from COSMIC source %s\n' "$source_sha"
} >> "$spec"
dnf5 -y --setopt=install_weak_deps=False builddep "$spec"

if [[ -f "$source_dir/.gitattributes" ]] && grep -q filter=lfs "$source_dir/.gitattributes"; then
    # The checkout has hydrated Git LFS content. A git archive would restore its pointers.
    if git -C "$source_dir" grep -Il '^version https://git-lfs[.]github[.]com/spec/v1$' >&2; then
        echo "Fetch $COMPONENT Git LFS objects before building." >&2
        exit 1
    fi
    git -C "$source_dir" ls-files -z |
        tar -czf "$sources/$name.tar.gz" -C "$source_dir" --transform="s,^,$name/,S" --null -T -
else
    git -C "$source_dir" archive --format=tar.gz --prefix="$name/" HEAD > "$sources/$name.tar.gz"
fi

if grep -q '^Source1: vendor.tar.gz$' "$spec"; then
    tar -xzf "$sources/$name.tar.gz" -C "$work"
    (
        cd "$work/$name"
        while read -r patch; do
            git apply "$sources/$patch"
        done < <(awk '/^Patch[0-9]*:/ {print $2}' "$spec")
        for attempt in 1 2 3; do
            if cargo vendor --locked > "$sources/vendor-config.toml"; then
                break
            fi
            if (( attempt == 3 )); then
                exit 1
            fi
        done
        find vendor -name '*.rs' -type f -exec chmod a-x {} +
        tar -czf "$sources/vendor.tar.gz" vendor
    )
    rm -rf -- "$work/$name"
fi

if [[ "$name" == cosmic-settings && "${CHANNEL:-canary}" == canary ]]; then
    # Fedora forces full Rust debug info even without a debuginfo subpackage.
    # Avoid whole-program LTO and full debug info on the hosted runner.
    export CARGO_PROFILE_RELEASE_LTO=off
    sed -i '/^just build-release /i export RUSTFLAGS="${RUSTFLAGS/-Cdebuginfo=2/-Cdebuginfo=0}"' "$spec"
fi
rpmbuild --define "_topdir $work" --define 'debug_package %{nil}' -bb "$spec"
if [[ "${RUSTC_WRAPPER:-}" == sccache ]]; then
    sccache --show-stats || true
fi

mkdir -p "$root/canary-rpms"
shopt -s nullglob
packages=("$work"/RPMS/{x86_64,noarch}/*.rpm)
(( ${#packages[@]} ))
for package in "${packages[@]}"; do
    [[ "$(rpm -qp --qf '%{RELEASE}' "$package")" == "1000.cosmicce.$build_number.fc45" ]]
    install -m 0644 "$package" "$root/canary-rpms/"
done
