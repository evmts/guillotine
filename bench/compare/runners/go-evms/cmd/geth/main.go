package main

import (
	"flag"
	"fmt"
	"math/big"
	"time"

	gethcommon "github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core"
	"github.com/ethereum/go-ethereum/core/rawdb"
	gethstate "github.com/ethereum/go-ethereum/core/state"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
	"github.com/ethereum/go-ethereum/triedb"
	"github.com/holiman/uint256"

	"guillotine-compare-go/common"
)

func gethChainConfig(fork string, chainID *big.Int) *params.ChainConfig {
	zero := uint64(0)
	cfg := &params.ChainConfig{
		ChainID:                 chainID,
		HomesteadBlock:          big.NewInt(0),
		EIP150Block:             big.NewInt(0),
		EIP155Block:             big.NewInt(0),
		EIP158Block:             big.NewInt(0),
		ByzantiumBlock:          big.NewInt(0),
		ConstantinopleBlock:     big.NewInt(0),
		PetersburgBlock:         big.NewInt(0),
		IstanbulBlock:           big.NewInt(0),
		BerlinBlock:             big.NewInt(0),
		LondonBlock:             big.NewInt(0),
		TerminalTotalDifficulty: big.NewInt(0),
		ShanghaiTime:            &zero,
		CancunTime:              &zero,
	}
	if fork == "PRAGUE" || fork == "OSAKA" {
		cfg.PragueTime = &zero
	}
	if fork == "OSAKA" {
		cfg.OsakaTime = &zero
	}
	return cfg
}

func buildGethState(w *common.JsonWorkload, chainCfg *params.ChainConfig) *gethstate.StateDB {
	memdb := rawdb.NewMemoryDatabase()
	tdb := triedb.NewDatabase(memdb, nil)
	sdb := gethstate.NewDatabase(tdb, nil)
	st, err := gethstate.New(gethcommon.Hash{}, sdb)
	if err != nil {
		panic(err)
	}
	for _, acc := range w.Accounts {
		addr := gethcommon.HexToAddress(acc.Address)
		st.CreateAccount(addr)
		bal := common.ParseHexU256(acc.Balance)
		st.SetBalance(addr, &bal, tracing.BalanceChangeUnspecified)
		st.SetNonce(addr, acc.Nonce, tracing.NonceChangeUnspecified)
		code := common.ParseHexBytes(acc.Code)
		if len(code) > 0 {
			st.SetCode(addr, code, tracing.CodeChangeUnspecified)
		}
		for _, kv := range acc.Storage {
			st.SetState(addr, gethcommon.HexToHash(kv[0]), gethcommon.HexToHash(kv[1]))
		}
	}
	rules := chainCfg.Rules(big.NewInt(0), true, 0)
	root, err := st.Commit(rules, 0)
	if err != nil {
		panic(err)
	}
	fresh, err := gethstate.New(root, sdb)
	if err != nil {
		panic(err)
	}
	return fresh
}

func main() {
	workloadPath := flag.String("workload", "", "path to canonical workload JSON")
	_ = flag.String("engine", "geth", "engine")
	mode := flag.String("mode", "warm", "mode: warm or cold")
	warmup := flag.Int("warmup", 20, "warmup iterations")
	minSamples := flag.Int("min-samples", 15, "min samples")
	maxSamples := flag.Int("max-samples", 200, "max samples")
	targetMs := flag.Int64("target-ms", 1500, "target measurement ms")
	flag.Parse()

	w := common.LoadWorkload(*workloadPath)
	chainCfg := gethChainConfig(w.Hardfork, common.ParseHexBig(w.Block.ChainID))
	prev := gethcommon.HexToHash(w.Block.Prevrandao)
	blockCtx := vm.BlockContext{
		CanTransfer: core.CanTransfer,
		Transfer:    core.Transfer,
		GetHash:     func(u uint64) gethcommon.Hash { return crypto.Keccak256Hash([]byte(fmt.Sprintf("%d", u))) },
		Coinbase:    gethcommon.HexToAddress(w.Block.Coinbase),
		GasLimit:    common.ParseHexU64(w.Block.GasLimit),
		BlockNumber: common.ParseHexBig(w.Block.Number),
		Time:        common.ParseHexU64(w.Block.Timestamp),
		Difficulty:  big.NewInt(0),
		BaseFee:     common.ParseHexBig(w.Block.Basefee),
		BlobBaseFee: big.NewInt(1),
		Random:      &prev,
	}
	to := gethcommon.HexToAddress(w.Tx.To)
	val := common.ParseHexU256(w.Tx.Value)
	gp := common.ParseHexU256(w.Tx.GasPrice)
	gpCopy := gp
	tip := uint256.NewInt(0)
	msg := &core.Message{
		To:        &to,
		From:      gethcommon.HexToAddress(w.Tx.Caller),
		Nonce:     w.Tx.Nonce,
		Value:     &val,
		GasLimit:  common.ParseHexU64(w.Tx.GasLimit),
		GasPrice:  &gp,
		GasFeeCap: &gpCopy,
		GasTipCap: tip,
		Data:      common.ParseHexBytes(w.Tx.Input),
	}

	baseState := buildGethState(w, chainCfg)
	isCold := *mode == "cold"

	runOnce := func() (bool, uint64, []byte, int64, string) {
		var st *gethstate.StateDB
		if isCold {
			st = buildGethState(w, chainCfg)
		} else {
			st = baseState.Copy()
		}
		gasPool := core.NewGasPool(blockCtx.GasLimit)
		var start time.Time
		if isCold {
			start = time.Now()
		}
		evm := vm.NewEVM(blockCtx, st, chainCfg, vm.Config{})
		if !isCold {
			start = time.Now()
		}
		res, err := core.ApplyMessage(evm, msg, gasPool)
		dt := time.Since(start).Nanoseconds()
		if err != nil {
			return false, 0, nil, dt, err.Error()
		}
		if res.Err != nil {
			return false, res.UsedGas, res.ReturnData, dt, res.Err.Error()
		}
		return true, res.UsedGas, res.ReturnData, dt, ""
	}

	common.MeasureAndEmit("geth", w, *mode, *warmup, *minSamples, *maxSamples, *targetMs, runOnce)
}
