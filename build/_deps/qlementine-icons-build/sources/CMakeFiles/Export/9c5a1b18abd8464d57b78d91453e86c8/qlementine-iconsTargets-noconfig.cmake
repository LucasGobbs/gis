#----------------------------------------------------------------
# Generated CMake target import file.
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "qlementine-icons::qlementine-icons" for configuration ""
set_property(TARGET qlementine-icons::qlementine-icons APPEND PROPERTY IMPORTED_CONFIGURATIONS NOCONFIG)
set_target_properties(qlementine-icons::qlementine-icons PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_NOCONFIG "CXX"
  IMPORTED_LOCATION_NOCONFIG "${_IMPORT_PREFIX}/lib/libqlementine-icons.a"
  )

list(APPEND _cmake_import_check_targets qlementine-icons::qlementine-icons )
list(APPEND _cmake_import_check_files_for_qlementine-icons::qlementine-icons "${_IMPORT_PREFIX}/lib/libqlementine-icons.a" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
