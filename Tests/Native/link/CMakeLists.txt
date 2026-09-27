# LocalLink の線の形式と受け手の溜まりの方針（Sources/Shared/ETLinkCodec.c）。
# Tests/Native の CMakeLists.txt から add_subdirectory で読まれても、
# これだけを cmake -S Tests/Native/link で建てても動く。
# サニタイザは CMAKE_C_FLAGS で渡す（Tests/Native のプリセットと同じ入れ方）。
cmake_minimum_required(VERSION 3.24)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  project(effectdeck_link_tests LANGUAGES C)
  enable_testing()
endif()

set(ET_LINK_SHARED "${CMAKE_CURRENT_SOURCE_DIR}/../../../Sources/Shared")
# 親（Tests/Native）から読まれたときは親の値に従う。単独で建てるときは警告で止める。
option(ET_NATIVE_WERROR "Treat warnings in the test targets as errors" ON)

# 検査ごとに ctest へ登録する。名前はソースの ET_ENTRY(...) の行から拾う。
function(et_link_test target source)
  add_executable(${target} ${source} ${ARGN})
  set_property(TARGET ${target} PROPERTY C_STANDARD 11)
  set_property(TARGET ${target} PROPERTY C_STANDARD_REQUIRED ON)
  target_include_directories(${target} PRIVATE "${ET_LINK_SHARED}" "${CMAKE_CURRENT_SOURCE_DIR}")
  if(MSVC)
    target_compile_options(${target} PRIVATE /experimental:c11atomics /utf-8 /W3)
    if(ET_NATIVE_WERROR)
      target_compile_options(${target} PRIVATE /WX)
    endif()
  else()
    target_compile_options(${target} PRIVATE -Wall -Wextra)
    if(ET_NATIVE_WERROR)
      target_compile_options(${target} PRIVATE -Werror)
    endif()
    target_link_libraries(${target} PRIVATE m)
  endif()
  # 検査を足したら ctest の一覧も変わるので、ソースが変われば構成し直す。
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${source}")
  file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/${source}" entries REGEX "ET_ENTRY\\([a-z0-9_]+\\)")
  foreach(line IN LISTS entries)
    string(REGEX REPLACE ".*ET_ENTRY\\(([a-z0-9_]+)\\).*" "\\1" name "${line}")
    add_test(NAME ${target}.${name} COMMAND ${target} ${name})
    # Tests/Native の他の試験と同じラベル（tsan のプリセットには入らない。スレッドを使わないので）。
    set_tests_properties(${target}.${name} PROPERTIES LABELS "native;link" TIMEOUT 300)
  endforeach()
endfunction()

et_link_test(link_codec link_codec.c "${ET_LINK_SHARED}/ETLinkCodec.c")
et_link_test(link_jitter link_jitter.c "${ET_LINK_SHARED}/ETLinkCodec.c")
