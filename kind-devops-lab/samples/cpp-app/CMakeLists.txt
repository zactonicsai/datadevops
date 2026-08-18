cmake_minimum_required(VERSION 3.22)
project(cpp_app VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)   # helps clang-tidy

add_library(calc src/calc.cpp)
target_include_directories(calc PUBLIC include)
target_compile_options(calc PRIVATE -Wall -Wextra)

add_executable(cpp_app src/main.cpp)
target_link_libraries(cpp_app PRIVATE calc)
target_compile_options(cpp_app PRIVATE -Wall -Wextra)

# ---- tests -----------------------------------------------------------------
enable_testing()
find_package(GTest REQUIRED)

add_executable(calc_test tests/calc_test.cpp)
target_link_libraries(calc_test PRIVATE calc GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(calc_test)

install(TARGETS cpp_app RUNTIME DESTINATION bin)
