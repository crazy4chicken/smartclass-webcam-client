find_package(GTest QUIET)
if(NOT GTest_FOUND)
  include(FetchContent)
  FetchContent_Declare(
    googletest
    URL https://github.com/google/googletest/archive/refs/tags/v1.14.0.tar.gz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  )
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(googletest)
endif()

set(TEST_BINARY "camera_desktop_plugin_test")

add_executable(${TEST_BINARY}
  camera_desktop_plugin_test.cc
)

target_compile_features(${TEST_BINARY} PRIVATE cxx_std_14)

target_include_directories(${TEST_BINARY} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/.."
)

target_link_libraries(${TEST_BINARY} PRIVATE
  camera_desktop_plugin
  flutter
  GTest::gtest_main
  GTest::gmock
)

include(GoogleTest)
gtest_discover_tests(${TEST_BINARY})
