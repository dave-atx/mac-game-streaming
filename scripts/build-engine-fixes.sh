#!/bin/sh
# Rebuild two unix modules of the free engine from its exact winecx source and install them:
#  - winebus.so with SDL2 support, plus an x86_64 SDL2 (controllers);
#  - winecoreaudio.so with patches/winecoreaudio-render-buffer.patch (audio crackling).
# Originals are kept as <name>.orig; installs swap files atomically so a running Wine is unharmed.
#
# winebus:
# dappermint/winecx-gptk builds winebus.so without SDL ("SDL support not compiled in!"), so no
# gamepad reaches XInput. This builds the unix half from the runtime's exact winecx commit with
# SONAME_LIBSDL2 set, links it against the runtime's own ntdll.so (as the runtime's CI does), and
# puts libSDL2-2.0.0.dylib in Wine/lib, which winebus.so's @loader_path/../../ rpath finds.
# Same approach as Bridgeplay's docs/WINECX.md (Controllers).
#
# Needs: Xcode CLT, cmake, Homebrew bison and mingw-w64 (`brew install bison mingw-w64`) (Wine's configure requires a PE compiler
# even though only unix objects are built).
set -eu
GS_HOME="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
. "$GS_HOME/scripts/wine-env.sh"

# The engine release these fixes are built for; its own modules must match, since winebus.so and
# winecoreaudio.so link against the runtime's ntdll.so. CI downloads this release and checks the hash.
# Read with sed by the engine-fixes workflow and package-engine-fixes.sh.
# shellcheck disable=SC2034
RUNTIME_TAG=runtime-v4.8.1
# shellcheck disable=SC2034
RUNTIME_SHA256=e8b23bafa4e41be6c8ad468581bc92b86758bfd13c6fb4091585a33a4ec257d7
WINECX_COMMIT=9f3f6447844add700bc0dde650e4f398fd5f69ab   # runtime-v4.8.1 release notes
SDL_VERSION=2.32.10
SDL_SHA256=5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165
BUILD="${BUILD:-$HOME/Library/Caches/mac-game-streaming/engine-build}"
WINE_ROOT="$GS_RUNTIME/Wine"
UNIX="$WINE_ROOT/lib/wine/x86_64-unix"
export MACOSX_DEPLOYMENT_TARGET=26.0
mkdir -p "$BUILD" && cd "$BUILD"

# SDL2, x86_64 (Wine runs under Rosetta).
if [ ! -f sdl-build/libSDL2-2.0.0.dylib ]; then
  [ -f "SDL2-$SDL_VERSION.tar.gz" ] || curl -fsSL -o "SDL2-$SDL_VERSION.tar.gz" \
    "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VERSION/SDL2-$SDL_VERSION.tar.gz"
  echo "$SDL_SHA256  SDL2-$SDL_VERSION.tar.gz" | shasum -a 256 -c -
  tar xzf "SDL2-$SDL_VERSION.tar.gz"
  cmake -S "SDL2-$SDL_VERSION" -B sdl-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DSDL_STATIC=OFF -DSDL_TEST=OFF
  cmake --build sdl-build -j8
fi

# winecx source at the runtime's commit, configured for x86_64.
if [ ! -d winecx/.git ]; then
  git init -q winecx
  git -C winecx remote add origin https://github.com/dappermint/winecx.git
