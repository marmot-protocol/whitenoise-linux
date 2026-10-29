cmake_minimum_required(VERSION 3.16)
project(wn_translation LANGUAGES C CXX)
get_filename_component(WN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_CUDA OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
# A static baseline backend must run on the package's CPU, not just the build
# machine. Do not accidentally make AVX2/FMA a hidden runtime requirement.
foreach(feature SSE42 BMI2 AVX AVX2 AVX512 AVX_VNNI AVX512_VBMI AVX512_VNNI AVX512_BF16 FMA F16C AMX_TILE AMX_INT8 AMX_BF16)
  set(GGML_${feature} OFF CACHE BOOL "" FORCE)
endforeach()
add_subdirectory("${WN_ROOT}/vendor/llama.cpp" llama EXCLUDE_FROM_ALL)
set(FT "${WN_ROOT}/vendor/fasttext/src")
add_library(wn_fasttext STATIC
  "${FT}/args.cc" "${FT}/autotune.cc" "${FT}/densematrix.cc"
  "${FT}/dictionary.cc" "${FT}/fasttext.cc" "${FT}/loss.cc"
  "${FT}/matrix.cc" "${FT}/meter.cc" "${FT}/model.cc"
  "${FT}/productquantizer.cc" "${FT}/quantmatrix.cc"
  "${FT}/utils.cc" "${FT}/vector.cc")
target_include_directories(wn_fasttext PUBLIC "${FT}")
find_package(Threads REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(TRANSLATION_IO REQUIRED IMPORTED_TARGET libcurl glib-2.0 libcrypto)
add_executable(wn-translate "${WN_ROOT}/app/translate.cpp" "${WN_ROOT}/app/helper_ipc.c")
target_link_libraries(wn-translate PRIVATE llama wn_fasttext PkgConfig::TRANSLATION_IO Threads::Threads)
# Inference/detection are static, so no third-party runtime .so can go missing
# from install-tree. curl/glib/crypto use the app's existing system/bundle deps.
set_target_properties(wn-translate PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
