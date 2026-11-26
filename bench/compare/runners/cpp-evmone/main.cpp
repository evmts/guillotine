#include <evmc/evmc.hpp>
#include <evmc/hex.hpp>
#include <evmone/evmone.h>
#include <intx/intx.hpp>
#include <nlohmann/json.hpp>
#include <test/state/block.hpp>
#include <test/state/hash_utils.hpp>
#include <test/state/state.hpp>
#include <test/state/state_view.hpp>
#include <test/state/transaction.hpp>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

using json = nlohmann::json;
using namespace evmone::state;

namespace
{
std::string trim_hex(const std::string& s)
{
    size_t start = 0;
    while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start])))
        ++start;
    size_t end = s.size();
    while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1])))
        --end;
    std::string t = s.substr(start, end - start);
    if (t.size() >= 2 && t[0] == '0' && (t[1] == 'x' || t[1] == 'X'))
        t = t.substr(2);
    return t;
}

uint64_t parse_u64(const std::string& s)
{
    auto h = trim_hex(s);
    if (h.empty())
        return 0;
    return std::stoull(h, nullptr, 16);
}

intx::uint256 parse_u256(const std::string& s)
{
    auto h = trim_hex(s);
    if (h.empty())
        return intx::uint256{0};
    return intx::from_string<intx::uint256>("0x" + h);
}

evmc::bytes parse_bytes(const std::string& s)
{
    auto h = trim_hex(s);
    if (h.empty())
        return {};
    if (h.size() % 2 == 1)
        h = "0" + h;
    auto opt = evmc::from_hex(h);
    if (!opt.has_value())
        throw std::runtime_error("invalid hex bytes: " + s);
    return *opt;
}

evmc::address parse_addr(const std::string& s)
{
    auto h = trim_hex(s);
    if (h.size() < 40)
        h = std::string(40 - h.size(), '0') + h;
    auto opt = evmc::from_hex<evmc::address>(h);
    if (!opt.has_value())
        throw std::runtime_error("invalid address: " + s);
    return *opt;
}

evmc::bytes32 parse_b32(const std::string& s)
{
    auto h = trim_hex(s);
    if (h.size() < 64)
        h = std::string(64 - h.size(), '0') + h;
    auto opt = evmc::from_hex<evmc::bytes32>(h);
    if (!opt.has_value())
        throw std::runtime_error("invalid bytes32: " + s);
    return *opt;
}

evmc_revision parse_rev(const std::string& s)
{
    if (s == "OSAKA")
        return EVMC_OSAKA;
    if (s == "PRAGUE")
        return EVMC_PRAGUE;
    if (s == "CANCUN")
        return EVMC_CANCUN;
    throw std::runtime_error("unsupported hardfork: " + s);
}

class MemStateView final : public StateView
{
public:
    struct Entry
    {
        Account account;
        evmc::bytes code;
        std::unordered_map<evmc::bytes32, evmc::bytes32> storage;
    };

    std::unordered_map<evmc::address, Entry> accounts;

    std::optional<Account> get_account(const evmc::address& addr) const noexcept override
    {
        auto it = accounts.find(addr);
        if (it == accounts.end())
            return std::nullopt;
        return it->second.account;
    }

    evmc::bytes get_account_code(const evmc::address& addr) const noexcept override
    {
        auto it = accounts.find(addr);
        if (it == accounts.end())
            return {};
        return it->second.code;
    }

    evmc::bytes32 get_storage(const evmc::address& addr, const evmc::bytes32& key) const noexcept override
    {
        auto it = accounts.find(addr);
        if (it == accounts.end())
            return {};
        auto sit = it->second.storage.find(key);
        if (sit == it->second.storage.end())
            return {};
        return sit->second;
    }
};

class ZeroBlockHashes final : public BlockHashes
{
public:
    evmc::bytes32 get_block_hash(int64_t) const noexcept override { return {}; }
};

void emit_failure(const std::string& engine, const std::string& workload, const std::string& mode,
    const std::string& hardfork, uint64_t gas_used, const std::string& reason)
{
    json j = {
        {"engine", engine},
        {"workload", workload},
        {"mode", mode},
        {"status", "failed"},
        {"hardfork", hardfork},
        {"success", false},
        {"gas_used", gas_used},
        {"reason", reason},
    };
    std::cout << j.dump() << "\n";
}

evmc::VM make_vm(const std::string& engine)
{
    evmc::VM vm{evmc_create_evmone()};
    if (engine == "evmone-advanced")
    {
        if (vm.set_option("advanced", "") != EVMC_SET_OPTION_SUCCESS)
            throw std::runtime_error("failed to enable evmone advanced mode");
    }
    else if (engine != "evmone-baseline")
    {
        throw std::runtime_error("unknown engine: " + engine);
    }
    return vm;
}
}  // namespace