fi
git -C winecx fetch -q --depth 1 origin "$WINECX_COMMIT"
git -C winecx checkout -q -f FETCH_HEAD
# Render buffer = half Wine's period, so CoreAudio pulls never outrun what the game queued
# (from raymondchins/Bridgeplay winecoreaudio-patch, verified there against crackling).
git -C winecx apply "$GS_HOME/patches/winecoreaudio-render-buffer.patch"
mkdir -p wine-build && cd wine-build
if [ ! -f Makefile ]; then
  PATH="$(brew --prefix bison)/bin:$PATH" ac_cv_func_pipe2=no arch -x86_64 ../winecx/configure \
    --host=x86_64-apple-darwin24 --enable-win64 --enable-archs=x86_64 --disable-tests \
    --without-x --without-wayland --without-oss --without-alsa --without-pulse --without-sane \
    --without-usb --without-v4l2 --without-pcap --without-capi --without-opencl --without-cups \
    --without-freetype --without-gstreamer --without-ffmpeg --without-gnutls --without-krb5 \
    --without-netapi --without-gphoto --without-vulkan --without-inotify --without-sdl \
    CC="/usr/bin/clang -arch x86_64" CXX="/usr/bin/clang++ -arch x86_64" \
    CFLAGS="-O2 -Wno-error=implicit-function-declaration" >../configure.log
fi
PATH="$(brew --prefix bison)/bin:$PATH" arch -x86_64 make -j8 \
  dlls/winecoreaudio.drv/authorization.o dlls/winecoreaudio.drv/coreaudio.o dlls/winecoreaudio.drv/coremidi.o \
  dlls/winebus.sys/bus_iohid.o dlls/winebus.sys/bus_udev.o \
  dlls/winebus.sys/bus_xbox360.o dlls/winebus.sys/hid.o dlls/winebus.sys/unixlib.o

# bus_sdl.o by hand: configure ran --without-sdl, so add the header and soname ourselves.
/usr/bin/clang -arch x86_64 -std=gnu23 -m64 -c -o dlls/winebus.sys/bus_sdl.o ../winecx/dlls/winebus.sys/bus_sdl.c \
  -Idlls/winebus.sys -I../winecx/dlls/winebus.sys -Iinclude -I../winecx/include -D__WINESRC__ -DWINE_UNIX_LIB \
  -Wall -pipe -fcf-protection=none -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing -fPIC \
  -fasynchronous-unwind-tables -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
  -I"../SDL2-$SDL_VERSION/include" -D_THREAD_SAFE -DHAVE_SDL_H '-DSONAME_LIBSDL2="libSDL2-2.0.0.dylib"'

/usr/bin/clang -arch x86_64 -o winebus.so -dynamiclib -install_name @rpath/winebus.so -Wl,-rpath,@loader_path/ \
  dlls/winebus.sys/bus_iohid.o dlls/winebus.sys/bus_sdl.o dlls/winebus.sys/bus_udev.o \
  dlls/winebus.sys/bus_xbox360.o dlls/winebus.sys/hid.o dlls/winebus.sys/unixlib.o \
  "$UNIX/ntdll.so" -framework IOKit -framework CoreFoundation
install_name_tool -add_rpath @loader_path/../../ winebus.so
codesign -fs - winebus.so

/usr/bin/clang -arch x86_64 -o winecoreaudio.so -dynamiclib -install_name @rpath/winecoreaudio.so -Wl,-rpath,@loader_path/ \
  dlls/winecoreaudio.drv/authorization.o dlls/winecoreaudio.drv/coreaudio.o dlls/winecoreaudio.drv/coremidi.o \
  "$UNIX/ntdll.so" -framework CoreFoundation -framework CoreAudio -framework AudioUnit -framework AudioToolbox \
  -framework CoreMIDI -framework AppKit -framework AVFoundation
install_name_tool -add_rpath @loader_path/../../ winecoreaudio.so
codesign -fs - winecoreaudio.so

install_atomically() {  # src dst
  [ -f "$2.orig" ] || [ ! -f "$2" ] || cp -p "$2" "$2.orig"
  cp "$1" "$2.new" && mv -f "$2.new" "$2"
}
install_atomically winebus.so "$UNIX/winebus.so"
install_atomically winecoreaudio.so "$UNIX/winecoreaudio.so"
codesign -fs - ../sdl-build/libSDL2-2.0.0.dylib
install_atomically ../sdl-build/libSDL2-2.0.0.dylib "$WINE_ROOT/lib/libSDL2-2.0.0.dylib"
echo "installed winebus.so (SDL), winecoreaudio.so (render buffer) and libSDL2 into $WINE_ROOT"
