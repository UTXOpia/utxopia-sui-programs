# Sui Programs — AI Audit Remediation (2026-06-18)

Source report: `utxopia-utxopia-sui-programs-main.json` (exported 2026-06-17), 59 findings
(1 critical, 4 major, 8 medium, 4 minor, 16 info, 26 discussion).

Branch: `sui-audit-fixes-2026-06-18`. Status after changes: `sui move build` clean,
`sui move test` = **93/93 passing** (3 new regression tests added).

---

## Fixed (code changes landed)

| # | Sev | Title | Fix | Files |
|---|-----|-------|-----|-------|
| 0 | CRITICAL | Tree rotation freezes notes & pending deposits | Pool now records each rotated-out tree's final root in `historical_roots`; `transact`/`redeem`/`unshield` accept proofs against those roots, so pre-rotation notes stay spendable. Deposit OP_RETURN tag bound to the **pool only** (tree component dropped) so deposits survive rotation. | `pool.move`, `transact.move`, `redemption.move`, `token_registry.move`, `btc_deposit.move` |
| 1 | MAJOR | Finality bypass via pre-stored side forks | Reorg now walks back to the **true common ancestor** and asserts that fork height ≥ `finalized_height`, instead of checking only the batch's immediate predecessor. | `btc_light_client.move` |
| 2 | MAJOR | Valid Bitcoin merkle proofs rejected (dup sibling) | Replaced the unconditional `sib != current` reject with a directional check: a duplicate sibling is allowed only as the **right** child (`is_left == false`), which is Bitcoin's legitimate odd-width duplication, while still rejecting the CVE-2012-2459 forgery direction. | `btc_light_client.move` |
| 3 | MAJOR | MEV/UTXO theft via fake `RedemptionQueue` + abandoned reservations | Pool binds a single authorized queue (`redemption_queue_id`); `redeem`/`mark_processing`/`complete_redemption`/`approve_signing`/`consume_approval` now require it. Added `abort_processing` to release reserved UTXOs from a stalled redemption. | `pool.move`, `redemption.move`, `ika_policy.move`, `btc_deposit.move` |
| 4 | MAJOR | Redeem proof reuse via ambiguous script boundaries | On-chain mitigation: every queued `btc_script` must be a standard scriptPubKey (P2PKH/P2SH/P2WPKH/P2WSH/P2TR), collapsing the re-partitioning space so a replayed proof cannot decode to an attacker-spendable fragment (e.g. bare `OP_TRUE`). See "Residual / coordination" for the full fix. | `bitcoin.move`, `redemption.move` |
| 7 | MEDIUM | Missing Median Time Past validation | Non-regtest headers must have `timestamp` strictly greater than the median of the previous 11 block timestamps; window seeded from the parent chain and slid forward across the batch. | `btc_light_client.move` |
| 8 | MEDIUM | Pool-bricking deposit-config (no fee viability) | `propose_deposit_config_update` now rejects configs where `max_deposit_sats` cannot clear `protocol_fee + service_fee_sats`, so the advertised range is always at least partially depositable. | `pool.move` |
| 10 | MEDIUM | Any pool can bind an existing `TokenRegistry` | `TokenRegistry` records its `owner_pool` on first use; all registry operations require the same pool, enforcing strict 1:1 binding. | `token_registry.move` |
| 12 | MEDIUM | Unbounded nullifier vector growth / O(n) scan | `NullifierRegistry.spent` migrated from inline `vector` to `Table` (dynamic-field storage): no object-size ceiling, O(1) membership. | `nullifier.move` |
| 16 | MINOR | Late tree-full gas burn | `transact`/`unshield`/`redeem` reject a full tree **before** Groth16 verification when tree outputs will be inserted. | `transact.move`, `token_registry.move`, `redemption.move` |
| 39 | DISC | Missing `tx_index` validation for single-tx blocks | `verify_tx_inclusion` now asserts `tx_index == 0` on the empty-proof (coinbase-only) path. | `btc_light_client.move` |

### Findings resolved as a side effect of the above
- **#5** (deposit tag invalid on rotation) — fixed by the pool-only OP_RETURN tag (#0).
- **#11** (missing queue-to-pool auth in `approve_signing`) — fixed by the queue binding (#3).
- **#15** (pool-local redemption IDs collide in a shared queue) — prevented: each pool binds exactly one queue, so cross-pool sharing of a queue is no longer reachable (#3).

---

## #4 + #51–54 bound-params hashing — FIXED (Sui-scoped, circuit untouched)

`boundParamsHash` is a free circuit *input* (the circuit never decomposes the scripts —
`msgHash = Poseidon(merkleRoot, boundParamsHash, …)`), so the encoding is enforced on-chain
and recomputed by the prover/SDK. **No circuit change and no VK regen.** The Sui encoding
already diverged from Solana's, so the fix was scoped to Sui only (shared SDK helpers + the
Solana program left untouched).

