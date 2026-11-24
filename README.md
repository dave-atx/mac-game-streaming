# mac-game-streaming

Stream Windows games from a Mac to an Apple TV with Sunshine and Moonlight: a free Wine engine instead of
CrossOver, a virtual display that keeps the stream off your desktop, and a controller with rumble.

The guide is still being written. What's here so far:

- `vdisplay/`: a headless virtual display for Sunshine to capture (`make install`).
- `scripts/gs`: status and control for the whole setup (`gs status`, `gs up`, `gs down`, `gs quit`, `gs logs`).
- `scripts/build-engine-fixes.sh`: rebuilds the engine's `winebus.so` with SDL (controllers) and
  `winecoreaudio.so` with an audio crackle fix.
- `examples/mass-effect-le/`: launch, quit and setup scripts for Mass Effect Legendary Edition through Steam and the
  EA app, plus the matching Sunshine `apps.json` entry.

Configuration lives in `~/.config/mac-game-streaming/config.env`; start from `config.env.example`.
