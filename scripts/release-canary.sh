#!/usr/bin/env bash
set -euo pipefail

packages=$(realpath "${1:?package artifact directory}")
build_sha=${2:?build commit}
run_id=${3:?build run ID}
repository=${4:?GitHub repository}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
assets=$(mktemp -d)
trap 'rm -rf "$assets"' EXIT

bundle_script() {
    printf "#!/bin/sh\nset -eu\ninstaller=\$(cat <<'COSMIC_CE_APT_PAYLOAD'\n"
    cat "$root/scripts/cosmic-ce-apt.sh"
    printf 'COSMIC_CE_APT_PAYLOAD\n)\n'
    printf 'exec bash -c "$installer" %s %s\n' "$1" "$2"
}

bundle_script install.sh '"$@"' > "$assets/install.sh"
bundle_script rollback.sh 'rollback' > "$assets/rollback.sh"
sh -n "$assets/install.sh"
sh -n "$assets/rollback.sh"

archive="$assets/cosmic-ce-canary-amd64.tar.gz"
(
    cd "$packages"
    shopt -s nullglob
    debs=(deb-*/*.deb)
    [[ ${#debs[@]} -gt 0 ]]
    tar -czf "$archive" -- "${debs[@]}"
)
(
    cd "$assets"
    sha256sum install.sh rollback.sh cosmic-ce-canary-amd64.tar.gz > SHA256SUMS
)
cat > "$assets/notes.md" <<EOF
Rolling COSMIC CE Canary for Pop!_OS 24.04 (amd64).

- [Build run](https://github.com/$repository/actions/runs/$run_id)
- [Build source](https://github.com/$repository/tree/$build_sha)
- [APT installation and rollback](https://github.com/$repository#cosmic-ce-canary-apt-repository)
EOF

ref="repos/$repository/git/refs/tags/canary"
if current_sha=$(gh api "repos/$repository/git/ref/tags/canary" --jq .object.sha 2>/dev/null); then
    if [[ "$current_sha" != "$build_sha" ]]; then
        gh api --method PATCH "$ref" -f sha="$build_sha" -F force=true --silent
    fi
else
    gh api --method POST "repos/$repository/git/refs" -f ref=refs/tags/canary -f sha="$build_sha" --silent
fi

files=("$assets/install.sh" "$assets/rollback.sh" "$archive" "$assets/SHA256SUMS")
if gh release view canary --repo "$repository" >/dev/null 2>&1; then
    gh release upload canary "${files[@]}" --repo "$repository" --clobber
    gh release edit canary --repo "$repository" --title 'COSMIC CE Canary' \
        --prerelease --latest=false --notes-file "$assets/notes.md"
else
    gh release create canary "${files[@]}" --repo "$repository" --verify-tag \
        --title 'COSMIC CE Canary' --prerelease --latest=false --notes-file "$assets/notes.md"
fi
