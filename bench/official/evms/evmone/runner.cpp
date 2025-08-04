#include <evmc/evmc.h>
#include <evmc/mocked_host.hpp>
#include <evmone/evmone.h>

#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <chrono>
#include <cstring>
#include <iomanip>

using namespace evmc::literals;

constexpr int64_t GAS = 1000000000;
const auto ZERO_ADDRESS = 0x0000000000000000000000000000000000000000_address;
const auto CONTRACT_ADDRESS = 0x2000000000000000000000000000000000000002_address;
const auto CALLER_ADDRESS = 0x1000000000000000000000000000000000000001_address;

// Convert hex string to bytes
evmc::bytes hex_to_bytes(const std::string& hex) {
    std::string clean_hex = hex;
    if (clean_hex.substr(0, 2) == "0x") {
        clean_hex = clean_hex.substr(2);
    }
    
    evmc::bytes bytes;
    evmc::from_hex(clean_hex.begin(), clean_hex.end(), std::back_inserter(bytes));
    return bytes;
}

void check_status(evmc_result result) {
    if (result.status_code != EVMC_SUCCESS) {
        std::cerr << "Execution failed with status: " << result.status_code << std::endl;
        exit(1);
    }
}

int main(int argc, char* argv[]) {
    std::string contract_code_path;
    std::string calldata_hex;
    int num_runs = 1;
    
    // Parse arguments
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--contract-code-path" && i + 1 < argc) {
            contract_code_path = argv[++i];
        } else if (arg == "--calldata" && i + 1 < argc) {
            calldata_hex = argv[++i];
        } else if ((arg == "--num-runs" || arg == "-n") && i + 1 < argc) {
            num_runs = std::stoi(argv[++i]);
        } else if (arg == "--help" || arg == "-h") {
            std::cout << "evmone runner interface\n\n";
            std::cout << "Usage: runner [OPTIONS]\n\n";
            std::cout << "Options:\n";
            std::cout << "  --contract-code-path <PATH>  Path to the hex contract code to deploy and run\n";
            std::cout << "  --calldata <HEX>            Hex of calldata to use when calling the contract\n";
            std::cout << "  -n, --num-runs <N>          Number of times to run the benchmark [default: 1]\n";
            std::cout << "  -h, --help                  Print help information\n";
            return 0;
        }
    }
    
    // Read contract code
    std::ifstream file(contract_code_path);
    if (!file) {
        std::cerr << "Failed to open contract code file: " << contract_code_path << std::endl;
        return 1;
    }
    
    std::string contract_code_hex;
    std::getline(file, contract_code_hex);
    auto contract_code = hex_to_bytes(contract_code_hex);
    
    // Prepare calldata
    auto calldata_bytes = hex_to_bytes(calldata_hex);
    
    // Create evmone VM
    const auto vm = evmc_create_evmone();
    if (!vm) {
        std::cerr << "Failed to create evmone VM" << std::endl;
        return 1;
    }
    
    // Create host for deployment
    evmc::MockedHost host;
    
    // Deploy contract using bytecode directly as init code (like Guillotine does)
    
    
    
    
    // Deploy contract using CREATE
    evmc_message create_msg{};
    create_msg.kind = EVMC_CREATE;
    create_msg.recipient = CONTRACT_ADDRESS;
    create_msg.gas = GAS;
    
    auto create_result = evmc_execute(vm, &host.get_interface(), 
                                     (evmc_host_context*)&host,
                                     EVMC_SHANGHAI, &create_msg, 
                                     contract_code.data(), contract_code.size());
    
    check_status(create_result);
    
    // Extract the deployed code from the CREATE result
    const auto exec_code = evmc::bytes(create_result.output_data, create_result.output_size);
    
    if (exec_code.empty()) {
        std::cerr << "Contract deployment failed: no runtime code returned" << std::endl;
        return 1;
    }
    
    // Clean up create result
    if (create_result.release) create_result.release(&create_result);
    
    // Prepare call message
    evmc_message call_msg{};
    call_msg.kind = EVMC_CALL;
    call_msg.gas = GAS;
    call_msg.input_data = calldata_bytes.data();
    call_msg.input_size = calldata_bytes.size();
    call_msg.recipient = CONTRACT_ADDRESS;
    call_msg.sender = CALLER_ADDRESS;
    
    // Run benchmark
    for (int i = 0; i < num_runs; i++) {
        // Create fresh host for each run
        evmc::MockedHost run_host;
        
        auto start = std::chrono::high_resolution_clock::now();
        
        auto call_result = evmc_execute(vm, &run_host.get_interface(), 
                                       (evmc_host_context*)&run_host,
                                       EVMC_SHANGHAI, &call_msg, 
                                       exec_code.data(), exec_code.size());
        
        auto end = std::chrono::high_resolution_clock::now();
        
        check_status(call_result);
        
        // Clean up call result
        if (call_result.release) call_result.release(&call_result);
        
        // Calculate duration
        auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
        double duration_ms = duration / 1000.0;
        
    }
    
    evmc_destroy(vm);
    return 0;
}