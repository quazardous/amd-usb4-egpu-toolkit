# Publishing eGPU Indicator

**Status: prepared, not published.** Nothing has been uploaded anywhere.

## Build the zip

```bash
./gnome-extension/pack.sh
# → gnome-extension/dist/egpu-indicator@quazardous.github.io.shell-extension.zip
```

The zip holds only `metadata.json`, `extension.js`, `stylesheet.css`,
`icons/` and `LICENSE`. `dist/` is git-ignored.

Before each release: bump `version-name` in `metadata.json`, and add a new
GNOME release to `shell-version` only once it is stable and tested.

## Option A — GitHub Release (no review)

1. `./gnome-extension/pack.sh`
2. Create a release (tag e.g. `gnome-ext-v0.1`) and attach the zip.
3. Users install it with:

   ```bash
   gnome-extensions install --force egpu-indicator@quazardous.github.io.shell-extension.zip
   ```

   then log out and back in (Wayland).

## Option B — extensions.gnome.org

Upload at https://extensions.gnome.org/upload/ (account needed). Every
version is reviewed by hand against the
[review guidelines](https://gjs.guide/extensions/review-guidelines/review-guidelines.html).

### To settle before submitting

1. **"Extensions must not be AI-generated."** This extension was written with
   Claude Code (see the commit trailers). The guidelines allow AI as a
   development tool, but say developers SHOULD be able to justify and explain
   the submitted code, and that submissions showing signs of AI-generated
   output WILL be rejected. The maintainer has to review the code and own it
   before submitting; do not submit it as is.
2. **Functional without the hardware.** A reviewer without an NVIDIA eGPU sees
   nothing: the indicator stays hidden until one is plugged in, and Eject needs
   the toolkit. "Fundamentally broken" extensions are rejected. The
   description says so; a screenshot of the menu (to take) would help.
3. **External privileged helper.** Allowed through pkexec on a root-owned,
   non-user-writable file, which is what is done, but external scripts are
   "strongly discouraged". The description explains the dependency.

### Guidelines checklist

| Guideline | How the extension complies |
|---|---|
| Only static resources at initialization | The `Extension` subclass creates nothing until `enable()` |
| Destroy objects, disconnect signals, remove sources in `disable()` | `disable()` destroys the indicator; its `destroy()` removes the poll timer; the menu signal is bound with `connectObject` to the indicator |
| No deprecated modules, no Gtk/Gdk/Adw in the shell | ESM `gi://` imports only; no preferences window |
| No excessive logging | One `console.error` on an unexpected exception |
| Spawn processes carefully | Async `Gio.Subprocess` only; `nvidia-smi` under `timeout`, never stacked, menu open only; `/proc` walk in a subprocess, off the main loop |
| Privileged subprocess not user-writable | `pkexec /usr/local/lib/amd-usb4-egpu-toolkit/egpu-eject.sh`, installed 0755 root:root by `setup-compute.sh` |
| metadata.json well-formed | `uuid` `name@namespace`; `shell-version` `["50"]` (stable only); `url` to GitHub; no `session-modes`, no `donations` |
| GPL-compatible license | MIT, `LICENSE` in the zip |
| Trademarks | "NVIDIA" only as a descriptive word in text; the icon is a generic graphics card |
| No unnecessary files | `pack.sh` ships the five items above only |
| Linter | ESLint 9 `recommended` (+ GJS globals): 0 errors, 0 warnings (2026-10-09) |

### Still to do

- Take a screenshot of the open menu for the extensions.gnome.org page.
- Test the zip in a nested session, which needs `mutter-devkit`:
  `dbus-run-session gnome-shell --devkit --wayland`
