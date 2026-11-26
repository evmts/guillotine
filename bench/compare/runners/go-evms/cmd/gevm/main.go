package main

import (
	"flag"
	"fmt"
	"time"

	"github.com/Giulio2002/gevm/host"
	"github.com/Giulio2002/gevm/spec"
	gevmstate "github.com/Giulio2002/gevm/state"
	"github.com/Giulio2002/gevm/types"
	"github.com/holiman/uint256"

	"guillotine-compare-go/common"
)

func parseGevmAddr(s string) types.Address {
	var a types.Address
	b := common.ParseHexBytes(s)
	copy(a[20-len(b):], b)
	return a
}

type gevmMemDB struct {
	accounts map[types.Address]gevmstate.AccountInfo
	storage  map[types.Address]map[uint256.Int]uint256.Int
	codes    map[types.B256][]byte
}

func newGevmMemDB(w *common.JsonWorkload) *gevmMemDB {
	db := &gevmMemDB{
		accounts: make(map[types.Address]gevmstate.AccountInfo, len(w.Accounts)),
		storage:  make(map[types.Address]map[uint256.Int]uint256.Int, len(w.Accounts)),
		codes:    make(map[types.B256][]byte),
	}
	for _, acc := range w.Accounts {
		addr := parseGevmAddr(acc.Address)
		code := common.ParseHexBytes(acc.Code)
		codeHash := types.KeccakEmpty
		if len(code) > 0 {
			codeHash = types.Keccak256(code)
			db.codes[codeHash] = code
		}
		db.accounts[addr] = gevmstate.AccountInfo{
			Balance:  common.ParseHexU256(acc.Balance),
			Nonce:    acc.Nonce,
			CodeHash: codeHash,
			Code:     code,
		}
		if len(acc.Storage) > 0 {
			st := make(map[uint256.Int]uint256.Int, len(acc.Storage))
			for _, kv := range acc.Storage {
				st[common.ParseHexU256(kv[0])] = common.ParseHexU256(kv[1])
			}
			db.storage[addr] = st
		}
	}
	return db
}

func (db *gevmMemDB) Basic(addr types.Address) (gevmstate.AccountInfo, bool, error) {
	info, ok := db.accounts[addr]
	return info, ok, nil
}
func (db *gevmMemDB) CodeByHash(hash types.B256) (types.Bytes, error) { return db.codes[hash], nil }
func (db *gevmMemDB) Code(addr types.Address) (types.Bytes, error) {
	if info, ok := db.accounts[addr]; ok {
		return info.Code, nil
	}
	return nil, nil
}
func (db *gevmMemDB) Storage(addr types.Address, index uint256.Int) (uint256.Int, error) {
	if st, ok := db.storage[addr]; ok {
		return st[index], nil
	}
	return uint256.Int{}, nil
}
func (db *gevmMemDB) HasStorage(addr types.Address) (bool, error) {
	st, ok := db.storage[addr]
	return ok && len(st) > 0, nil
}
func (db *gevmMemDB) BlockHash(number uint64) (types.B256, error) { return types.B256{}, nil }

func gevmFork(s string) spec.ForkID {
	switch s {
	case "OSAKA":
		return spec.Osaka
	case "PRAGUE":
		return spec.Prague
	case "CANCUN":
		return spec.Cancun
	default:
		panic("unsupported fork: " + s)
	}
}

func main() {
	workloadPath := flag.String("workload", "", "path to canonical workload JSON")
	_ = flag.String("engine", "gevm", "engine")
	mode := flag.String("mode", "warm", "mode: warm or cold")
	warmup := flag.Int("warmup", 20, "warmup iterations")
	minSamples := flag.Int("min-samples", 15, "min samples")
	maxSamples := flag.Int("max-samples", 200, "max samples")
	targetMs := flag.Int64("target-ms", 1500, "target measurement ms")
	flag.Parse()

	w := common.LoadWorkload(*workloadPath)
	fork := gevmFork(w.Hardfork)
	prev := common.ParseHexU256(w.Block.Prevrandao)
	block := host.BlockEnv{
		Beneficiary: parseGevmAddr(w.Block.Coinbase),
		GasLimit:    common.ParseHexU256(w.Block.GasLimit),
		BaseFee:     common.ParseHexU256(w.Block.Basefee),
		Number:      common.ParseHexU256(w.Block.Number),
		Timestamp:   common.ParseHexU256(w.Block.Timestamp),
		Prevrandao:  &prev,
	}
	cfg := host.CfgEnv{ChainId: common.ParseHexU256(w.Block.ChainID)}
	tx := host.Transaction{
		Kind:     host.TxKindCall,
		TxType:   host.TxTypeLegacy,
		Caller:   parseGevmAddr(w.Tx.Caller),
		To:       parseGevmAddr(w.Tx.To),
		Value:    common.ParseHexU256(w.Tx.Value),
		Input:    common.ParseHexBytes(w.Tx.Input),
		GasLimit: common.ParseHexU64(w.Tx.GasLimit),
		GasPrice: common.ParseHexU256(w.Tx.GasPrice),
		Nonce:    w.Tx.Nonce,
	}
	warmDB := newGevmMemDB(w)
	isCold := *mode == "cold"

	runOnce := func() (bool, uint64, []byte, int64, string) {
		db := warmDB
		if isCold {
			db = newGevmMemDB(w)
		}
		var start time.Time
		if isCold {
			start = time.Now()
		}
		evm := host.NewEvm(db, fork, block, cfg)
		if !isCold {
			start = time.Now()
		}
		res := evm.Transact(&tx)
		dt := time.Since(start).Nanoseconds()
		evm.ReleaseEvm()
		out := append([]byte(nil), res.Output...)
		errStr := ""
		if !res.IsSuccess() {
			errStr = fmt.Sprintf("gevm kind=%v reason=%v validation=%v", res.Kind, res.Reason, res.ValidationError)
		}
		return res.IsSuccess(), res.GasUsed, out, dt, errStr
	}

	common.MeasureAndEmit("gevm", w, *mode, *warmup, *minSamples, *maxSamples, *targetMs, runOnce)
}
