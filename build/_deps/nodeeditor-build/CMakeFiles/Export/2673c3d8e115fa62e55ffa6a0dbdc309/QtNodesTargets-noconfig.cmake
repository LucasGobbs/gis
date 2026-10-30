#----------------------------------------------------------------
# Generated CMake target import file.
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "QtNodes::QtNodes" for configuration ""
set_property(TARGET QtNodes::QtNodes APPEND PROPERTY IMPORTED_CONFIGURATIONS NOCONFIG)
set_target_properties(QtNodes::QtNodes PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_NOCONFIG "CXX"
  IMPORTED_LOCATION_NOCONFIG "${_IMPORT_PREFIX}/lib/libQtNodes.a"
  )

list(APPEND _cmake_import_check_targets QtNodes::QtNodes )
list(APPEND _cmake_import_check_files_for_QtNodes::QtNodes "${_IMPORT_PREFIX}/lib/libQtNodes.a" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
