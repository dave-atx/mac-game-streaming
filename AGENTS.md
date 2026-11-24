# Notes for agents

Scripts and a small tool for streaming Windows games from a Mac to an Apple TV with Sunshine + Moonlight, on the
free dappermint/winecx-gptk Wine engine. Read this before changing anything: most of the rules below come from
incidents, not style.

## Layout and config

- `scripts/`: `gs` (status / control), `wine-env.sh` (loads config, sets up Wine), `build-engine-fixes.sh`,
  `sunshine/` (helpers Sunshine runs around a stream).
- `examples/mass-effect-le/`: the worked example (Steam + EA app). Game-specific code goes in an example folder,
  never in `scripts/`.
- `vdisplay/`: Objective-C. Keep it ObjC (not Swift): `VDVirtualDisplay.{h,m}` is meant to move into Sunshine's
  `src/platform/macos`, which has no Swift.
- **No hard-coded paths.** Every script sets `GS_HOME` (the repo root, via `realpath "$0"`) and sources
  `scripts/wine-env.sh`, which reads `~/.config/mac-game-streaming/config.env` (or `$GS_CONFIG`). A new setting is
  optional with a default, or goes in `config.env.example` with a comment.
- **Nothing personal in the repo:** no usernames, tokens, signing identities or hostnames. Examples use `/Users/YOU`.

## Rules from incidents

- **Never create or destroy a virtual display while the Mac is locked or its displays are asleep**, and never
  force-wake displays (`caffeinate -u`, `IOPMAssertionDeclareUserActivity`) while a display hotplug may be pending.
  Doing both wedged WindowServer until a forced restart. `vdisplay start` refuses while locked and `stop` defers
  removal until unlock; keep it that way. Test those paths with `touch $TMPDIR/vdisplay/simulate-lock`.
- **Never stop a bottle with a bare `wineserver -k` while a launcher may be syncing.** Killing Wine during the EA
  app's post-game cloud upload leaves a server-side lock, and the next launch fails with EC:10608. Use the
  example's quit script (`GS_QUIT`).
- **Sunshine undo commands must return quickly**, or Moonlight reports "quitting the app failed". Slow cleanup goes
  in a detached second half (see `me-quit.sh --finish`).
- **Never inline `sh -c '…'` in Sunshine's `apps.json`.** Its command splitting mangles nested quotes; call script
  files.
- **Never override `d3d11` / `dxgi` globally.** DXMT goes next to each game's exe, DXVK only for Steam's
  `steamwebhelper.exe`, both via `AppDefaults` (see `setup-d3d.sh`).
- **Don't set a `map` value under the winebus registry key** on this engine (heap overflow in unpatched
  `winebus.sys`).
- **Don't start Steam, launchers or games from an agent's shell.** Wine inherits the environment, including agent
  tokens. Launch through Sunshine or a plain login shell.
- On this engine Windows programs show up as `wine` in `ps`, and `pgrep MassEffect1` finds nothing. Use
  `wine winedbg --command "info proc"` for the Windows process tree.

## Testing

Run before committing:

```sh
shellcheck -x -S warning scripts/gs scripts/*.sh scripts/sunshine/*.sh examples/*/*.sh tests/trace/run.sh tests/trace/shim/*
make -C vdisplay
tests/trace/run.sh
```

`tests/trace/run.sh` runs the scripts against stand-in `wine` / `wineserver` / `cp` / `pgrep` in a fake HOME and
compares the commands they would run with `tests/trace/expected/`. After an intended behavior change, run it with
`--update` and review the diff of `expected/` like code. Anything that needs a real game, display or Wine (a
stream, `vdisplay start`, `build-engine-fixes.sh`) isn't covered; say so when reporting a change as tested.

CI (`.github/workflows/ci.yml`) runs the same three steps on a macOS runner.

`.github/workflows/engine-fixes.yml` builds the engine modules for the runtime pinned in
`scripts/build-engine-fixes.sh` (`RUNTIME_TAG`, `RUNTIME_SHA256`), checks them with
`scripts/package-engine-fixes.sh` (x86_64, exports identical to the runtime's originals, winebus loads SDL), and
releases them on `engine-fixes-*` tags with a provenance attestation. Moving to a new runtime means updating the
pins (tag, hash, `WINECX_COMMIT`) together and tagging a new release. The checks don't prove a controller works:
that still needs a game.

## Style

- POSIX `sh` with macOS's BSD tools (`sed -i ''`, no GNU options). Python only as `python3 -I`, standard library.
- Comments say why, especially when a line exists because of an incident.
- Commit messages: plain imperative subject, no prefix; a body when the why isn't obvious. No AI attribution.