- **Move** (`bound_params.move`): `redeem_hash` (scripts), `stealth_data_hash`, and
  `unshield_hash` (recipients) now bind each list with explicit boundaries via
  `length_prefixed_hash` = `sha256(u32_le(count) || for each [ u32_le(len) || bytes ])`. Two
  distinct partitions of the same concatenated bytes can no longer collide → defeats the
  redeem proof-replay / script-substitution attack (#4/#53) and the stealth/recipient
  ambiguity (#51/#52/#54). The standard-scriptPubKey check stays as defense-in-depth.
- **SDK** (`sdk/packages/sdk/src/bound-params.ts`): added Sui-specific
  `computeSui{Transfer,Unshield,Redeem}BoundParamsHash` + `computeSuiStealthDataHash` +
  `suiLengthPrefixedHash`, matching the Move encoding byte-for-byte. Shared/Solana helpers
  unchanged.
- **Cross-language lock** (Move ⟷ SDK), pinned vectors:
  - transfer (stealth=[72×0x11]) = `089f78cb…ff8ad9da`
  - unshield (recipients=[0xA11CE,0xB0B], stealth=[72×0x11]) = `25f18c98…e3d5f3a5`
  - redeem (scripts=[34×0x51], stealth=[]) = `2f145c70…b6ce3dbb`
  Locked in `token_registry_tests::unshield_hash_matches_sdk_vector`,
  `transact_tests::transfer_hash_matches_sdk_vector`, and
  `bound-params.test.ts > "Sui length-prefixed bound-params (Move parity)"` (+ a test proving
  `[AB]` and `[A,B]` now hash differently).

**Web — DONE.** The Sui hooks now build bound params with the new length-prefixed helpers:
- `web/src/hooks/sui/use-sui-transfer.ts` → `computeSuiTransferBoundParamsHash(stealthArrays)`
- `web/src/hooks/sui/use-sui-unshield.ts` → `computeSuiUnshieldBoundParamsHash([recipient], stealth)`
(The Solana hook `use-build-transfer-params.ts` is untouched — it keeps the flat encoding.)
`npx tsc --noEmit` in `web` is clean.

**Publish-coupling caveat:** `web` consumes `@utxopia/sdk` as a vendored GitHub snapshot
(`github:UTXOpia/utxopia-sdk#main`, served as raw source). To make local dev compile now, the
new SDK source (`bound-params.ts`, `taproot.ts`, the `index.ts` exports) was overlaid into
`web/node_modules/@utxopia/sdk/...`. That overlay is a stopgap — the durable step is to publish
the SDK changes to `utxopia-sdk#main` and re-install, after which the vendored copy is
authoritative again. `ops` needed no sync (its deposit-tag helper is inline; it doesn't use the
bound-params hashes).
- **Deposit OP_RETURN tag (#0/#5) — DONE, off-chain wired.** The on-chain tag is now
  `sha256("UTXOPIA_SUI" || bcs(pool_id))[0..8]` (pool-only, no tree). The off-chain derivation
  was added and locked to the on-chain value across three languages:
  - SDK: `computeSuiDepositPoolTag(poolObjectId)` in `sdk/packages/sdk/src/taproot.ts` (exported).
  - ops: `computeSuiDepositPoolTag` + `buildSuiDepositOpReturnContext(poolObjectId, btcNetwork)`
    in `ops/scripts/lib/deposit-op-return.ts` (computed inline so it works against the pinned
    vendored SDK without a republish; destinationChain = SUI = 2).
  - Cross-language lock test pins `sha256("UTXOPIA_SUI" || 0x01*32)[0..8] = bf020d6c8198041c`
    in both `btc_deposit_tests::pool_tag_matches_sdk_vector` (Move) and
    `taproot.test.ts > computeSuiDepositPoolTag` (SDK).

---

## Reviewed — no code change (design intent, off-chain, or unconfirmed)

- **#6** first-spendable-output heuristic, **#9** miner-fee reserve accounting, **#13** raw-ID
  UTXO-set binding, **#14** tree aliasing / cross-pool note reuse, **#50** cross-token nullifier
  namespace — these depend on circuit-level domain separation, off-chain operational invariants,
  or admin-only one-time setup. #14/#50 in particular hinge on whether the circuit binds a
  `pool_id`/token domain separator, which is out of scope for the Move layer alone.
- Remaining **info/discussion** items are largely admin-misconfiguration notes, defense-in-depth
  observations, or restatements of the above. They carry no standalone on-chain fix beyond what
  the structural changes already provide.

---

## New regression tests
- `btc_light_client_tests::i_verify_inclusion_odd_level_duplicate_accepted` (#2 accept path)
- `btc_light_client_tests::i_verify_inclusion_rejects_left_duplicate_forgery` (#2 forgery reject)
- `redemption_tests::abort_processing_releases_reserved_utxos` (#3 recovery)
- extended `pool_admin_tests::rotate_commitment_tree_rebinds_to_successor` to assert the
  rotated-out root is preserved (#0)
- `btc_light_client_tests::i_reorg_multi_batch_fork` updated to use a 3-confirmation depth so the
  legitimate recent-block reorg stays above the finalized boundary (#1).
