CC      ?= clang
CFLAGS  ?= -O2 -Wall -Wextra -Werror -Wno-unused-parameter
CFLAGS  += -fobjc-arc -mmacosx-version-min=14.0
LDFLAGS += -framework Foundation -framework CoreGraphics -framework IOKit
# Developer ID to sign with, e.g. `make SIGN_ID=<sha1>`; ad hoc when unset.
SIGN_ID ?= -
PREFIX  ?= $(HOME)/.local

SRC = src/main.m src/VDVirtualDisplay.m

build/vdisplay: $(SRC) src/VDVirtualDisplay.h
	@mkdir -p build
	$(CC) $(CFLAGS) $(SRC) $(LDFLAGS) -arch arm64 -arch x86_64 -o $@
	codesign --force --options runtime --timestamp=none --sign "$(SIGN_ID)" $@

install: build/vdisplay
	install -d $(PREFIX)/bin
	install -m 755 build/vdisplay $(PREFIX)/bin/vdisplay

clean:
	rm -rf build

.PHONY: install clean
