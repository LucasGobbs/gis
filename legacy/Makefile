# Legacy Odin app (pre-cpp_port). Kept runnable while the C++ port proves
# parity; delete when the cutover lands (see AGENTS.md / migration plan).
# NOTE: the shared data (src/shaders, src/generated, assets, vendor) stays
# at the repo ROOT — this makefile runs odin from there with -define paths
# resolved relative to the root, so `make -C legacy run` still works.
ODIN      ?= odin
ROOT      := ..
SLANG     ?= $(ROOT)/vendor/slang/bin/slangc
GOOSE_DIR ?= ../vendor/goose
GOOSE     := $(GOOSE_DIR)/src/tools/build
GOOSE_BIN := $(GOOSE_DIR)/goose-build
GOOSE_SRC := $(wildcard $(GOOSE)/*.odin)
SRC       := $(ROOT)/legacy/src
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

.PHONY: all build shaders shaders-hot run run-optimized debug debug-optimized clean

# The integrated ImGui editor (src/imgui_editor.odin) links the
# ImGuiColorTextEdit wrapper; every app build needs it. The wrapper MUST use
# the same IMGUI_DISABLE_OBSOLETE_* defines as the premake-built imgui lib.
APP_DEPS := $(ROOT)/vendor/ImGuiColorTextEdit/libite.a $(MD4C_LIB) $(TFD_LIB)
IMGUI_DEFINES := -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS -DIMGUI_DISABLE_OBSOLETE_KEYIO
IMGUI_INC := $(ROOT)/vendor/odin-imgui/build/deps/imgui
ITE_SRC := $(ROOT)/vendor/ImGuiColorTextEdit/TextEditor.cpp $(ROOT)/vendor/ImGuiColorTextEdit/TextEditor.h $(ROOT)/vendor/ImGuiColorTextEdit/ite/ite.cpp $(ROOT)/vendor/ImGuiColorTextEdit/ite/ite.h

$(ROOT)/vendor/ImGuiColorTextEdit/libite.a: $(ITE_SRC)
	clang++ -std=c++17 -O2 $(IMGUI_DEFINES) -c $(ROOT)/vendor/ImGuiColorTextEdit/TextEditor.cpp -I$(IMGUI_INC) -I$(ROOT)/vendor/ImGuiColorTextEdit -o /tmp/TextEditor.o
	clang++ -std=c++17 -O2 $(IMGUI_DEFINES) -c $(ROOT)/vendor/ImGuiColorTextEdit/ite/ite.cpp -I$(IMGUI_INC) -I$(ROOT)/vendor/ImGuiColorTextEdit -o /tmp/ite.o
	rm -f $@
	ar rc $@ /tmp/TextEditor.o /tmp/ite.o
	ranlib $@

MD4C_LIB := $(ROOT)/vendor/md4c/libmd4c.a

$(MD4C_LIB): $(ROOT)/vendor/md4c/md4c.c $(ROOT)/vendor/md4c/md4c.h
	cc -std=c11 -O2 -c $(ROOT)/vendor/md4c/md4c.c -o /tmp/md4c_obj.o
	rm -f $@
	ar rc $@ /tmp/md4c_obj.o
	ranlib $@

TFD_LIB := $(ROOT)/vendor/tinyfiledialogs/libtfd.a

$(TFD_LIB): $(ROOT)/vendor/tinyfiledialogs/tinyfiledialogs.c $(ROOT)/vendor/tinyfiledialogs/tinyfiledialogs.h
	cc -std=c11 -O2 -c $(ROOT)/vendor/tinyfiledialogs/tinyfiledialogs.c -o /tmp/tfd_obj.o
	rm -f $@
	ar rc $@ /tmp/tfd_obj.o
	ranlib $@


all: build

# Default app build (asserts/bounds ON: an invariant violation crashes
# loudly instead of corrupting state silently).
build: shaders $(APP_DEPS)
	$(ODIN) build $(SRC) -out:$(ROOT)/$(BIN) $(RELEASE_FLAGS)

$(GOOSE_BIN): $(GOOSE_SRC)
	$(ODIN) build $(GOOSE) -out:$(GOOSE_BIN) -o:aggressive -microarch:native -no-bounds-check

# Baked glue: shader blobs are #load-ed into the binary at compile time.
shaders: $(GOOSE_BIN)
	cd $(ROOT) && $(abspath $(GOOSE_BIN)) --manifest goose.json --slang $(abspath $(SLANG))

# Benchmarking variant: asserts and bounds checks compiled out.
perf: shaders $(APP_DEPS)
	$(ODIN) build $(SRC) -out:$(ROOT)/$(BIN) $(NOASSERT_FLAGS)



shaders-hot: shaders $(APP_DEPS)

run: shaders-hot $(APP_DEPS)
	cd $(ROOT) && $(ODIN) run $(SRC) $(HOT_FLAGS) -- $(ARGS)

run-optimized: shaders-hot $(APP_DEPS)
	cd $(ROOT) && $(ODIN) run $(SRC) $(RELEASE_FLAGS) $(HOT_FLAGS) -- $(ARGS)

debug: shaders-hot $(APP_DEPS)
	$(ODIN) build $(SRC) -out:$(ROOT)/$(BIN_DEBUG) $(DEBUG_FLAGS) $(HOT_FLAGS)

debug-optimized: shaders-hot $(APP_DEPS)
	$(ODIN) build $(SRC) -out:$(ROOT)/$(BIN_DEBUG) $(RELEASE_FLAGS) $(HOT_FLAGS) -debug

clean:
	rm -f $(ROOT)/$(BIN) $(ROOT)/$(BIN_DEBUG)
