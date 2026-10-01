PREFIX ?= /usr/local
VERSION := $(shell sed -n 's/^let version = "\(.*\)"/\1/p' Sources/sapu/main.swift)
DIST := dist/sapu-$(VERSION)-macos-universal

# Swift Testing ships inside Xcode. With only the Command Line Tools installed, the compiler
# has to be pointed at the copy that comes with them.
CLT := /Library/Developer/CommandLineTools
ifeq ($(shell xcode-select -p 2>/dev/null),$(CLT))
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT)/Library/Developer/Frameworks \
	-Xswiftc -plugin-path -Xswiftc $(CLT)/usr/lib/swift/host/plugins/testing \
	-Xlinker -F -Xlinker $(CLT)/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT)/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT)/Library/Developer/usr/lib
endif

.PHONY: build test install uninstall dist clean

build:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

install: build
	install -d $(PREFIX)/bin
	install -m 755 .build/release/sapu $(PREFIX)/bin/sapu

uninstall:
	rm -f $(PREFIX)/bin/sapu

# A universal (Apple silicon + Intel) binary, packed the way the release workflow publishes it.
dist:
	swift build -c release --triple arm64-apple-macosx
	swift build -c release --triple x86_64-apple-macosx
	mkdir -p $(DIST)
	lipo -create -output $(DIST)/sapu \
		.build/arm64-apple-macosx/release/sapu .build/x86_64-apple-macosx/release/sapu
	cp LICENSE README.md $(DIST)/
	tar -C dist -czf $(DIST).tar.gz $(notdir $(DIST))
	cd dist && shasum -a 256 $(notdir $(DIST)).tar.gz > $(notdir $(DIST)).tar.gz.sha256
	@echo "Built $(DIST).tar.gz"

clean:
	swift package clean
	rm -rf dist
