# UTXOpia Sui Indexer

This service will ingest Sui package events and expose the normalized UTXOpia
indexer API used by the SDK and web app.

## Responsibilities

- Track Sui package checkpoints/cursors.
- Ingest UTXOpia Sui events.
- Store commitments, nullifiers, roots, redemption requests, and completions.
- Expose note scanning and pool state APIs.
- Provide replay/rebuild tooling for indexer recovery.

## Initial Event Types

```text
PoolCreated
CommitmentInserted
MerkleRootUpdated
NullifierSpent
RedemptionRequested
RedemptionCompleted
PoolPaused
PoolConfigUpdated
VerifyingKeyRegistered
JoinSplitVerified
```

## Planned Layout

```text
src/
  ingest/
  db/
  api/
  workers/
```
