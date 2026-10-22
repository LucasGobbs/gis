ODIN      ?= odin
SLANG     ?= vendor/slang/bin/slangc
GOOSE_DIR ?= ../goose
GOOSE     := $(GOOSE_DIR)/src/tools/build
GOOSE_BIN := $(GOOSE_DIR)/goose-build
GOOSE_SRC := $(wildcard $(GOOSE)/*.odin)
SRC       := ./src
BIN       := main
BIN_DEBUG := main_debug

RELEASE_FLAGS := -o:aggressive -microarch:native -no-bounds-check
# Perf-checked variant with asserts/bounds compiled out (matches the old
# release flags) for benchmarking only; the default build keeps them on so
# an invariant violation crashes/logs instead of corrupting state silently.
NOASSERT_FLAGS := -o:aggressive -microarch:native -no-bounds-check -disable-assert
DEBUG_FLAGS   := -debug -o:none
HOT_FLAGS     := -define:HOT_RELOAD=true

BUNDLE_VERSION ?= 0.1.0

.PHONY: all build shaders shaders-hot run run-optimized debug debug-optimized clean bundle-apple configure-cpp build-cpp run-cpp test-cpp clean-cpp

# The integrated ImGui editor (src/imgui_editor.odin) links the
# ImGuiColorTextEdit wrapper; every app build needs it. The wrapper MUST use
# the same IMGUI_DISABLE_OBSOLETE_* defines as the premake-built imgui lib.
APP_DEPS := vendor/ImGuiColorTextEdit/libite.a $(MD4C_LIB) $(TFD_LIB)
IMGUI_DEFINES := -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS -DIMGUI_DISABLE_OBSOLETE_KEYIO
IMGUI_INC := vendor/odin-imgui/build/deps/imgui
ITE_SRC := vendor/ImGuiColorTextEdit/TextEditor.cpp vendor/ImGuiColorTextEdit/TextEditor.h vendor/ImGuiColorTextEdit/ite/ite.cpp vendor/ImGuiColorTextEdit/ite/ite.h

vendor/ImGuiColorTextEdit/libite.a: $(ITE_SRC)
	clang++ -std=c++17 -O2 $(IMGUI_DEFINES) -c vendor/ImGuiColorTextEdit/TextEditor.cpp -I$(IMGUI_INC) -Ivendor/ImGuiColorTextEdit -o /tmp/TextEditor.o
	clang++ -std=c++17 -O2 $(IMGUI_DEFINES) -c vendor/ImGuiColorTextEdit/ite/ite.cpp -I$(IMGUI_INC) -Ivendor/ImGuiColorTextEdit -o /tmp/ite.o
	rm -f $@
	ar rc $@ /tmp/TextEditor.o /tmp/ite.o
	ranlib $@

MD4C_LIB := vendor/md4c/libmd4c.a

$(MD4C_LIB): vendor/md4c/md4c.c vendor/md4c/md4c.h
	cc -std=c11 -O2 -c vendor/md4c/md4c.c -o /tmp/md4c_obj.o
	rm -f $@
	ar rc $@ /tmp/md4c_obj.o
	ranlib $@

TFD_LIB := vendor/tinyfiledialogs/libtfd.a

$(TFD_LIB): vendor/tinyfiledialogs/tinyfiledialogs.c vendor/tinyfiledialogs/tinyfiledialogs.h
	cc -std=c11 -O2 -c vendor/tinyfiledialogs/tinyfiledialogs.c -o /tmp/tfd_obj.o
	rm -f $@
	ar rc $@ /tmp/tfd_obj.o
	ranlib $@


all: build

$(GOOSE_BIN): $(GOOSE_SRC)
	$(ODIN) build $(GOOSE) -out:$(GOOSE_BIN) -o:aggressive -microarch:native -no-bounds-check

# Baked glue: shader blobs are #load-ed into the binary at compile time.
shaders: $(GOOSE_BIN)
	$(GOOSE_BIN) --manifest goose.json --slang $(SLANG)

# Benchmarking variant: asserts and bounds checks compiled out.
perf: shaders $(APP_DEPS)
	$(ODIN) build $(SRC) -out:$(BIN) $(NOASSERT_FLAGS)


run: shaders-hot $(APP_DEPS)
	$(ODIN) run $(SRC) $(HOT_FLAGS) -- $(ARGS)

run-optimized: shaders-hot $(APP_DEPS)
	$(ODIN) run $(SRC) $(RELEASE_FLAGS) $(HOT_FLAGS) -- $(ARGS)

debug: shaders-hot $(APP_DEPS)
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(DEBUG_FLAGS) $(HOT_FLAGS)

debug-optimized: shaders-hot $(APP_DEPS)
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(RELEASE_FLAGS) $(HOT_FLAGS) -debug

# C++/Qt port (cpp_port). Prereqs: brew install qt sdl3 qscintilla2 cmake.
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

clean:
	rm -f $(BIN) $(BIN_DEBUG)

# Self-contained macOS bundle + zip under builds/apple (see
# tools/package_macos.sh). `make bundle-apple BUNDLE_VERSION=0.2.0`;
# `tools/package_macos.sh --render-icon` also re-renders the icon.
bundle-apple:
	tools/package_macos.sh $(BUNDLE_VERSION)
