# Installing the herdr fork

Builds from source on macOS and Linux, with the parser's runtime safety checks on and every background network call disabled. The reasoning is in `security-audit-2026-10-19.md`; the day-to-day commands are in `README.md`.

## 1. Prerequisites

Both platforms:

- `rustup` (https://rustup.rs). The repository pins the Rust toolchain in `rust-toolchain.toml`; rustup installs that exact version on the first `cargo` call.
- `git`, `make`, `curl`, `tar` with xz support.

macOS additionally:

- Xcode command line tools: `xcode-select --install`. They provide `otool`, `nm`, `strings` and `codesign` for the binary check.
- Do not install Zig from Homebrew for this; the fork pins its own copy below. If a Homebrew Zig is on `PATH`, the makefile's copy still wins.

Linux additionally:

- `binutils` (`readelf`, `nm`, `strings`) and a C toolchain for the few crates with C code, for example `build-essential` on Debian and Ubuntu.

## 2. Get the source

```sh
git clone git@github.com:<you>/herdr.git
cd herdr
git checkout fork
```

`master` mirrors upstream and carries nothing of ours; `fork` adds only the `fork/` directory.

## 3. Install nono and enter the build sandbox

nono is the one tool that runs outside the sandbox, so install it from a verified release rather than a pipe-to-shell script:

```sh
brew install nono                      # macOS
# Linux: download nono-v<ver>-<arch>-unknown-linux-gnu.tar.gz and SHA256SUMS.txt from
# https://github.com/nolabs-ai/nono/releases, verify, and put `nono` on PATH
nono setup --check-only
make -C fork nono-check                # validates fork/nono/herdr-build.json and prints the grants
make -C fork shell                     # everything from here on runs inside this shell
```

Inside the shell, install the audit tools and the pinned Zig:

```sh
make -C fork tools    # cargo-deny and cargo-audit, built with --locked
make -C fork zig      # Zig 0.16.0 into fork/toolchain/, checksum verified against the values pinned in the script
make -C fork upstream-remote
```

The sandbox denies `~/.ssh`, `~/.gnupg`, `~/.aws`, keychains, browser data and shell configs, limits writes to the repository and the Rust and Zig caches, and routes network through nono's proxy with only the hosts in section 7 allowed. If a build step fails with a permission or network error, `nono why --path <file> --op read` or `nono why --self --host <url>` explains which rule denied it; extend `fork/nono/herdr-build.json` only after understanding why the step needs it.

## 4. Configure herdr before the first run

Create or edit `~/.config/herdr/config.toml` (or `$XDG_CONFIG_HOME/herdr/config.toml`):

```toml
# Optional: skip the first-run welcome overlay (keybind hints only; it installs nothing).
onboarding = false

[update]
# Both are true by default. With both false a release build makes no network connection at all.
version_check = false    # stops the periodic fetch of herdr.dev/latest.json, preview.json and the Homebrew formula API
manifest_check = false   # stops the periodic fetch of herdr.dev/agent-detection/index.toml and the per-agent manifests
channel = "stable"       # irrelevant once version_check is off; kept explicit so a stray `herdr channel set` is visible in the file
```

There is no automatic update to turn off: the background check only reports a newer version, and installation happens solely through `herdr update` or `herdr channel set`. Never run either; the fork is rebuilt from source instead. There is no telemetry.

Verify:

```sh
make -C fork check-config
```

It fails if either flag is missing and warns about installed plugins or cached remote detection manifests under `~/.local/state/herdr/agent-detection/`. Delete that cache so only the bundled manifests are used.

What still reaches the network after this, and only when you ask for it: `herdr plugin install` (git clone from GitHub; the plan is no plugins), the remote-machine installer (unused), and clicking a hyperlink, which opens it in your browser.

## 5. Build, audit, check, install

```sh
make -C fork verify     # cargo build --release --locked, cargo deny, cargo audit, binary check
```

The build exports `LIBGHOSTTY_VT_OPTIMIZE=ReleaseSafe` and `HERDR_BUILD_CHANNEL=fork`, so `herdr --version` prints `<version>-fork`. On a first build for a platform the binary check fails because there is no baseline yet. Read `fork/out/<os>/` (linked libraries, flagged symbols, URLs, external command strings), then accept it:

```sh
make -C fork baseline
git add fork/baseline && git commit -m 'chore: add <os> binary baseline'
```

Expected on macOS: libSystem, CoreFoundation, Carbon and IOKit as linked libraries; no `Sec*`, `LA*` or TCC symbols; URLs limited to herdr.dev, github.com, formulae.brew.sh, json-schema.org and documentation links. Expected on Linux: libc, libm, libgcc_s and the dynamic loader; the standard library's spawn and socket symbols plus `dlsym`.

Install where agents cannot write. This step runs outside the nono shell because it needs `sudo`, and so does `git push`, which needs `~/.ssh`:

```sh
sudo make -C fork install                 # /usr/local/bin/herdr
make -C fork install PREFIX=$HOME/.local  # alternative, if $HOME/.local/bin is not writable by your agents
```

## 6. First run

```sh
herdr --version                 # <version>-fork
herdr integration status
herdr integration install <agent>   # optional, per agent you use; gives it session resume and hook-reported state
herdr
```

Optional for your own shells, so neither you nor herdr's git spawns run repository hooks:

```sh
git config --global core.hooksPath /dev/null
```

## 7. Build-time network

A build with warm caches makes no connection. A cold one fetches from exactly these hosts:

| Host | What |
|---|---|
| `static.rust-lang.org` | the pinned Rust toolchain, on the first `cargo` call |
| `ziglang.org` | Zig 0.16.0, `make -C fork zig` |
| `index.crates.io`, `static.crates.io` | Rust crates, checked against `Cargo.lock` |
| `github.com` | RustSec advisory database for cargo deny and cargo audit |
| `deps.files.ghostty.org` | Zig packages of the vendored terminal parser, content-hash pinned |
| `codeberg.org` | `translate-c`, the Zig C-header translator the parser build needs, content-hash pinned |

## 8. Upgrading later

See `README.md`: `make -C fork fetch sync-report`, review the report with `REVIEW.md`, then `make -C fork rebase verify install`.
