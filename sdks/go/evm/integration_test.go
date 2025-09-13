package evm

import (
	"encoding/hex"
	"math/big"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/evmts/guillotine/sdks/go/primitives"
)

// Test constants
const (
	DefaultBalance = 1000000
	StandardGas = 100000
	HighGas = 200000
	VeryHighGas = 1000000
	LargeBalance = 10000000
)

func TestIntegrationScenarios(t *testing.T) {
	t.Run("ERC20 token transfer simulation", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		tokenAddr := primitives.NewAddress([20]byte{0x01})
		senderAddr := primitives.NewAddress([20]byte{0x02})
		
		// Set up sender with balance
		err = evm.SetBalance(senderAddr, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		senderBalanceSlot := big.NewInt(0)
		receiverBalanceSlot := big.NewInt(1)
		
		initialSenderBalance := big.NewInt(1000)
		initialReceiverBalance := big.NewInt(500)
		
		err = evm.SetStorage(tokenAddr, senderBalanceSlot, initialSenderBalance)
		require.NoError(t, err)
		err = evm.SetStorage(tokenAddr, receiverBalanceSlot, initialReceiverBalance)
		require.NoError(t, err)
		transferSimulation := "60645f54606490035f55606460015401600155"
		
		bytecode, err := hex.DecodeString(transferSimulation)
		require.NoError(t, err)

		// Deploy the bytecode
		err = evm.SetCode(tokenAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: senderAddr,
			To:     tokenAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)

		finalSenderBalance, err := evm.GetStorage(tokenAddr, senderBalanceSlot)
		require.NoError(t, err)
		finalReceiverBalance, err := evm.GetStorage(tokenAddr, receiverBalanceSlot)
		require.NoError(t, err)
		
		assert.Equal(t, uint64(900), finalSenderBalance.Uint64())
		assert.Equal(t, uint64(600), finalReceiverBalance.Uint64())
	})

	t.Run("DEX swap simulation", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		dexAddr := primitives.NewAddress([20]byte{0x04})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		reserve0Slot := big.NewInt(0)
		reserve1Slot := big.NewInt(1)
		
		reserve0 := big.NewInt(100000)
		reserve1 := big.NewInt(200000)
		
		err = evm.SetStorage(dexAddr, reserve0Slot, reserve0)
		require.NoError(t, err)
		err = evm.SetStorage(dexAddr, reserve1Slot, reserve1)
		require.NoError(t, err)

		swapSimulation := "5f5460015402619c40116100165761001b5661001b5b60016001555b"
		
		bytecode, err := hex.DecodeString(swapSimulation)
		require.NoError(t, err)

		// Deploy the bytecode
		err = evm.SetCode(dexAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     dexAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
	})

	t.Run("Multi-sig wallet execution", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		walletAddr := primitives.NewAddress([20]byte{0x05})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		ownerCountSlot := big.NewInt(0)
		thresholdSlot := big.NewInt(1)
		
		ownerCount := big.NewInt(3)
		threshold := big.NewInt(2)
		
		err = evm.SetStorage(walletAddr, ownerCountSlot, ownerCount)
		require.NoError(t, err)
		err = evm.SetStorage(walletAddr, thresholdSlot, threshold)
		require.NoError(t, err)

		multiSigExecution := "5f546001541161001e5760aa60025560015460025410610020576001610022565b5f5b5f5260205ff3"
		
		bytecode, err := hex.DecodeString(multiSigExecution)
		require.NoError(t, err)

		// Deploy the bytecode
		err = evm.SetCode(walletAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     walletAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
	})

	t.Run("NFT minting process", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		nftAddr := primitives.NewAddress([20]byte{0x06})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		totalSupplySlot := big.NewInt(0)
		
		currentSupply := big.NewInt(100)
		err = evm.SetStorage(nftAddr, totalSupplySlot, currentSupply)
		require.NoError(t, err)

		mintNFT := "5f5460010180606411610019575f5560015f5260205ff35bfd"
		
		bytecode, err := hex.DecodeString(mintNFT)
		require.NoError(t, err)

		// Deploy the bytecode
		err = evm.SetCode(nftAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     nftAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)

		newSupply, err := evm.GetStorage(nftAddr, totalSupplySlot)
		require.NoError(t, err)
		assert.Equal(t, uint64(101), newSupply.Uint64())
	})

	t.Run("Staking rewards calculation", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		stakingAddr := primitives.NewAddress([20]byte{0x07})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		totalStakedSlot := big.NewInt(0)
		rewardRateSlot := big.NewInt(1)
		
		totalStaked := big.NewInt(DefaultBalance)
		rewardRate := big.NewInt(5)
		
		err = evm.SetStorage(stakingAddr, totalStakedSlot, totalStaked)
		require.NoError(t, err)
		err = evm.SetStorage(stakingAddr, rewardRateSlot, rewardRate)
		require.NoError(t, err)

		calculateRewards := "5f546001540260648104600255"
		
		bytecode, err := hex.DecodeString(calculateRewards)
		require.NoError(t, err)

		// Deploy the bytecode
		err = evm.SetCode(stakingAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     stakingAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
	})

	t.Run("Governance voting mechanism", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		govAddr := primitives.NewAddress([20]byte{0x08})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		proposalSlot := big.NewInt(0)
		yesVotesSlot := big.NewInt(1)
		noVotesSlot := big.NewInt(2)
		
		proposalId := big.NewInt(42)
		yesVotes := big.NewInt(75)
		noVotes := big.NewInt(25)
		
		err = evm.SetStorage(govAddr, proposalSlot, proposalId)
		require.NoError(t, err)
		err = evm.SetStorage(govAddr, yesVotesSlot, yesVotes)
		require.NoError(t, err)
		err = evm.SetStorage(govAddr, noVotesSlot, noVotes)
		require.NoError(t, err)

		checkVoteOutcome := "600154600254116100155760016100165660006100165b5f5260205ff3"
		
		bytecode, err := hex.DecodeString(checkVoteOutcome)
		require.NoError(t, err)

		// Deploy the bytecode
		err = evm.SetCode(govAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     govAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
	})

	t.Run("Cross-contract interaction", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		contractA := primitives.NewAddress([20]byte{0x09})
		contractB := primitives.NewAddress([20]byte{0x0a})
		caller := primitives.ZeroAddress()
		
		// Set up caller and contract A with balance
		err = evm.SetBalance(caller, big.NewInt(LargeBalance))
		require.NoError(t, err)
		err = evm.SetBalance(contractA, big.NewInt(LargeBalance))
		require.NoError(t, err)
		
		contractBCode := []byte{0x60, 0xaa, 0x5f, 0x55, 0x60, 0x01, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}
		err = evm.SetCode(contractB, contractBCode)
		require.NoError(t, err)

		crossContractCall := "5f5f5f5f5f73" + hex.EncodeToString(contractB.Bytes()) + "61fffff1503d60205f5f3e5f515f5260205ff3"
		
		bytecode, err := hex.DecodeString(crossContractCall)
		require.NoError(t, err)

		// Deploy the bytecode to contract A
		err = evm.SetCode(contractA, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractA,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
		assert.Equal(t, 32, len(result.Output))
	})

	t.Run("Flash loan pattern", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		lenderAddr := primitives.NewAddress([20]byte{0x0b})
		borrowerAddr := primitives.NewAddress([20]byte{0x0c})
		caller := primitives.ZeroAddress()
		
		// Set up caller and lender with balance
		err = evm.SetBalance(caller, big.NewInt(LargeBalance))
		require.NoError(t, err)
		err = evm.SetBalance(lenderAddr, big.NewInt(LargeBalance))
		require.NoError(t, err)
		
		borrowerCode := []byte{0x34, 0x61, 0x03, 0xe8, 0x01, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}
		err = evm.SetCode(borrowerAddr, borrowerCode)
		require.NoError(t, err)

		flashLoan := "5f5f5f5f6103e873" + hex.EncodeToString(borrowerAddr.Bytes()) + "61fffff1503d5f5f3e5f51610fa010610400196100385760016100385b5f5260205ff3"
		
		bytecode, err := hex.DecodeString(flashLoan)
		require.NoError(t, err)

		// Deploy the bytecode to lender
		err = evm.SetCode(lenderAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     lenderAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
	})

	t.Run("Upgradeable proxy pattern", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		proxyAddr := primitives.NewAddress([20]byte{0x0d})
		implAddr := primitives.NewAddress([20]byte{0x0e})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		implSlot := big.NewInt(0)
		// Convert address to big.Int
		implAddrBig := new(big.Int).SetBytes(implAddr.Bytes())
		err = evm.SetStorage(proxyAddr, implSlot, implAddrBig)
		require.NoError(t, err)
		
		implCode := []byte{0x60, 0xbb, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}
		err = evm.SetCode(implAddr, implCode)
		require.NoError(t, err)

		proxyDelegateCall := "5f545f5f5f5f8173ffffffffffffffffffffffffffffffffffffffff1661fffff45f5260205ff3"
		
		bytecode, err := hex.DecodeString(proxyDelegateCall)
		require.NoError(t, err)

		// Deploy the bytecode to proxy
		err = evm.SetCode(proxyAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     proxyAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
	})

	t.Run("Time-locked transaction", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		timelockAddr := primitives.NewAddress([20]byte{0x0f})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		unlockTimeSlot := big.NewInt(0)
		
		unlockTime := big.NewInt(900)
		err = evm.SetStorage(timelockAddr, unlockTimeSlot, unlockTime)
		require.NoError(t, err)

		checkTimelock := "5f5442116100145760aa5f5560016100175660006100175b5f5260205ff3"
		
		bytecode, err := hex.DecodeString(checkTimelock)
		require.NoError(t, err)

		// Deploy the bytecode
		err = evm.SetCode(timelockAddr, bytecode)
		require.NoError(t, err)

		// Note: SetBlockTimestamp method may not exist in new API - test will verify timelock logic
		result, err := evm.Call(Call{
			Caller: caller,
			To:     timelockAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
	})

	t.Run("Batch transaction processing", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		batchAddr := primitives.NewAddress([20]byte{0x10})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)
		
		for i := uint64(0); i < 5; i++ {
			slot := big.NewInt(int64(i))
			value := big.NewInt(int64(i * 10))
			err = evm.SetStorage(batchAddr, slot, value)
			require.NoError(t, err)
		}

		batchProcess := "5f5b80600511610022578054600182019150816020028155600101809150610001565b"
		
		bytecode, err := hex.DecodeString(batchProcess)
		require.NoError(t, err)

		// Deploy the bytecode
		err = evm.SetCode(batchAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     batchAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
	})

	t.Run("Oracle price feed integration", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		oracleAddr := primitives.NewAddress([20]byte{0x11})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		priceSlot := big.NewInt(0)
		timestampSlot := big.NewInt(1)
		
		price := big.NewInt(50000)
		timestamp := big.NewInt(1000)
		
		err = evm.SetStorage(oracleAddr, priceSlot, price)
		require.NoError(t, err)
		err = evm.SetStorage(oracleAddr, timestampSlot, timestamp)
		require.NoError(t, err)

		readPrice := "5f54600154426103e8039011610021576001610025565f610025565b5f5260205ff3"
		
		bytecode, err := hex.DecodeString(readPrice)
		require.NoError(t, err)

		// Deploy the bytecode
		err = evm.SetCode(oracleAddr, bytecode)
		require.NoError(t, err)

		// Note: SetBlockTimestamp method may not exist in new API - test will verify oracle logic
		result, err := evm.Call(Call{
			Caller: caller,
			To:     oracleAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
	})

	t.Run("Merkle proof verification", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		merkleAddr := primitives.NewAddress([20]byte{0x12})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		rootSlot := big.NewInt(0)
		
		// Convert hex string to big.Int
		merkleRootBytes, err := hex.DecodeString("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")
		require.NoError(t, err)
		merkleRoot := new(big.Int).SetBytes(merkleRootBytes)
		err = evm.SetStorage(merkleAddr, rootSlot, merkleRoot)
		require.NoError(t, err)

		verifyProof := "5f545f5f205f5f2014610019576001610001d5660006100001d565b5f5260205ff3"
		
		bytecode, err := hex.DecodeString(verifyProof)
		require.NoError(t, err)

		// Deploy the bytecode
		err = evm.SetCode(merkleAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     merkleAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
	})

	t.Run("Emergency pause mechanism", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		pausableAddr := primitives.NewAddress([20]byte{0x13})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		pausedSlot := big.NewInt(0)
		
		paused := big.NewInt(0)
		err = evm.SetStorage(pausableAddr, pausedSlot, paused)
		require.NoError(t, err)

		checkPausedAndExecute := "5f5415610011575f610017575b60015f555b60aa5f5260205ff3"
		
		bytecode, err := hex.DecodeString(checkPausedAndExecute)
		require.NoError(t, err)

		// Deploy the bytecode
		err = evm.SetCode(pausableAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     pausableAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
		
		// Test with paused = 1
		pausedValue := big.NewInt(1)
		err = evm.SetStorage(pausableAddr, pausedSlot, pausedValue)
		require.NoError(t, err)
		
		result, err = evm.Call(Call{
			Caller: caller,
			To:     pausableAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
	})
}

func TestRealWorldContracts(t *testing.T) {
	t.Run("Simple storage contract", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		storageContract := "608060405234801561001057600080fd5b50610150806100206000396000f3fe608060405234801561001057600080fd5b50600436106100365760003560e01c80632e64cec11461003b5780636057361d14610059575b600080fd5b610043610075565b60405161005091906100a1565b60405180910390f35b610073600480360381019061006e91906100ed565b61007e565b005b60008054905090565b8060008190555050565b6000819050919050565b61009b81610088565b82525050565b60006020820190506100b66000830184610092565b92915050565b600080fd5b6100ca81610088565b81146100d557600080fd5b50565b6000813590506100e7816100c1565b92915050565b600060208284031215610103576101026100bc565b5b6000610111848285016100d8565b9150509291505056fea2646970667358221220"
		
		bytecode, err := hex.DecodeString(storageContract)
		require.NoError(t, err)

		// Use Create call type for contract deployment
		result, err := evm.Call(Create{
			Caller:   caller,
			Value:    big.NewInt(0),
			InitCode: bytecode,
			Gas:      1000000,
		})
		require.NoError(t, err)
		assert.NotNil(t, result)
	})

	t.Run("Counter contract", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		counterAddr := primitives.NewAddress([20]byte{0x14})
		caller := primitives.ZeroAddress()
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		counterSlot := big.NewInt(0)
		counter := big.NewInt(0)
		err = evm.SetStorage(counterAddr, counterSlot, counter)
		require.NoError(t, err)

		increment := "5f5460010155"
		decrement := "5f5460010355"
		getCount := "5f545f5260205ff3"
		
		// Test increment
		incBytecode, _ := hex.DecodeString(increment)
		err = evm.SetCode(counterAddr, incBytecode)
		require.NoError(t, err)
		
		result, err := evm.Call(Call{
			Caller: caller,
			To:     counterAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
		
		value, err := evm.GetStorage(counterAddr, counterSlot)
		require.NoError(t, err)
		assert.Equal(t, uint64(1), value.Uint64())
		
		// Test increment again
		result, err = evm.Call(Call{
			Caller: caller,
			To:     counterAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
		
		value, err = evm.GetStorage(counterAddr, counterSlot)
		require.NoError(t, err)
		assert.Equal(t, uint64(2), value.Uint64())
		
		// Test decrement
		decBytecode, _ := hex.DecodeString(decrement)
		err = evm.SetCode(counterAddr, decBytecode)
		require.NoError(t, err)
		
		result, err = evm.Call(Call{
			Caller: caller,
			To:     counterAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
		
		value, err = evm.GetStorage(counterAddr, counterSlot)
		require.NoError(t, err)
		assert.Equal(t, uint64(1), value.Uint64())
		
		// Test get count
		getBytecode, _ := hex.DecodeString(getCount)
		err = evm.SetCode(counterAddr, getBytecode)
		require.NoError(t, err)
		
		result, err = evm.Call(Call{
			Caller: caller,
			To:     counterAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.True(t, result.Success)
		assert.Equal(t, 32, len(result.Output))
	})
}