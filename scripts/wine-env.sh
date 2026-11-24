# shellcheck shell=sh
# Sourced by every script: loads your config, then sets up the environment for the free WineCX engine
# (dappermint/winecx-gptk: CrossOver's open-source changes on Wine 11, as shipped by frankea/Whisky).
# The caller sets GS_HOME (this repo's root) first.
GS_CONFIG="${GS_CONFIG:-$HOME/.config/mac-game-streaming/config.env}"
if [ ! -f "$GS_CONFIG" ]; then
  echo "mac-game-streaming: no config at $GS_CONFIG (start from config.env.example)" >&2
  exit 78
fi
# shellcheck source=/dev/null
. "$GS_CONFIG"
: "${GS_RUNTIME:?set GS_RUNTIME in $GS_CONFIG}" "${WINEPREFIX:?set WINEPREFIX in $GS_CONFIG}"
export WINEPREFIX
export PATH="$GS_RUNTIME/Wine/bin:$PATH"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEMSYNC=1
# Direct3D: DXMT for the games, DXVK for Steam's Chromium helper, both per executable via AppDefaults
# (see examples/mass-effect-le/setup-d3d.sh). Never override d3d11/dxgi globally.
# Steam's CEF sandbox fails under Wine (frankea/Whisky sets this for every program).
export STEAM_DISABLE_CEF_SANDBOX=1
# No SDL_GAMECONTROLLERCONFIG: since OpenJoystickDriver 0.6.0-alpha.4, its default SDLCompatible pad
# (045E:0B13) is read by SDL 2's own Xbox driver. With the Generic persona, export the output of
# 'ojd virtual export-mapping generic' here instead.