int main(int argc, char** argv)
{
    try
    {
        std::string workload_path;
        std::string engine = "evmone-advanced";
        std::string mode = "warm";
        size_t warmup = 20;
        size_t min_samples = 15;
        size_t max_samples = 200;
        uint64_t target_ms = 1500;

        for (int i = 1; i < argc; ++i)
        {
            std::string arg = argv[i];
            if (arg == "--workload" && i + 1 < argc)
                workload_path = argv[++i];
            else if (arg == "--engine" && i + 1 < argc)
                engine = argv[++i];
            else if (arg == "--mode" && i + 1 < argc)
                mode = argv[++i];
            else if (arg == "--warmup" && i + 1 < argc)
                warmup = std::stoull(argv[++i]);
            else if (arg == "--min-samples" && i + 1 < argc)
                min_samples = std::stoull(argv[++i]);
            else if (arg == "--max-samples" && i + 1 < argc)
                max_samples = std::stoull(argv[++i]);
            else if (arg == "--target-ms" && i + 1 < argc)
                target_ms = std::stoull(argv[++i]);
            else
                throw std::runtime_error("unknown arg: " + arg);
        }

        if (workload_path.empty())
            throw std::runtime_error("--workload required");

        std::ifstream f(workload_path);
        if (!f)
            throw std::runtime_error("cannot open " + workload_path);
        json w = json::parse(f);

        const std::string name = w.at("name").get<std::string>();
        const std::string hardfork = w.at("hardfork").get<std::string>();
        const auto rev = parse_rev(hardfork);

        MemStateView state_view;
        for (const auto& acc : w.at("accounts"))
        {
            const auto addr = parse_addr(acc.at("address").get<std::string>());
            MemStateView::Entry entry;
            entry.account.balance = parse_u256(acc.at("balance").get<std::string>());
            entry.account.nonce = acc.at("nonce").get<uint64_t>();
            entry.code = parse_bytes(acc.at("code").get<std::string>());
            entry.account.code_hash = entry.code.empty() ? Account::EMPTY_CODE_HASH : evmone::keccak256(entry.code);
            for (const auto& kv : acc.at("storage"))
            {
                entry.storage[parse_b32(kv.at(0).get<std::string>())] =
                    parse_b32(kv.at(1).get<std::string>());
            }
            entry.account.has_storage = !entry.storage.empty();
            state_view.accounts.emplace(addr, std::move(entry));
        }

        const auto& jb = w.at("block");
        BlockInfo block;
        block.number = static_cast<int64_t>(parse_u64(jb.at("number").get<std::string>()));
        block.timestamp = static_cast<int64_t>(parse_u64(jb.at("timestamp").get<std::string>()));
        block.coinbase = parse_addr(jb.at("coinbase").get<std::string>());
        block.base_fee = parse_u64(jb.at("basefee").get<std::string>());
        block.prev_randao = parse_b32(jb.at("prevrandao").get<std::string>());
        block.gas_limit = static_cast<int64_t>(parse_u64(jb.at("gas_limit").get<std::string>()));
        block.chain_id = parse_u64(jb.at("chain_id").get<std::string>());
        block.blob_base_fee = intx::uint256{1};

        const auto& jtx = w.at("tx");
        Transaction tx;
        tx.type = Transaction::Type::legacy;
        tx.sender = parse_addr(jtx.at("caller").get<std::string>());
        tx.to = parse_addr(jtx.at("to").get<std::string>());
        tx.value = parse_u256(jtx.at("value").get<std::string>());
        tx.data = parse_bytes(jtx.at("input").get<std::string>());
        tx.gas_limit = static_cast<int64_t>(parse_u64(jtx.at("gas_limit").get<std::string>()));
        tx.max_gas_price = parse_u256(jtx.at("gas_price").get<std::string>());
        tx.max_priority_gas_price = tx.max_gas_price;
        tx.nonce = jtx.at("nonce").get<uint64_t>();
        tx.chain_id = block.chain_id;

        ZeroBlockHashes block_hashes;
        const bool is_cold = (mode == "cold");
        evmc::VM warm_vm = make_vm(engine);

        auto run_once = [&](bool cold) -> std::tuple<bool, uint64_t, uint64_t, std::string> {
            const auto t0 = std::chrono::steady_clock::now();
            auto props_or_err = validate_transaction(
                state_view, block, tx, rev, block.gas_limit, block.gas_limit, 0);
            if (std::holds_alternative<std::error_code>(props_or_err))
            {
                const auto dt = std::chrono::duration_cast<std::chrono::nanoseconds>(
                    std::chrono::steady_clock::now() - t0)
                                    .count();
                return {false, 0, static_cast<uint64_t>(dt),
                    std::get<std::error_code>(props_or_err).message()};
            }
            const auto& props = std::get<TransactionProperties>(props_or_err);
            TransactionReceipt receipt;
            if (cold)
            {
                evmc::VM cold_vm = make_vm(engine);
                receipt = transition(state_view, block, block_hashes, tx, rev, cold_vm, props);
            }
            else
            {
                receipt = transition(state_view, block, block_hashes, tx, rev, warm_vm, props);
            }
            const auto dt = std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - t0)
                                .count();
            const bool ok = (receipt.status == EVMC_SUCCESS);
            return {ok, static_cast<uint64_t>(receipt.gas_used), static_cast<uint64_t>(dt),
                ok ? "" : ("evmc status " + std::to_string(static_cast<int>(receipt.status)))};
        };

        auto [ok, ref_gas, preflight_ns, err] = run_once(is_cold);
        if (!ok)
        {
            emit_failure(engine, name, mode, hardfork, ref_gas, err);
            return 0;
        }

        size_t budget_warmup = warmup;
        if (preflight_ns > 0)
        {
            size_t cap = std::max<size_t>(2, static_cast<size_t>(500'000'000ULL / preflight_ns));
            budget_warmup = std::min(warmup, cap);
        }

        for (size_t i = 0; i < budget_warmup; ++i)
        {
            auto [w_ok, w_gas, _, w_err] = run_once(is_cold);
            if (!w_ok || w_gas != ref_gas)
            {
                emit_failure(engine, name, mode, hardfork, w_gas, "warmup non-determinism");
                return 0;
            }
        }

        std::vector<uint64_t> samples;
        samples.reserve(max_samples);
        const uint64_t target_ns = target_ms * 1'000'000ULL;
        uint64_t elapsed_ns = 0;
        while (samples.size() < max_samples)
        {
            if (samples.size() >= min_samples && elapsed_ns >= target_ns)
                break;
            auto [s_ok, s_gas, dt, s_err] = run_once(is_cold);
            if (!s_ok || s_gas != ref_gas)
            {
                emit_failure(engine, name, mode, hardfork, s_gas, "sample non-determinism");
                return 0;
            }
            samples.push_back(dt);
            elapsed_ns += dt;
        }

        auto sorted = samples;
        std::sort(sorted.begin(), sorted.end());
        const size_t n = sorted.size();
        const double median_ns = (n % 2 == 1)
                                     ? static_cast<double>(sorted[n / 2])
                                     : (static_cast<double>(sorted[n / 2 - 1]) +
                                           static_cast<double>(sorted[n / 2])) /
                                           2.0;
        long double sum = 0;
        for (auto v : sorted)
            sum += v;
        const double mean_ns = static_cast<double>(sum / n);
        const double min_ns = static_cast<double>(sorted.front());
        const double max_ns = static_cast<double>(sorted.back());
        const double p25_ns = static_cast<double>(sorted[n / 4]);
        const double p75_ns = static_cast<double>(sorted[(n * 3) / 4]);
        const double iqr_ns = p75_ns - p25_ns;
        const size_t p95_idx = std::min(n - 1, ((n * 95 + 99) / 100) - 1);
        const double p95_ns = static_cast<double>(sorted[p95_idx]);
        const double mgas = median_ns > 0.0 ? (static_cast<double>(ref_gas) * 1000.0) / median_ns : 0.0;

        json out = {
            {"engine", engine},
            {"workload", name},
            {"mode", mode},
            {"status", "ok"},
            {"hardfork", hardfork},
            {"success", true},
            {"gas_used", ref_gas},
            {"output_hex", nullptr},  // evmone::state::TransactionReceipt omits top-level return data
            {"jit_compiled", false},
            {"compile_ns", nullptr},
            {"warmup_runs", budget_warmup},
            {"sample_count", n},
            {"median_ns", median_ns},
            {"mean_ns", mean_ns},
            {"min_ns", min_ns},
            {"max_ns", max_ns},
            {"p25_ns", p25_ns},
            {"p75_ns", p75_ns},
            {"iqr_ns", iqr_ns},
            {"p95_ns", p95_ns},
            {"mgas_per_sec", mgas},
            {"samples_ns", samples},
        };
        std::cout << out.dump() << "\n";
        return 0;
    }
    catch (const std::exception& e)
    {
        std::cerr << "compare-evmone: " << e.what() << "\n";
        return 1;
    }
}
