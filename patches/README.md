# Patches

`winecoreaudio-render-buffer.patch` fixes crackling audio by halving the CoreAudio device buffer for render streams.
It comes unchanged from Bridgeplay ([`winecoreaudio-patch/winecx-render-buffer.patch`](https://github.com/raymondchins/Bridgeplay/blob/6cf4b007985f9924a90a3bdf5325031bfe5be476/winecoreaudio-patch/winecx-render-buffer.patch),
commit `6cf4b00`), a fork of NotProton, and keeps Bridgeplay's license, GPL-3.0. It patches Wine's
`dlls/winecoreaudio.drv/coreaudio.c`, which is LGPL-2.1-or-later, so the patched file and the `winecoreaudio.so`
built from it are distributed under GPL-3.0.
