# Upstream sync review

You are reviewing an upstream herdr update before it is rebased into a personal hardened fork. The report directory is given in the request (`fork/reports/<date>_<old>_<new>/`). Read `summary.md` first, then the files it lists. Do not modify any file. Deliver an assessment only.

## Threat model

herdr is a terminal multiplexer and coding-agent runtime that runs unsandboxed as the user on macOS and Linux. The fork exists to catch, before building, any upstream change that:

1. adds or changes network egress (the only accepted egress is `curl` to herdr.dev for the update check and manifest refresh, both disabled by config, and `git` to GitHub for plugin install, which is not used);
2. reads secrets or protected data: macOS Keychain, Security.framework, TCC-protected locations, `~/.ssh`, `~/.gnupg`, `~/.aws`, browser profiles, the clipboard beyond the existing OSC 52 write and image paste;
3. adds a code-execution path that something other than the user controls: new process spawns with non-argv arguments, shell `-c` strings built from data, `dlopen`, new build scripts or proc macros, config-driven commands, hot-reloaded files;
4. widens what a pane, a remote endpoint, a plugin or a hook can make the server or the local client do (socket API methods, escape-sequence relays, OSC handlers, integration writes into other agents' config);
5. changes build inputs: new crates, new publishers, git or path sources, `.cargo` config, `RUSTFLAGS`, linker or runner settings, Zig fetch URLs or hashes, vendored libghostty-vt commit, local patches;
6. adds persistence or privilege: launchd, cron, login items, setuid, file mode changes, writes outside `~/.config/herdr` and `~/.local/state/herdr`.

Things that are not findings here: style, performance, bugs without a security consequence, test-only files, documentation.

## Procedure

1. `commits.txt`: list every subject mentioning update, network, curl, fetch, download, install, platform, macos, launchd, keychain, security, unsafe, vendor, ghostty, plugin, hook, socket, api, remote, ssh, permission or mode. These commits get a full read of their diff in `watchlist.diff`.
2. `deps-delta.txt`: for every added crate say what it does, whether it touches network, filesystem, processes or `unsafe`, and which herdr dependency pulls it in (`cargo tree --locked -i <crate>`). Any source other than crates.io or `path` is a stop. Version bumps of crates on the `[bans] deny` list in `fork/deny.toml` cannot occur; a major bump of a crate that does I/O or FFI is worth a sentence.
3. `vendor-and-build.diff`: any new fetch URL, content hash, build step, link flag, environment read, or patch content is a finding until explained. If `summary.md` reports a vendored libghostty-vt commit change, open the Ghostty compare link, list the commits touching `src/terminal`, `src/terminfo`, `pkg/` or `build.zig`, and check the advisories page for anything in the range.
4. `watchlist.diff`: read it in full. For each hunk answer: does it change what gets executed, connected to, read, written, or trusted? Pay attention to `src/platform`, `src/update.rs`, `src/noninteractive_process.rs`, `src/api`, `src/integration`, `src/client/endpoint`, `crates/ghostty-vt/src`.
5. `flags.txt`: every hit is either explained by a hunk you already assessed or becomes a finding. `unsafe` hits in `crates/ghostty-vt` need the FFI contract checked (lengths, lifetimes, null handling).
6. `new-files.txt` and `binaries.txt`: name each new file's purpose. Any binary file outside `assets/` and `docs/` is a stop until its origin is known.

## Output

Start with one verdict line:

- `SAFE TO REBASE`: nothing in categories 1 to 6;
- `REBASE WITH FOLLOW-UP`: findings that need a config change, a baseline update, or a watch item but no code change;
- `STOP`: a finding in categories 1, 2, 3 or 5 that is not explained by the commit message and upstream discussion.

Then a findings table with columns: severity (stop / follow-up / note), file and line in the new revision, what changed, why it matters under the threat model, suggested action. Then a short list of upstream commits worth watching in later releases. Then, if the vendored parser changed, the Ghostty commit range summary. Keep the whole assessment under two screens; put diffs in fenced blocks only when the reader needs the exact text.
