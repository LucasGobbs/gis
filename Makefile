# gis root makefile: the app (CMake here) plus the shared shader bake.
# The Odin app lives in legacy/ (its own Makefile) until the cutover lands.
ODIN      ?= odin
SLANG     ?= vendor/slang/bin/slangc
GOOSE_DIR ?= vendor/goose
GOOSE     := $(GOOSE_DIR)/src/tools/build
GOOSE_BIN := $(GOOSE_DIR)/goose-build
GOOSE_SRC := $(wildcard $(GOOSE)/*.odin)

.PHONY: all shaders configure build run build-asan run-asan test clean bundle-apple

all: build

$(GOOSE_BIN): $(GOOSE_SRC)
	$(ODIN) build $(GOOSE) -out:$(GOOSE_BIN) -o:aggressive -microarch:native -no-bounds-check

# Baked glue + scene artifacts (src/generated): consumed by the app
# (and by legacy/, which runs the same command).
shaders: $(GOOSE_BIN)
	$(GOOSE_BIN) --manifest goose.json --slang $(SLANG)

# The app (CMake at the repo root). Prereqs: brew install qt sdl3 qscintilla2 cmake.
BUILD_DIR  := build
CONFIGURE := cmake -B $(BUILD_DIR) -S . \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
	-DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt

configure:
	$(CONFIGURE)

build: configure
	cmake --build $(BUILD_DIR)

# ASan/UBSan build for development: catches heap races/overflows like the
# reflection mid-write reads. Same sources; separate build dir.
BUILD_DIR_ASAN := build-asan
build-asan: configure
	cmake -B $(BUILD_DIR_ASAN) -S . \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
		-DCMAKE_PREFIX_PATH="/opt/homebrew/opt/qt;/opt/homebrew/opt/sdl3" \
		-DCMAKE_CXX_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer" \
		-DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined"
	cmake --build $(BUILD_DIR_ASAN)

run: shaders build
	./build/gis_host $(ARGS)

# Same, under ASan/UBSan (slower; use when hunting the hot-reload races).
# asan.supp silences the known Qlementine 1.5.2 startup UAF (upstream dep
# bug) so OUR memory bugs are the ones that surface.
run-asan: shaders build-asan
	ASAN_OPTIONS="suppressions=asan.supp:detect_leaks=0" \
		UBSAN_OPTIONS="suppressions=ubsan.supp:print_stacktrace=1" \
		./build-asan/gis_host $(ARGS)

test: build
	cd $(BUILD_DIR) && QT_QPA_PLATFORM=offscreen ctest --output-on-failure

clean:
	rm -rf $(BUILD_DIR) $(BUILD_DIR_ASAN)

# Self-contained macOS bundle + zip under builds/apple (see
# tools/package_macos.sh). `make bundle-apple BUNDLE_VERSION=0.2.0`;
# `tools/package_macos.sh --render-icon` also re-renders the icon.
bundle-apple:
	tools/package_macos_cpp.sh $(BUNDLE_VERSION)
