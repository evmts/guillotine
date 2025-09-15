# CLAUDE.md - Provider Module

## MISSION CRITICAL: Data Provider Abstraction
**Provider bugs cause stale data, consensus failures, incorrect execution.**

## Provider Types
- **State Provider**: Account/storage data access
- **Block Provider**: Historical block/transaction data
- **Network Provider**: Real-time blockchain synchronization
- **Cache Provider**: Performance optimization with consistency

## Key Responsibilities
- **Data Integrity**: Consistent, validated data
- **Caching Strategy**: Balance performance with freshness
- **Error Handling**: Graceful degradation on failures
- **State Sync**: Keep local state synchronized
- **Historical Access**: Past blockchain states

## Critical Safety
- Validate all external data
- Handle network failures gracefully
- Maintain consistency across updates
- Prevent stale data affecting consensus
- Retry mechanisms with backoff

## Performance
- Intelligent caching with TTL/invalidation
- Batch operations for multiple requests
- Connection pooling for network providers
- Lazy loading of expensive structures

## Data Validation
- Merkle proof verification for state
- Block header validation
- Transaction signature verification
- Gas calculation validation
- State root consistency checks

## Emergency Procedures
- Fallback to alternative sources
- Data corruption detection/recovery
- Network partition handling
- Cache invalidation on errors
- Safe degradation modes

**Providers are foundation of data integrity. Incorrect/stale data propagates system-wide.**