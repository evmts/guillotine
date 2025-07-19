/// EVM gas cost constants re-exported from primitives
///
/// This module re-exports gas constants from the primitives package for
/// backwards compatibility with existing EVM code.
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

// Re-export all constants from primitives
pub const GasQuickStep = GasConstants.GasQuickStep;
pub const GasFastestStep = GasConstants.GasFastestStep;
pub const GasFastStep = GasConstants.GasFastStep;
pub const GasMidStep = GasConstants.GasMidStep;
pub const GasSlowStep = GasConstants.GasSlowStep;
pub const GasExtStep = GasConstants.GasExtStep;

pub const Keccak256Gas = GasConstants.Keccak256Gas;
pub const Keccak256WordGas = GasConstants.Keccak256WordGas;

pub const SloadGas = GasConstants.SloadGas;
pub const ColdSloadCost = GasConstants.ColdSloadCost;
pub const ColdAccountAccessCost = GasConstants.ColdAccountAccessCost;
pub const WarmStorageReadCost = GasConstants.WarmStorageReadCost;
pub const SstoreSentryGas = GasConstants.SstoreSentryGas;
pub const SstoreSetGas = GasConstants.SstoreSetGas;
pub const SstoreResetGas = GasConstants.SstoreResetGas;
pub const SstoreClearGas = GasConstants.SstoreClearGas;
pub const SstoreRefundGas = GasConstants.SstoreRefundGas;

pub const JumpdestGas = GasConstants.JumpdestGas;

pub const LogGas = GasConstants.LogGas;
pub const LogDataGas = GasConstants.LogDataGas;
pub const LogTopicGas = GasConstants.LogTopicGas;

pub const CreateGas = GasConstants.CreateGas;
pub const CallGas = GasConstants.CallGas;
pub const CallStipend = GasConstants.CallStipend;
pub const CallValueTransferGas = GasConstants.CallValueTransferGas;
pub const CallNewAccountGas = GasConstants.CallNewAccountGas;

pub const CallValueCost = GasConstants.CallValueCost;
pub const CallCodeCost = GasConstants.CallCodeCost;
pub const DelegateCallCost = GasConstants.DelegateCallCost;
pub const StaticCallCost = GasConstants.StaticCallCost;
pub const NewAccountCost = GasConstants.NewAccountCost;
pub const SelfdestructGas = GasConstants.SelfdestructGas;
pub const SelfdestructRefundGas = GasConstants.SelfdestructRefundGas;

pub const MemoryGas = GasConstants.MemoryGas;
pub const QuadCoeffDiv = GasConstants.QuadCoeffDiv;

pub const CreateDataGas = GasConstants.CreateDataGas;
pub const InitcodeWordGas = GasConstants.InitcodeWordGas;
pub const MaxInitcodeSize = GasConstants.MaxInitcodeSize;

pub const TxGas = GasConstants.TxGas;
pub const TxGasContractCreation = GasConstants.TxGasContractCreation;
pub const TxDataZeroGas = GasConstants.TxDataZeroGas;
pub const TxDataNonZeroGas = GasConstants.TxDataNonZeroGas;
pub const CopyGas = GasConstants.CopyGas;
pub const COPY_GAS = GasConstants.CopyGas;
pub const MaxRefundQuotient = GasConstants.MaxRefundQuotient;

pub const BlobHashGas = GasConstants.BlobHashGas;
pub const BlobBaseFeeGas = GasConstants.BlobBaseFeeGas;

pub const TLoadGas = GasConstants.TLoadGas;
pub const TStoreGas = GasConstants.TStoreGas;

pub const IDENTITY_BASE_COST = GasConstants.IDENTITY_BASE_COST;
pub const IDENTITY_WORD_COST = GasConstants.IDENTITY_WORD_COST;
pub const SHA256_BASE_COST = GasConstants.SHA256_BASE_COST;
pub const SHA256_WORD_COST = GasConstants.SHA256_WORD_COST;
pub const RIPEMD160_BASE_COST = GasConstants.RIPEMD160_BASE_COST;
pub const RIPEMD160_WORD_COST = GasConstants.RIPEMD160_WORD_COST;
pub const ECRECOVER_COST = GasConstants.ECRECOVER_COST;

pub const ECADD_GAS_COST = GasConstants.ECADD_GAS_COST;
pub const ECADD_GAS_COST_BYZANTIUM = GasConstants.ECADD_GAS_COST_BYZANTIUM;
pub const ECMUL_GAS_COST = GasConstants.ECMUL_GAS_COST;
pub const ECMUL_GAS_COST_BYZANTIUM = GasConstants.ECMUL_GAS_COST_BYZANTIUM;
pub const ECPAIRING_BASE_GAS_COST = GasConstants.ECPAIRING_BASE_GAS_COST;
pub const ECPAIRING_PER_PAIR_GAS_COST = GasConstants.ECPAIRING_PER_PAIR_GAS_COST;
pub const ECPAIRING_BASE_GAS_COST_BYZANTIUM = GasConstants.ECPAIRING_BASE_GAS_COST_BYZANTIUM;
pub const ECPAIRING_PER_PAIR_GAS_COST_BYZANTIUM = GasConstants.ECPAIRING_PER_PAIR_GAS_COST_BYZANTIUM;

pub const MODEXP_MIN_GAS = GasConstants.MODEXP_MIN_GAS;
pub const MODEXP_QUADRATIC_THRESHOLD = GasConstants.MODEXP_QUADRATIC_THRESHOLD;
pub const MODEXP_LINEAR_THRESHOLD = GasConstants.MODEXP_LINEAR_THRESHOLD;

pub const CALL_BASE_COST = GasConstants.CALL_BASE_COST;
pub const CALL_COLD_ACCOUNT_COST = GasConstants.CALL_COLD_ACCOUNT_COST;
pub const CALL_VALUE_TRANSFER_COST = GasConstants.CALL_VALUE_TRANSFER_COST;
pub const CALL_NEW_ACCOUNT_COST = GasConstants.CALL_NEW_ACCOUNT_COST;
pub const GAS_STIPEND_VALUE_TRANSFER = GasConstants.GAS_STIPEND_VALUE_TRANSFER;
pub const CALL_GAS_RETENTION_DIVISOR = GasConstants.CALL_GAS_RETENTION_DIVISOR;

// Re-export functions
pub const memory_gas_cost = GasConstants.memory_gas_cost;
pub const wordCount = GasConstants.wordCount;

