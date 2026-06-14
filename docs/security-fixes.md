# Security scan follow-ups (sui-first-scan)

Source: AI security scan (`sui-first-scan.json`, 35 findings). Each actionable finding was
re-verified against the current `entry/` + `lib/` layout (the scan ran on the old flat
`sources/` layout, so its line numbers were stale).

## Applied on-chain (with regression tests)

| # | Severity | Fix | Location |
|---|----------|-----|----------|
| 1 | MAJOR | `complete_redemption` forces all non-recipient/non-fee value back to the pool change script | `entry/redemption.move` |
| 3 | MEDIUM | `complete_redemption` requires the tx to spend ONLY reserved inputs (`bitcoin::input_count`) | `entry/redemption.move`, `lib/bitcoin.move` |
| 6 | MEDIUM | `deposit_fee_bps < MAX_BPS` (was `<=`) — blocks the 100%-fee deposit DoS | `entry/pool.move` |
| 7 | MEDIUM | Testnet4 min-difficulty check guards `timestamp > parent_timestamp` (no `wrapping_sub_u32` underflow) | `entry/btc_light_client.move` |
| 5 | MEDIUM | Redemption fee cap is now a protocol constant (`MAX_FEE_SATS`), not an unbound user input — removes the proof-replay fee-tampering vector | `entry/redemption.move` + `sdk-sui` |
| 8 | DISC | Admin-gated commitment-tree rotation past the 65,536-leaf cap | `entry/commitment_tree.move`, `entry/pool.move` |
| 9 | DISC | Nullifiers range-checked `< BN254_FR` before byte-equality dedup | `lib/public_inputs.move` |

## No action

- **#2 (MAJOR)** already fixed — the reorg ancestor walk-back loop in `submit_headers`
  repairs the canonical height map. Covered by `i_reorg_multi_batch_fork`.
- **#10 (MINOR)** false positive — credited amount is script-bound via
  `find_output_by_script(pool_script)`, not the position-guessed deposit output.
- **#4 (MEDIUM)** the stated cross-pool theft path is blocked: `RedemptionRequest`s are
  only created through the verified `redeem` path with the real `pool_id`. The missing
  queue↔pool binding is latent defense-in-depth only.

## #8 — commitment tree rotation: operator procedure

Once a pool's commitment tree reaches 65,536 leaves (`commitment_tree::is_full`):

1. `commitment_tree::create_successor(&full_tree, ctx)` — mints + shares a fresh tree with
   `tree_number + 1`. Aborts (`tree_not_full`, 50) unless the current tree is full.
2. `pool::rotate_commitment_tree(&admin_cap, &mut pool, &full_tree, &new_tree)` — rebinds
   the pool to the empty successor. Guards: old tree is the bound one and full; new tree is
   the immediate (`+1`) successor and empty. Emits `CommitmentTreeRotated`.

Note: root history does not carry across trees, so in-flight proofs generated against the
old tree's roots become invalid after rotation (expected; rotate only when full).

## #5 — FIXED by aligning Sui with Solana (fee cap is a protocol constant)

Original problem: `redeem()` took `max_fees_sats` as a user array bound to *nothing* in the
proof, so a proof-replay frontrunner could re-submit the same proof with a different fee
cap (griefing → a queued redemption that can't be completed within the cap).

Investigation across the `/utxopia` workspace established two things:
- The circuit (`circuits/circom/joinsplit.circom`) treats `boundParamsHash` as a
  **pass-through public signal** — it never recomputes it — so binding extra fields would
  need only SDK + on-chain changes, no circuit/trusted-setup work.
- The bound-params hash is a **cross-chain shared primitive** (one 77-byte layout in
  `sdk/.../bound-params.ts`, consumed by both Sui `bound_params::redeem_hash` and Solana
  `compute_bound_params_hash_redeem`). Solana sidesteps the whole issue: it uses a fixed
  `MAX_FEE_SATS` constant, not a user-supplied per-request fee.

Chosen fix (matches Solana, no hash/circuit/Solana changes): make the Sui redemption
miner-fee cap a protocol constant rather than a user input.

- `entry/redemption.move`: added `const MAX_FEE_SATS: u64 = 50_000;`, dropped the
  `max_fees_sats` parameter from `redeem()`, and enqueue each request with `MAX_FEE_SATS`.
- `sdk-sui/src/sui-adapter.ts`: removed `maxFeesSats` from the `redeem` moveCall and its
  validation. The `maxFeeSats`/`maxFeesSats` fields remain on the shared `RedemptionInput`
  interface (used by other chains) but are ignored on Sui.

Deployment note: this is a breaking change to the Sui `redeem` entry signature (one fewer
argument) — ship the Move package upgrade and the `sdk-sui` release together. Solana and the
circuit are untouched. The `UTXOPIA_SUI_REDEEM_MAX_FEE_SATS` env knob in `regtest-flow.ts`
is now a no-op.
