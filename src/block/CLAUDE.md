# CLAUDE.md - Block Module

## MISSION CRITICAL: Block Structure and Validation
**Block handling errors cause consensus failures and chain splits.** Block validation must be perfect for network consensus.

## Block Validation (CONSENSUS CRITICAL)
- **Header**: Parent hash, merkle roots, difficulty, timestamp, gas limit
- **Transactions**: Validation and ordering, execute in sequence
- **State Root**: Compute world state merkle root
- **Gas Accounting**: Precise limit and usage tracking
- **Rewards**: Block and uncle rewards (pre-merge)

## Critical Safety Checks
- Parent block hash validation
- Gas limit bounds (EIP-1559 adjustments)
- Timestamp monotonicity
- Difficulty calculation (pre-merge)
- Transaction/receipt root verification

## Key Responsibilities
- **Parsing**: Extract and validate header fields
- **Processing**: Execute transactions in order
- **Merkle**: Compute state/transaction/receipt roots
- **Validation**: Ensure all consensus rules

## Performance & Emergency
- **Performance**: Parallel transaction validation, efficient merkle computation, block cache, database batching
- **Emergency**: Invalid block rejection, chain reorganization, consensus failure detection, corrupted data recovery

**Block processing is heart of consensus. Any specification deviation forks the network.**