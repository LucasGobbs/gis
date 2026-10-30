# CMake generated Testfile for 
# Source directory: /Users/gobbi/Desktop/code/projects/gis
# Build directory: /Users/gobbi/Desktop/code/projects/gis/build
# 
# This file includes the relevant testing commands required for 
# testing this directory and lists subdirectories to be tested as well.
add_test("gis_tests" "/Users/gobbi/Desktop/code/projects/gis/build/gis_tests")
set_tests_properties("gis_tests" PROPERTIES  WORKING_DIRECTORY "/Users/gobbi/Desktop/code/projects/gis" _BACKTRACE_TRIPLES "/Users/gobbi/Desktop/code/projects/gis/CMakeLists.txt;91;add_test;/Users/gobbi/Desktop/code/projects/gis/CMakeLists.txt;0;")
subdirs("_deps/qlementine-icons-build")
subdirs("_deps/qlementine-build")
subdirs("_deps/nodeeditor-build")
subdirs("_deps/catch2-build")
