# COSMIC CE

## Project ownership

COSMIC CE is a community fork of System76's COSMIC desktop, maintained independently of the upstream Pop!_OS and COSMIC teams. COSMIC CE maintainers lack write access to the original `pop-os` repositories. Treat those repositories as read-only upstreams and apply CE changes in CE-owned forks.

Publish COSMIC CE packages through CE-owned infrastructure. The signed COSMIC CE Canary APT archive serves packages for Pop!_OS from this fork's GitHub Pages at `https://krakotay.github.io/cosmic-ce/apt`.

## Component forks

- When connecting a component fork, give it an `upstream` branch and a CE patch branch. Use the original component's default branch name for the CE branch, usually `master` or `main`.
- Set up the fork's GitHub Actions workflow to fast-forward `upstream` daily from the original `pop-os` repository, with a manual trigger as well. Apply CE patches on the CE branch and review upstream changes before integrating them there.
- Point `.gitmodules` at the fork and set `branch` to its CE patch branch. Pin the component commit that COSMIC CE should build.

## Changelog

- Maintain the root [`CHANGELOG.md`](CHANGELOG.md) as a user-facing record of the major features and fixes COSMIC CE adds to upstream COSMIC. Update it when adding or changing a CE feature or fix, and move unreleased entries under the release heading when publishing a release.
