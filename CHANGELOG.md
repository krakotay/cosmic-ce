# COSMIC CE changelog

This changelog covers user-facing differences from upstream COSMIC.

## Unreleased

- **Screenshots** show open windows in a grid. The active window is placed in the cell nearest the pointer on its display, even if the pointer is stationary. Previews load progressively, and the selected window is captured at full resolution.
- **Screenshots** copy the PNG to the clipboard even after the picker closes and returns focus to the desktop.
- **Files** shows readable file types and can sort by type. It offers optional binary size units (KiB, MiB, GiB) and opt-in glob search from the View menu.
- **Panel** reserves a fixed width for the input source indicator so switching keyboard layouts keeps nearby applets in place.
- **Viewer** raises the raster texture limit from 2048 to 8192 pixels for sharper viewing of large images.
- **Packaging** provides Pop!_OS DEBs and Fedora RPMs for individual components or the full desktop, with Canary and Stable channels.
- **Canary** publishes each successful DEB and RPM to GitHub Releases as soon as its build finishes, including single-component runs on `master`. Each result replaces the previous file at the same download URL. The signed installer list and the Pop!_OS APT archive retain the last successful version of each package when a build fails or skips it.
- **Fedora packaging** builds Workspaces with its current Just recipes and reduces peak compiler memory for Canary Settings builds.
