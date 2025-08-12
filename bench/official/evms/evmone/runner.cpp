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
    
    // First, try deploying as initcode via CREATE to obtain runtime code
    evmc::MockedHost deploy_host;
    evmc_message create_msg{};
    create_msg.kind = EVMC_CREATE;
    create_msg.sender = CALLER_ADDRESS;
    create_msg.gas = GAS;
    auto create_result = evmc_execute(vm, &deploy_host.get_interface(),
                                      (evmc_host_context*)&deploy_host,
                                      EVMC_CANCUN, &create_msg,
                                      contract_code.data(), contract_code.size());
    evmc::bytes exec_code;
    if (create_result.status_code == EVMC_SUCCESS && create_result.output_size > 0 && create_result.output_data != nullptr) {
        exec_code.assign(create_result.output_data, create_result.output_data + create_result.output_size);
    } else {
        // Fallback: treat input as runtime code
        exec_code = contract_code;
    }
    if (create_result.release) create_result.release(&create_result);
    
    // Prepare call message
    evmc_message call_msg{};
    call_msg.kind = EVMC_CALL;
    call_msg.gas = GAS;
    call_msg.input_data = calldata_bytes.data();
    call_msg.input_size = calldata_bytes.size();
    call_msg.recipient = CONTRACT_ADDRESS;
    call_msg.sender = CALLER_ADDRESS;
    
    // Precompute selector for basic output validation
    uint32_t selector = 0;
    if (calldata_bytes.size() >= 4) {
        selector = (uint32_t(calldata_bytes[0]) << 24) |
                   (uint32_t(calldata_bytes[1]) << 16) |
                   (uint32_t(calldata_bytes[2]) << 8)  |
                   (uint32_t(calldata_bytes[3]) << 0);
    }

    // Run benchmark
    for (int i = 0; i < num_runs; i++) {
        // Create fresh host for each run
        evmc::MockedHost run_host;
        // Set reasonable tx context: gas price = 1, base fee = 7
        evmc::uint256be gas_price{};
        gas_price.bytes[31] = 1; // 1
        run_host.tx_context.tx_gas_price = gas_price;

        evmc::uint256be base_fee{};
        base_fee.bytes[31] = 7; // 7
        run_host.tx_context.block_base_fee = base_fee;
        auto call_result = evmc_execute(vm, &run_host.get_interface(),
                                       (evmc_host_context*)&run_host,
                                       EVMC_CANCUN, &call_msg,
                                       exec_code.data(), exec_code.size());
        
        check_status(call_result);
        // Gas consumption sanity
        const int64_t gas_left = call_result.gas_left;
        if (gas_left >= GAS) {
            if (call_result.release) call_result.release(&call_result);
            std::cerr << "Sanity failed: no gas consumed" << std::endl;
            return 1;
        }
        // Output validation similar to other runners
        if (selector == 0xa9059cbbu || selector == 0x095ea7b3u || selector == 0x40c10f19u) {
            if (call_result.output_size < 32 || call_result.output_data[call_result.output_size - 1] != 1) {
                if (call_result.release) call_result.release(&call_result);
                std::cerr << "Unexpected boolean return (expected 32-byte true)" << std::endl;
                return 1;
            }
        } else if (selector == 0x30627b7cu) {
            if (call_result.output_size != 0) {
                if (call_result.release) call_result.release(&call_result);
                std::cerr << "Unexpected output for Benchmark()" << std::endl;
                return 1;
            }
        }
        
        // Clean up call result
        if (call_result.release) call_result.release(&call_result);
        // no in-run timers
    }
    
    evmc_destroy(vm);
    return 0;
}