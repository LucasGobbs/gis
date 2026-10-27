cmake_minimum_required(VERSION 3.22)
project(gis LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Dev builds: every warning on, warnings ARE errors — but ONLY for our
# targets (added per-target below), not the FetchContent deps.
find_package(Qt6 6.8 REQUIRED COMPONENTS Widgets Svg)
find_package(SDL3 REQUIRED)
find_package(Threads REQUIRED)
# QScintilla prefix: -DQSCINTILLA_ROOT=<prefix> off Homebrew (Linux/Windows/vcpkg).
set(QSCINTILLA_ROOT "" CACHE PATH "QScintilla install prefix")
find_path(QSCINTILLA_INCLUDE_DIR Qsci/qsciscintilla.h REQUIRED
    HINTS ${QSCINTILLA_ROOT} /opt/homebrew/opt/qscintilla2 PATH_SUFFIXES include)
find_library(QSCINTILLA_LIBRARY NAMES qscintilla2_qt6 qscintilla2 REQUIRED
    HINTS ${QSCINTILLA_ROOT} /opt/homebrew/opt/qscintilla2 PATH_SUFFIXES lib)
include(FetchContent)
FetchContent_Declare(qlementine-icons GIT_REPOSITORY https://github.com/oclero/qlementine-icons.git GIT_TAG v1.16.1)
FetchContent_MakeAvailable(qlementine-icons)
FetchContent_Declare(qlementine GIT_REPOSITORY https://github.com/oclero/qlementine.git GIT_TAG v1.5.2
  # Local patch: polish(QMenu*) caches a PolishedWidgetRegistry::Entry& across
  # setWindowFlag() reentrancy; unpolish erases the QMap entry mid-polish and
  # polishMenu push_backs into freed memory (heap-use-after-free when any QMenu
  # opens). Fix: re-resolve the entry at the use site (upstream bug, v1.5.2).
  PATCH_COMMAND git checkout -- . && git apply ${CMAKE_CURRENT_SOURCE_DIR}/qlementine-menu-uaf.patch
)
FetchContent_MakeAvailable(qlementine)
set(NODE_EDITOR_STATIC ON CACHE BOOL "" FORCE)
set(NODE_EDITOR_SHARED OFF CACHE BOOL "" FORCE)
FetchContent_Declare(nodeeditor GIT_REPOSITORY https://github.com/paceholder/nodeeditor.git GIT_TAG 3.0.9
  # Local patch: ConnectionGraphicsObject statically downcasts event->widget()
  # to QGraphicsView in mouse move/release; with a grabbed draft connection the
  # event can arrive through a foreign top-level widget (UBSan vptr report).
  # Fix: qobject_cast + graceful drop when the view is unknown.
  PATCH_COMMAND git checkout -- . && git apply ${CMAKE_CURRENT_SOURCE_DIR}/nodeeditor-view-cast.patch
)
FetchContent_MakeAvailable(nodeeditor)

qt_standard_project_setup()  # AUTOMOC ON global (Shell/Editor/Node_View have Q_OBJECT)

file(GLOB_RECURSE GIS_SRC CONFIGURE_DEPENDS
     src/gfx/*.cpp src/ui/*.cpp src/export/*.cpp)
qt_add_library(gis STATIC ${GIS_SRC})
# All warnings as errors for OUR code only (FetchContent deps excluded);
# gis_host inherits via the PUBLIC gis link.
add_library(gis_warnings INTERFACE)
target_compile_options(gis_warnings INTERFACE
    $<$<CXX_COMPILER_ID:MSVC>:/W4>
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall;-Wextra;-Wpedantic;-Wshadow;-Wnon-virtual-dtor;-Wcast-align;-Woverloaded-virtual;-Werror>)
# -Wconversion/-Wsign-conversion omitted: they fire inside the
# QtNodes/Qlementine headers AUTOMOC pulls in, even as system
# includes (explicit -W flags bypass system-header suppression).
set(GIS_FONT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendor/fonts)
target_link_libraries(gis PRIVATE gis_warnings)
set_source_files_properties(${GIS_FONT_DIR}/JetBrainsMono-Regular.ttf
    PROPERTIES QT_RESOURCE_ALIAS "JetBrainsMono-Regular.ttf")
set_source_files_properties(${GIS_FONT_DIR}/Sergamon-Regular.ttf
    PROPERTIES QT_RESOURCE_ALIAS "Sergamon-Regular.ttf")
qt_add_resources(gis "fonts_qrc" PREFIX "/fonts"
    FILES ${GIS_FONT_DIR}/JetBrainsMono-Regular.ttf ${GIS_FONT_DIR}/Sergamon-Regular.ttf)
target_include_directories(gis PUBLIC src ${QSCINTILLA_INCLUDE_DIR})
# Vendored single-file C libs (cgltf, stb_image) compiled into gis.
target_include_directories(gis PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/vendor/cgltf
                                      ${CMAKE_CURRENT_SOURCE_DIR}/vendor/stb)
target_sources(gis PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/vendor/cgltf/cgltf.c)
# Vendor C code is third-party: no -Werror cast-align there (the C++ files
# keep the full warning set via gis_warnings).
if(NOT MSVC)
set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/vendor/cgltf/cgltf.c
    PROPERTIES COMPILE_OPTIONS "-Wno-cast-align;-Wno-sign-conversion;-Wno-conversion")
endif()
# md4c: headers via an alias dir (include/md4c_inc). The vendor dir itself
# is NOT on the include path: it carries an extensionless file named
# "version" that shadows libc++'s <version> under APFS case-insensitivity.
target_include_directories(gis PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include/md4c_inc)
target_sources(gis PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/vendor/md4c/md4c.c)
if(NOT MSVC)
set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/vendor/md4c/md4c.c
    PROPERTIES COMPILE_OPTIONS "-Wno-sign-conversion;-Wno-conversion;-Wno-cast-align")
endif()
target_link_libraries(gis PUBLIC Qt6::Widgets Qt6::Svg SDL3::SDL3 Threads::Threads qlementine-icons qlementine QtNodes
        ${QSCINTILLA_LIBRARY})

if(APPLE)
    qt_add_executable(gis_host src/host_main.mm)
    target_link_libraries(gis_host PRIVATE gis)
else()
    # Host is AppKit + Metal (MSL shaders, NSWindow embed): no Windows/Linux port yet.
    message(WARNING "gis_host skipped: src/host_main.mm is macOS-only")
endif()

option(GIS_BUILD_TESTS "Build Catch2 tests" ON)
if(GIS_BUILD_TESTS)
    include(FetchContent)
    FetchContent_Declare(catch2 GIT_REPOSITORY https://github.com/catchorg/Catch2.git GIT_TAG v3.7.1)
    FetchContent_MakeAvailable(catch2)
    add_executable(gis_tests tests/test_main.cpp tests/test_render_graph.cpp tests/test_shell.cpp tests/test_inspect.cpp tests/test_camera.cpp)
    target_link_libraries(gis_tests PRIVATE gis Catch2::Catch2)
    target_compile_definitions(gis_tests PRIVATE GIS_REPO_ROOT="${CMAKE_CURRENT_SOURCE_DIR}")
    enable_testing()
    add_test(NAME gis_tests COMMAND gis_tests WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
endif()
