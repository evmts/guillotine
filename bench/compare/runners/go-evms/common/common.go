package common

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/holiman/uint256"
)

type JsonBlock struct {
	Number     string `json:"number"`
	Timestamp  string `json:"timestamp"`
	Coinbase   string `json:"coinbase"`
	Basefee    string `json:"basefee"`
	Prevrandao string `json:"prevrandao"`
	GasLimit   string `json:"gas_limit"`
	ChainID    string `json:"chain_id"`
}

type JsonAccount struct {
	Address string      `json:"address"`
	Balance string      `json:"balance"`
	Nonce   uint64      `json:"nonce"`
	Code    string      `json:"code"`
	Storage [][2]string `json:"storage"`
}

type JsonTx struct {
	Caller   string `json:"caller"`
	To       string `json:"to"`
	Value    string `json:"value"`
	Input    string `json:"input"`
	GasLimit string `json:"gas_limit"`
	GasPrice string `json:"gas_price"`
	Nonce    uint64 `json:"nonce"`
}

type JsonWorkload struct {
	Name     string        `json:"name"`
	Hardfork string        `json:"hardfork"`
	Block    JsonBlock     `json:"block"`
	Accounts []JsonAccount `json:"accounts"`
	Tx       JsonTx        `json:"tx"`
}

func LoadWorkload(path string) *JsonWorkload {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	var w JsonWorkload
	if err := json.Unmarshal(data, &w); err != nil {
		panic(err)
	}
	return &w
}

func TrimHex(s string) string {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "0x")
	s = strings.TrimPrefix(s, "0X")
	return s
}

func ParseHexU64(s string) uint64 {
	h := TrimHex(s)
	if h == "" {
		return 0
	}
	v, err := strconv.ParseUint(h, 16, 64)
	if err != nil {
		panic(err)
	}
	return v
}

func ParseHexBig(s string) *big.Int {
	h := TrimHex(s)
	if h == "" {
		return new(big.Int)
	}
	v, ok := new(big.Int).SetString(h, 16)
	if !ok {
		panic("bad hex big.Int: " + s)
	}
	return v
}

func ParseHexU256(s string) uint256.Int {
	h := strings.TrimLeft(TrimHex(s), "0")
	if h == "" {
		return uint256.Int{}
	}
	v, err := uint256.FromHex("0x" + h)
	if err != nil {
		panic(err)
	}
	return *v
}

func ParseHexBytes(s string) []byte {
	h := TrimHex(s)
	if h == "" {
		return nil
	}
	if len(h)%2 == 1 {
		h = "0" + h
	}
	b, err := hex.DecodeString(h)
	if err != nil {
		panic(err)
	}
	return b
}

func EmitFailure(engine string, w *JsonWorkload, mode string, gas uint64, reason string) {
	b, _ := json.Marshal(map[string]any{
		"engine":   engine,
		"workload": w.Name,
		"mode":     mode,
		"status":   "failed",
		"hardfork": w.Hardfork,
		"success":  false,
		"gas_used": gas,
		"reason":   reason,
	})
	fmt.Println(string(b))
}

func MeasureAndEmit(
	engine string,
	w *JsonWorkload,
	mode string,
	warmup, minSamples, maxSamples int,
	targetMs int64,
	runOnce func() (bool, uint64, []byte, int64, string),
) {
	ok, refGas, refOut, preflightNs, errMsg := runOnce()
	if !ok {
		if errMsg == "" {
			errMsg = "preflight reverted or halted"
		}
		EmitFailure(engine, w, mode, refGas, errMsg)
		return
	}

	budgetWarmup := warmup
	if preflightNs > 0 {
		capW := int(500_000_000 / preflightNs)
		if capW < 2 {
			capW = 2
		}
		if capW < budgetWarmup {
			budgetWarmup = capW
		}
	}

	for i := 0; i < budgetWarmup; i++ {
		wOk, wGas, wOut, _, _ := runOnce()
		if !wOk || wGas != refGas || string(wOut) != string(refOut) {
			EmitFailure(engine, w, mode, wGas, "warmup non-determinism")
			return
		}
	}

	samples := make([]int64, 0, maxSamples)
	targetNs := targetMs * 1_000_000
	var elapsedNs int64
	for len(samples) < maxSamples {
		if len(samples) >= minSamples && elapsedNs >= targetNs {
			break
		}
		sOk, sGas, sOut, dt, _ := runOnce()
		if !sOk || sGas != refGas || string(sOut) != string(refOut) {
			EmitFailure(engine, w, mode, sGas, "sample non-determinism")
			return
		}
		samples = append(samples, dt)
		elapsedNs += dt
	}

	sorted := append([]int64(nil), samples...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	n := len(sorted)
	var median float64
	if n%2 == 1 {
		median = float64(sorted[n/2])
	} else {
		median = float64(sorted[n/2-1]+sorted[n/2]) / 2.0
	}
	var sum int64
	for _, v := range sorted {
		sum += v
	}
	mean := float64(sum) / float64(n)
	minV := float64(sorted[0])
	maxV := float64(sorted[n-1])
	p25 := float64(sorted[n/4])
	p75 := float64(sorted[(n*3)/4])
	iqr := p75 - p25
	p95Idx := (n*95 + 99)/100 - 1
	if p95Idx < 0 {
		p95Idx = 0
	}
	if p95Idx >= n {
		p95Idx = n - 1
	}
	p95 := float64(sorted[p95Idx])
	mgas := 0.0
	if median > 0 {
		mgas = (float64(refGas) * 1000.0) / median
	}

	outObj := map[string]any{
		"engine":       engine,
		"workload":     w.Name,
		"mode":         mode,
		"status":       "ok",
		"hardfork":     w.Hardfork,
		"success":      true,
		"gas_used":     refGas,
		"output_hex":   "0x" + hex.EncodeToString(refOut),
		"jit_compiled": false,
		"compile_ns":   nil,
		"warmup_runs":  budgetWarmup,
		"sample_count": n,
		"median_ns":    median,
		"mean_ns":      mean,
		"min_ns":       minV,
		"max_ns":       maxV,
		"p25_ns":       p25,
		"p75_ns":       p75,
		"iqr_ns":       iqr,
		"p95_ns":       p95,
		"mgas_per_sec": mgas,
		"samples_ns":   samples,
	}
	b, _ := json.Marshal(outObj)
	fmt.Println(string(b))
}
