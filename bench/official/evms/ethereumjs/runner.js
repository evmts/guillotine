#!/usr/bin/env bun

import { EVM } from '@ethereumjs/evm';
import { DefaultStateManager } from '@ethereumjs/statemanager';
import { Address, Account } from '@ethereumjs/util';
import { Chain, Common, Hardfork } from '@ethereumjs/common';
import { readFileSync } from 'fs';

const CALLER_ADDRESS = Address.fromString('0x1000000000000000000000000000000000000001');

async function main() {
    // Parse command line arguments
    const args = process.argv.slice(2);
    let contractCodePath = '';
    let calldataHex = '';
    let numRuns = 1;

    for (let i = 0; i < args.length; i++) {
        switch (args[i]) {
            case '--contract-code-path':
                contractCodePath = args[++i];
                break;
            case '--calldata':
                calldataHex = args[++i];
                break;
            case '--num-runs':
            case '-n':
                numRuns = parseInt(args[++i]);
                break;
            case '--help':
            case '-h':
                console.log('EthereumJS EVM runner interface\n');
                console.log('Usage: runner [OPTIONS]\n');
                console.log('Options:');
                console.log('  --contract-code-path <PATH>  Path to the hex contract code to deploy and run');
                console.log('  --calldata <HEX>            Hex of calldata to use when calling the contract');
                console.log('  -n, --num-runs <N>          Number of times to run the benchmark [default: 1]');
                console.log('  -h, --help                  Print help information');
                process.exit(0);
        }
    }

    // Read contract code
    const contractCodeHex = readFileSync(contractCodePath, 'utf8').trim();
    const contractCode = Buffer.from(contractCodeHex.replace('0x', ''), 'hex');
    
    // Prepare calldata
    const calldata = Buffer.from(calldataHex.replace('0x', ''), 'hex');

    // Create common instance for latest hardfork
    const common = new Common({ chain: Chain.Mainnet, hardfork: Hardfork.Shanghai });
    
    // Create state manager
    const stateManager = new DefaultStateManager();
    
    // Create EVM instance
    const evm = new EVM({
        common,
        stateManager
    });

    // Set up caller account with large balance
    const callerAccount = Account.fromAccountData({
        balance: BigInt('0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'),
        nonce: BigInt(0)
    });
    await stateManager.putAccount(CALLER_ADDRESS, callerAccount);
    
    // Create constructor that deploys the runtime code
    // Constructor format: init_code + runtime_code
    // init_code: PUSH runtime_size, PUSH (init_code_length), CODECOPY, PUSH runtime_size, PUSH 0, RETURN
    
    const runtimeSize = contractCode.length;
    const constructorCode = [];
    
    // PUSH runtime_size (for CODECOPY size)
    if (runtimeSize <= 0xFF) {
        constructorCode.push(0x60); // PUSH1
        constructorCode.push(runtimeSize);
    } else if (runtimeSize <= 0xFFFF) {
        constructorCode.push(0x61); // PUSH2
        constructorCode.push((runtimeSize >> 8) & 0xFF);
        constructorCode.push(runtimeSize & 0xFF);
    } else {
        throw new Error('Runtime code too large');
    }
    
    // Calculate where runtime code will be (after complete constructor)
    let constructorSize = constructorCode.length + 10; // +10 for remaining bytes
    if (runtimeSize > 0xFF) constructorSize += 2; // Extra bytes for PUSH2
    
    // PUSH offset (where runtime code starts)
    constructorCode.push(0x60); // PUSH1
    constructorCode.push(constructorSize);
    
    // PUSH1 0 (destination in memory)
    constructorCode.push(0x60); // PUSH1
    constructorCode.push(0x00); // 0
    
    // CODECOPY (copy runtime code to memory)
    constructorCode.push(0x39); // CODECOPY
    
    // PUSH runtime_size (for RETURN size)
    if (runtimeSize <= 0xFF) {
        constructorCode.push(0x60); // PUSH1
        constructorCode.push(runtimeSize);
    } else {
        constructorCode.push(0x61); // PUSH2
        constructorCode.push((runtimeSize >> 8) & 0xFF);
        constructorCode.push(runtimeSize & 0xFF);
    }
    
    // PUSH1 0 (offset in memory)
    constructorCode.push(0x60); // PUSH1
    constructorCode.push(0x00); // 0
    
    // RETURN
    constructorCode.push(0xf3); // RETURN
    
    // Create deployment bytecode: constructor + runtime code
    const deploymentCode = Buffer.concat([
        Buffer.from(constructorCode),
        contractCode
    ]);
    
    // Deploy contract with constructor code
    const deployResult = await evm.runCall({
        caller: CALLER_ADDRESS,
        data: deploymentCode,
        gasLimit: BigInt(10_000_000),
        value: BigInt(0)
    });
    
    if (deployResult.execResult.exceptionError) {
        throw new Error(`Contract deployment failed: ${deployResult.execResult.exceptionError}`);
    }
    
    if (!deployResult.createdAddress) {
        throw new Error('Contract deployment failed - no address returned');
    }
    
    const contractAddress = deployResult.createdAddress;
    
    // Store the deployed code (should be the runtime code returned by constructor)
    if (deployResult.execResult.returnValue && deployResult.execResult.returnValue.length > 0) {
        await stateManager.putContractCode(contractAddress, deployResult.execResult.returnValue);
        
        // Verify the deployed code matches our original runtime code
        if (deployResult.execResult.returnValue.length !== runtimeSize) {
            console.error(`Warning: Deployed code size mismatch: expected ${runtimeSize}, got ${deployResult.execResult.returnValue.length}`);
        }
        
    } else {
        throw new Error('Contract deployment failed: no runtime code returned');
    }

    // Run the benchmark num_runs times
    for (let i = 0; i < numRuns; i++) {
        const startTime = process.hrtime.bigint();
        
        // Execute the contract call
        const result = await evm.runCall({
            caller: CALLER_ADDRESS,
            to: contractAddress,
            data: calldata,
            gasLimit: BigInt(1_000_000_000),
            value: BigInt(0)
        });
        
        // Check for errors
        if (result.execResult.exceptionError) {
            throw new Error(`Call failed: ${result.execResult.exceptionError.error || result.execResult.exceptionError}`);
        }
        
        const endTime = process.hrtime.bigint();
        const durationNs = endTime - startTime;
        const durationMs = Number(durationNs) / 1_000_000;
        
        // Output timing (rounded to nearest ms, minimum 1)
        console.log(Math.max(1, Math.round(durationMs)));
    }
}

main().catch(error => {
    console.error('Error:', error);
    process.exit(1);
});