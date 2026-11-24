#!/bin/sh
# One-time Direct3D setup for the ME LE prefix on the free engine, mirroring frankea/Whisky's split:
#  - Steam's Chromium helper draws with DXVK (Vulkan via MoltenVK). With Wine's builtin d3d11 its window is
#    black; with DXMT it never presents ("cross-process swapchain not supported yet").
#  - The games use DXMT (D3D11 on Metal), installed next to each game's .exe: Windows loads DLLs from the
#    application directory first, so DXMT and DXVK can share the prefix even though both ship d3d11.dll.
# winemetal.dll stays the engine's builtin (it must match the engine's winemetal.so).
GS_HOME="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
. "$GS_HOME/scripts/wine-env.sh"
S32="$WINEPREFIX/drive_c/windows/system32"; S64="$WINEPREFIX/drive_c/windows/syswow64"
W="$GS_RUNTIME/Wine/lib/wine"
# system32/syswow64: DXVK d3d11/d3d10core; this DXVK build has no 64-bit dxgi, so dxgi stays Wine's builtin.
cp "$GS_RUNTIME/DXVK/x64/d3d11.dll" "$GS_RUNTIME/DXVK/x64/d3d10core.dll" "$S32/"
cp "$W/x86_64-windows/dxgi.dll" "$S32/dxgi.dll"
cp "$GS_RUNTIME/DXVK/x32/d3d11.dll" "$GS_RUNTIME/DXVK/x32/d3d10core.dll" "$S64/"
cp "$W/i386-windows/dxgi.dll" "$S64/dxgi.dll"
# DXMT next to each game and the launcher (the launcher draws with D3D11 and exits with code 1 on
# Wine's builtin d3d11).
GAME="$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps/common/Mass Effect Legendary Edition/Game"
for dir in ME1/Binaries/Win64 ME2/Binaries/Win64 ME3/Binaries/Win64 Launcher; do
  cp "$GS_RUNTIME/DXMT/x64/d3d11.dll" "$GS_RUNTIME/DXMT/x64/dxgi.dll" "$GS_RUNTIME/DXMT/x64/d3d10core.dll" \
    "$GAME/$dir/"
done
key() { echo "HKCU\\Software\\Wine\\AppDefaults\\$1\\DllOverrides"; }
for exe in MassEffect1.exe MassEffect2.exe MassEffect3.exe MassEffectLauncher.exe; do
  for dll in d3d11 dxgi d3d10core; do wine reg add "$(key $exe)" /v $dll /t REG_SZ /d native /f >/dev/null; done
done
for dll in d3d11 d3d10core; do wine reg add "$(key steamwebhelper.exe)" /v $dll /t REG_SZ /d native /f >/dev/null; done
# Wait for Wine to exit only if nothing else (e.g. Steam) is running in the prefix.
pgrep -qf "steam.exe" || wineserver -w
