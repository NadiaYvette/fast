cmake_minimum_required(VERSION 3.10)
project(fast C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Compiler flags
add_compile_options(-Wall -Wextra -Wpedantic -O3 -fPIC)

# Detect SSE2 support (SSE2 is baseline on x86-64)
include(CheckCCompilerFlag)
check_c_compiler_flag("-msse2" HAS_SSE2)
if(HAS_SSE2)
    add_compile_options(-msse2)
endif()

# Library sources
set(FAST_SOURCES
    src/fast.c
    src/fast_build.c
    src/fast_search.c
)

# Shared library
add_library(fast SHARED ${FAST_SOURCES})
target_include_directories(fast PUBLIC include PRIVATE src)
set_target_properties(fast PROPERTIES
    VERSION 1.0.0
    SOVERSION 1
    PUBLIC_HEADER include/fast.h
)

# Static library
add_library(fast_static STATIC ${FAST_SOURCES})
target_include_directories(fast_static PUBLIC include PRIVATE src)
set_target_properties(fast_static PROPERTIES OUTPUT_NAME fast)

# Test executable
add_executable(fast_test test/test_fast.c)
target_link_libraries(fast_test fast_static)
target_include_directories(fast_test PRIVATE include)

# Benchmark executable
add_executable(fast_bench bench/bench.c)
target_link_libraries(fast_bench fast_static)
target_include_directories(fast_bench PRIVATE include)

# Perf comparison benchmark
add_executable(fast_bench_perf bench/bench_perf.c)
target_link_libraries(fast_bench_perf fast_static)
target_include_directories(fast_bench_perf PRIVATE include)

# Install rules
include(GNUInstallDirs)
install(TARGETS fast fast_static
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    PUBLIC_HEADER DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)
