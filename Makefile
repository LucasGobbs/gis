# gis root makefile: the C++/Qt app (cpp_port) plus the shared shader bake.
# The Odin app lives in legacy/ (its own Makefile) while parity is proven.
ODIN      ?= odin
SLANG     ?= vendor/slang/bin/slangc
GOOSE_DIR ?= vendor/goose
GOOSE     := $(GOOSE_DIR)/src/tools/build
GOOSE_BIN := $(GOOSE_DIR)/goose-build
GOOSE_SRC := $(wildcard $(GOOSE)/*.odin)

.PHONY: all shaders configure-cpp build-cpp run-cpp build-cpp-asan run-cpp-asan test-cpp clean-cpp clean bundle-apple

all: build-cpp

$(GOOSE_BIN): $(GOOSE_SRC)
	$(ODIN) build $(GOOSE) -out:$(GOOSE_BIN) -o:aggressive -microarch:native -no-bounds-check

# Baked glue + scene artifacts (src/generated): consumed by the cpp_port
# (and by legacy/, which runs the same command).
shaders: $(GOOSE_BIN)
	$(GOOSE_BIN) --manifest goose.json --slang $(SLANG)

# C++/Qt port. Prereqs: brew install qt sdl3 qscintilla2 cmake.
CPP_BUILD  := cpp_port/build
CPP_CONFIGURE := cmake -B $(CPP_BUILD) -S cpp_port \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
	-DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt

configure-cpp:
	$(CPP_CONFIGURE)
	ln -sf $(CURDIR)/$(CPP_BUILD)/compile_commands.json $(CURDIR)/cpp_port/compile_commands.json

build-cpp: configure-cpp
	cmake --build $(CPP_BUILD)

# ASan/UBSan build for development: catches heap races/overflows like the
# reflection mid-write reads. Same sources; separate build dir.
CPP_BUILD_ASAN := cpp_port/build-asan
build-cpp-asan: configure-cpp
	cmake -B $(CPP_BUILD_ASAN) -S cpp_port \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
		-DCMAKE_PREFIX_PATH="/opt/homebrew/opt/qt;/opt/homebrew/opt/sdl3" \
		-DCMAKE_CXX_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer" \
		-DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined"
	cmake --build $(CPP_BUILD_ASAN)

run-cpp: shaders build-cpp
	cd $(CURDIR) && ./cpp_port/build/gis_host $(ARGS)

# Same, under ASan/UBSan (slower; use when hunting the hot-reload races).
# cpp_port/asan.supp silences the known Qlementine 1.5.2 startup UAF
# (upstream dep bug) so OUR memory bugs are the ones that surface.
run-cpp-asan: shaders build-cpp-asan
	cd $(CURDIR) && ASAN_OPTIONS="suppressions=cpp_port/asan.supp:detect_leaks=0" \
		UBSAN_OPTIONS="suppressions=cpp_port/ubsan.supp:print_stacktrace=1" \
		./cpp_port/build-asan/gis_host $(ARGS)

test-cpp: build-cpp
	cd $(CPP_BUILD) && QT_QPA_PLATFORM=offscreen ctest --output-on-failure

clean-cpp:
	rm -rf $(CPP_BUILD)

clean: clean-cpp
	rm -rf $(CPP_BUILD_ASAN)

# Self-contained macOS bundle + zip under builds/apple (see
# tools/package_macos.sh). `make bundle-apple BUNDLE_VERSION=0.2.0`;
# `tools/package_macos.sh --render-icon` also re-renders the icon.
bundle-apple:
	tools/package_macos_cpp.sh $(BUNDLE_VERSION)
