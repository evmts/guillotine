# Injected into evmone CMake build via -DCMAKE_PROJECT_evmone_INCLUDE=...
add_executable(compare-evmone "${CMAKE_CURRENT_LIST_DIR}/main.cpp")
target_link_libraries(compare-evmone PRIVATE
    evmone
    evmone::state
    evmc::evmc_cpp
    intx::intx
    nlohmann_json::nlohmann_json
)
target_compile_options(compare-evmone PRIVATE -O3 -mcpu=native)
set_target_properties(compare-evmone PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
