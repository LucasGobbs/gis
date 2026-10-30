# Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
# file LICENSE.rst or https://cmake.org/licensing for details.

cmake_minimum_required(VERSION ${CMAKE_VERSION}) # this file comes with cmake

# If CMAKE_DISABLE_SOURCE_CHANGES is set to true and the source directory is an
# existing directory in our source tree, calling file(MAKE_DIRECTORY) on it
# would cause a fatal error, even though it would be a no-op.
if(NOT EXISTS "/Users/gobbi/Desktop/code/projects/gis/build/_deps/qlementine-src")
  file(MAKE_DIRECTORY "/Users/gobbi/Desktop/code/projects/gis/build/_deps/qlementine-src")
endif()
file(MAKE_DIRECTORY
  "/Users/gobbi/Desktop/code/projects/gis/build/_deps/qlementine-build"
  "/Users/gobbi/Desktop/code/projects/gis/build/_deps/qlementine-subbuild/qlementine-populate-prefix"
  "/Users/gobbi/Desktop/code/projects/gis/build/_deps/qlementine-subbuild/qlementine-populate-prefix/tmp"
  "/Users/gobbi/Desktop/code/projects/gis/build/_deps/qlementine-subbuild/qlementine-populate-prefix/src/qlementine-populate-stamp"
  "/Users/gobbi/Desktop/code/projects/gis/build/_deps/qlementine-subbuild/qlementine-populate-prefix/src"
  "/Users/gobbi/Desktop/code/projects/gis/build/_deps/qlementine-subbuild/qlementine-populate-prefix/src/qlementine-populate-stamp"
)

set(configSubDirs )
foreach(subDir IN LISTS configSubDirs)
    file(MAKE_DIRECTORY "/Users/gobbi/Desktop/code/projects/gis/build/_deps/qlementine-subbuild/qlementine-populate-prefix/src/qlementine-populate-stamp/${subDir}")
endforeach()
if(cfgdir)
  file(MAKE_DIRECTORY "/Users/gobbi/Desktop/code/projects/gis/build/_deps/qlementine-subbuild/qlementine-populate-prefix/src/qlementine-populate-stamp${cfgdir}") # cfgdir has leading slash
endif()
