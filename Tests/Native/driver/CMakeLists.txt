# ドライバのゼロタイムスタンプ（Sources/Extension/ETZeroTimeStamp.c）。
# Tests/Native の CMakeLists.txt から add_subdirectory で読まれても、
# これだけを cmake -S Tests/Native/driver で建てても動く。
# サニタイザは CMAKE_C_FLAGS で渡す（Tests/Native のプリセットと同じ入れ方）。
cmake_minimum_required(VERSION 3.24)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  project(effectdeck_driver_tests LANGUAGES C)
  enable_testing()
endif()

set(ET_DRIVER_EXT "${CMAKE_CURRENT_SOURCE_DIR}/../../../Sources/Extension")
# 親（Tests/Native）から読まれたときは親の値に従う。単独で建てるときは警告で止める。
option(ET_NATIVE_WERROR "Treat warnings in the test targets as errors" ON)

add_executable(driver_zero_timestamp zero_timestamp.c "${ET_DRIVER_EXT}/ETZeroTimeStamp.c")
set_property(TARGET driver_zero_timestamp PROPERTY C_STANDARD 11)
set_property(TARGET driver_zero_timestamp PROPERTY C_STANDARD_REQUIRED ON)
# 検査台（et_check.h）は link と共有する。
target_include_directories(driver_zero_timestamp PRIVATE
  "${ET_DRIVER_EXT}" "${CMAKE_CURRENT_SOURCE_DIR}/../link")
if(MSVC)
  target_compile_options(driver_zero_timestamp PRIVATE /utf-8 /W3)
  if(ET_NATIVE_WERROR)
    target_compile_options(driver_zero_timestamp PRIVATE /WX)
  endif()
else()
  target_compile_options(driver_zero_timestamp PRIVATE -Wall -Wextra)
  if(ET_NATIVE_WERROR)
    target_compile_options(driver_zero_timestamp PRIVATE -Werror)
  endif()
  target_link_libraries(driver_zero_timestamp PRIVATE m)
endif()

# 検査ごとに ctest へ登録する。名前はソースの ET_ENTRY(...) の行から拾う。
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS zero_timestamp.c)
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/zero_timestamp.c" entries REGEX "ET_ENTRY\\([a-z0-9_]+\\)")
foreach(line IN LISTS entries)
  string(REGEX REPLACE ".*ET_ENTRY\\(([a-z0-9_]+)\\).*" "\\1" name "${line}")
  add_test(NAME driver_zero_timestamp.${name} COMMAND driver_zero_timestamp ${name})
  set_tests_properties(driver_zero_timestamp.${name} PROPERTIES LABELS "native;driver" TIMEOUT 300)
endforeach()
