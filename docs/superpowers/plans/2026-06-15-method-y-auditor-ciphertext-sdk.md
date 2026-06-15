# Method-Y Auditor Ciphertext (SDK) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** Let a permissioned-pool auditor decrypt every note in the pool from on-chain data alone, without holding any participant's key — by having the depositor SDK encrypt a copy of each note's viewing data (`tokenId`, `amount`) to the auditor's viewing public key via ECDH, and extending `auditor.ts` to decrypt those blobs.

**Architecture:** Hybrid of two existing schemes in `packages/sdk/src`: X25519 ECDH key-agreement (from the recipient note-encryption path, `crypto-ed25519.ts`) + XChaCha20-Poly1305 AEAD envelope with AAD binding (from `sender-memo.ts`). The depositor uses a fresh ephemeral X25519 keypair against the auditor's (Ed25519→X25519) viewing pubkey; the ephemeral public key travels in the blob so decryption is self-contained. **No on-chain changes** — the Solana program (`EVENT_AUDITOR_CIPHERTEXT` 0x16) and Sui (`auditor_ciphertext: vector<u8>`) already carry the opaque blob; this plan only fills/reads it.

**Tech stack:** TypeScript, `@noble/ciphers/chacha` (xchacha20poly1305), `@noble/hashes/sha256`, existing `crypto-ed25519.ts` helpers (`ed25519PubToX25519`, `x25519Ecdh`, `ed25519GenerateKeyPair`). Repo: **`utxopia/sdk`** (branch off `origin/main`). Tests: `bun test`.

**Spec:** `utxopia-sui-programs/docs/superpowers/specs/2026-06-15-permissioned-pool-design.md` §2 (Method-Y).

---

## Crypto design (locked)

- **Key agreement:** depositor generates a fresh ephemeral X25519 keypair `(eph_priv, eph_pub)`. `auditor_x = ed25519PubToX25519(auditor_viewing_pubkey)`. `shared = x25519Ecdh(eph_priv, auditor_x)`.
- **Symmetric key:** `k = sha256(concat(shared, utf8("utxopia.auditor-ciphertext.v1")))` (domain-separated, matches the SDK's SHA256-KDF idiom).
- **AEAD:** `xchacha20poly1305(k, nonce).encrypt(plaintext, aad)`.
  - `plaintext` (40 bytes) = `tokenId` (32 BE) || `amount` (8 LE) — same layout as note/sender-memo.
  - `aad` (32 bytes) = `commitment` (the SDK knows it pre-submission; do NOT use leafIndex — unknown until execution).
  - `nonce` = 24 random bytes.
- **Auditor decrypt:** `auditor_x_priv = ed25519PrivToX25519(auditor_viewing_priv)` (add helper if missing — Ed25519 scalar → X25519, mirroring the pub map); `shared = x25519Ecdh(auditor_x_priv, eph_pub)`; same `k`; `xchacha20poly1305(k, nonce).decrypt(ct, aad)`. Returns `null` on tag failure.
- **Wire blob (88 bytes), opaque to chain:** `eph_pub(32) || nonce(24) || ciphertextWithTag(32)` where ciphertextWithTag = 40 plaintext encrypted under XChaCha20-Poly1305? NO — XChaCha20-Poly1305 ciphertext length = plaintext(40) + tag(16) = 56. So blob = `eph_pub(32) || nonce(24) || ctWithTag(56)` = **112 bytes**. `commitment` is NOT in the blob (it's the AAD, supplied at decrypt time from the paired announcement/event).

---

### Task 1: ECDH auditor-ciphertext crypto module

**Files:**
- Create: `packages/sdk/src/auditor-ciphertext.ts`
- Test: `packages/sdk/test/unit/auditor-ciphertext.test.ts`
- Possibly modify: `packages/sdk/src/crypto-ed25519.ts` (add `ed25519PrivToX25519` if absent)

- [ ] **Step 1: Write the failing round-trip + negative tests** in `auditor-ciphertext.test.ts`:

```ts
import { describe, it, expect } from "bun:test";
import { ed25519GenerateKeyPair } from "../../src/crypto-ed25519";
import { encryptAuditorCiphertext, decryptAuditorCiphertext } from "../../src/auditor-ciphertext";

const ZKBTC = 0x7a627463n;
function fakeCommitment(b = 0xAB) { return new Uint8Array(32).fill(b); }

describe("Method-Y auditor ciphertext (ECDH + XChaCha20-Poly1305)", () => {
  it("roundtrips tokenId+amount encrypted to the auditor viewing pubkey", () => {
    const auditor = ed25519GenerateKeyPair();
    const commitment = fakeCommitment();
    const blob = encryptAuditorCiphertext(auditor.pubKey, { tokenId: ZKBTC, amount: 12_345n }, commitment);
    expect(blob.length).toBe(112);
    const plain = decryptAuditorCiphertext(auditor.privKey, blob, commitment);
    expect(plain).not.toBeNull();
    expect(plain!.tokenId).toBe(ZKBTC);
    expect(plain!.amount).toBe(12_345n);
  });
  it("returns null for the wrong auditor key", () => {
    const auditor = ed25519GenerateKeyPair();
    const wrong = ed25519GenerateKeyPair();
    const c = fakeCommitment();
    const blob = encryptAuditorCiphertext(auditor.pubKey, { tokenId: ZKBTC, amount: 1n }, c);
    expect(decryptAuditorCiphertext(wrong.privKey, blob, c)).toBeNull();
  });
  it("returns null when the commitment (AAD) doesn't match", () => {
    const auditor = ed25519GenerateKeyPair();
    const blob = encryptAuditorCiphertext(auditor.pubKey, { tokenId: ZKBTC, amount: 1n }, fakeCommitment(0x01));
    expect(decryptAuditorCiphertext(auditor.privKey, blob, fakeCommitment(0x02))).toBeNull();
  });
});
```

- [ ] **Step 2: Run → fail** (`bun test packages/sdk/test/unit/auditor-ciphertext.test.ts`) — module/fns missing.

- [ ] **Step 3: Implement `auditor-ciphertext.ts`.** Read `crypto-ed25519.ts` for the exact signatures of `ed25519PubToX25519`, `x25519Ecdh`, and the keypair shape; read `sender-memo.ts` for the `xchacha20poly1305` import + encrypt/decrypt idiom. Implement:

```ts
import { xchacha20poly1305 } from "@noble/ciphers/chacha";
import { sha256 } from "@noble/hashes/sha256";
import { randomBytes } from "@noble/hashes/utils";
import { ed25519PubToX25519, ed25519PrivToX25519, x25519Ecdh } from "./crypto-ed25519";

const DOMAIN = new TextEncoder().encode("utxopia.auditor-ciphertext.v1");
export interface AuditorNotePlain { tokenId: bigint; amount: bigint; }

function deriveKey(shared: Uint8Array): Uint8Array {
  const buf = new Uint8Array(shared.length + DOMAIN.length);
  buf.set(shared, 0); buf.set(DOMAIN, shared.length);
  return sha256(buf);
}
function encodePlain(p: AuditorNotePlain): Uint8Array {
  const out = new Uint8Array(40);
  // tokenId 32 BE
  let t = p.tokenId; for (let i = 31; i >= 0; i--) { out[i] = Number(t & 0xffn); t >>= 8n; }
  // amount 8 LE
  let a = p.amount; for (let i = 0; i < 8; i++) { out[32 + i] = Number(a & 0xffn); a >>= 8n; }
  return out;
}
function decodePlain(b: Uint8Array): AuditorNotePlain {
  let t = 0n; for (let i = 0; i < 32; i++) t = (t << 8n) | BigInt(b[i]);
  let a = 0n; for (let i = 7; i >= 0; i--) a = (a << 8n) | BigInt(b[32 + i]);
  return { tokenId: t, amount: a };
}

/** Encrypt a note's viewing data to the auditor's Ed25519 viewing pubkey. Returns
 *  the 112-byte blob: eph_pub(32) || nonce(24) || ctWithTag(56). */
export function encryptAuditorCiphertext(
  auditorViewingPubKey: Uint8Array, // Ed25519, 32B (the on-chain auditor_viewing_pubkey)
  plain: AuditorNotePlain,
  commitment: Uint8Array,           // 32B, the note commitment (AAD)
  ephemeralPriv?: Uint8Array,       // test override; else random
): Uint8Array {
  const eph_priv = ephemeralPriv ?? randomBytes(32);
  // derive X25519 eph pub from eph priv via the X25519 base mul the SDK uses (see crypto-ed25519)
  const { x25519PubFromPriv } = require("./crypto-ed25519"); // or import directly; use the SDK's helper
  const eph_pub = x25519PubFromPriv(eph_priv);
  const auditor_x = ed25519PubToX25519(auditorViewingPubKey);
  const shared = x25519Ecdh(eph_priv, auditor_x);
  const key = deriveKey(shared);
  const nonce = randomBytes(24);
  const ct = xchacha20poly1305(key, nonce, commitment).encrypt(encodePlain(plain));
  const blob = new Uint8Array(32 + 24 + ct.length);
  blob.set(eph_pub, 0); blob.set(nonce, 32); blob.set(ct, 56);
  return blob;
}

/** Auditor-side decrypt. Returns null on tag/AAD/key mismatch. */
export function decryptAuditorCiphertext(
  auditorViewingPrivKey: Uint8Array, // Ed25519, 32B (auditor holds)
  blob: Uint8Array,
  commitment: Uint8Array,
): AuditorNotePlain | null {
  if (blob.length !== 112) return null;
  const eph_pub = blob.slice(0, 32), nonce = blob.slice(32, 56), ct = blob.slice(56);
  const auditor_x_priv = ed25519PrivToX25519(auditorViewingPrivKey);
  const shared = x25519Ecdh(auditor_x_priv, eph_pub);
  const key = deriveKey(shared);
  try {
    const pt = xchacha20poly1305(key, nonce, commitment).decrypt(ct);
    return decodePlain(pt);
  } catch { return null; }
}
```

IMPORTANT for the implementer: use the SDK's ACTUAL X25519 helpers. Confirm the exact names for "X25519 pub from priv" and "Ed25519 priv → X25519 scalar" in `crypto-ed25519.ts`. If `ed25519PrivToX25519` / `x25519PubFromPriv` don't exist, add them next to `ed25519PubToX25519`/`x25519Ecdh` using `@noble/curves` `x25519.getPublicKey` and the standard Ed25519→X25519 clamped-scalar derivation (the SDK already does the pub-key map; mirror it for the private side). Replace the `require` with a proper top-of-file import.

- [ ] **Step 4: Run → pass.** Fix until all 3 tests pass. (The blob is 112 bytes; assert that.)

- [ ] **Step 5: Commit** `git add packages/sdk/src/auditor-ciphertext.ts packages/sdk/src/crypto-ed25519.ts packages/sdk/test/unit/auditor-ciphertext.test.ts && git commit -m "sdk: Method-Y auditor ciphertext (ECDH encrypt-to-auditor + decrypt)"`

---

### Task 2: Auditor viewing keypair helpers

**Files:** Modify `packages/sdk/src/keys.ts` (or `auditor.ts`); Test: extend `auditor-ciphertext.test.ts`.

- [ ] **Step 1:** Read `keys.ts` for `DelegatedViewKey` and existing keygen (`ed25519GenerateKeyPair`, `ed25519DeriveKeyFromSeed` in `crypto-ed25519.ts`).
- [ ] **Step 2: Add** `generateAuditorViewingKeypair(): { privKey: Uint8Array; pubKey: Uint8Array }` and `deriveAuditorViewingKeypair(seed: Uint8Array)` thin wrappers over the existing Ed25519 keygen, exported from `keys.ts` and `index.ts`. The `pubKey` is what goes on-chain as `auditor_viewing_pubkey` (Sui `set_auditor_viewing_pubkey` / Solana `setAuditorViewingPubkey`).
- [ ] **Step 3: Test** the keypair generate/derive determinism; commit `sdk: auditor viewing keypair helpers`.

---

### Task 3: Event parsing for the auditor ciphertext blob

**Files:** Modify `packages/sdk/src/events.ts`, `packages/sdk/src/event-client.ts` (Solana); note Sui side reads the `auditor_ciphertext` event field via the Sui event client.

- [ ] **Step 1:** Read `events.ts` (the `EVENT_*` discriminants + parse fns) and how `announcement-client.ts`/`event-client.ts` surface them.
- [ ] **Step 2: Add** `EVENT_AUDITOR_CIPHERTEXT = 0x16` const + `interface AuditorCiphertextEvent { type: "auditor_ciphertext"; commitment: Uint8Array; blob: Uint8Array }` + `parseAuditorCiphertextEvent(segments)` — Solana `sol_log_data` layout `[disc(1)] [commitment(32)] [blob(112)]` (the program emits `[disc, commitment, ciphertext]`). Validate lengths; return null otherwise. Mirror an existing parse fn exactly (e.g. the sender-memo parser).
- [ ] **Step 3:** For Sui, add a small reader that pulls `auditor_ciphertext` (and the `commitment`/`note` fields) out of the `BtcDepositVerified`/`StealthAnnounced` event JSON in the Sui event client, producing the same `{ commitment, blob }` shape. (Read how the Sui event client parses existing event fields.)
- [ ] **Step 4: Test** a parse round-trip from a synthetic log/segment set; commit `sdk: parse auditor-ciphertext events (Solana 0x16 + Sui field)`.

---

### Task 4: `auditor.ts` integration

**Files:** Modify `packages/sdk/src/auditor.ts`; Test: extend `test/unit/auditor.test.ts`.

- [ ] **Step 1:** Read `auditor.ts` `auditScan`, `AuditScanOptions`, `AuditRecord`, `AuditDirection`, and the existing sender-memo processing loop (~lines 217-249).
- [ ] **Step 2: Extend** `AuditScanOptions` with `auditorCiphertexts?: ReadonlyArray<{ commitment: Uint8Array; blob: Uint8Array; slot?: number; blockTime?: number }>` and add `"AUDITOR_VISIBLE"` to `AuditDirection`. The auditor's key for decryption is its viewing PRIVATE key — accept it on the scan (extend `DelegatedViewKey` usage or add an `auditorViewingPrivKey` option; the auditor holds this, distinct from any user key).
- [ ] **Step 3: Add the decrypt loop** mirroring the sender-memo loop: for each `auditorCiphertexts` entry within the slot range, `const p = decryptAuditorCiphertext(auditorViewingPrivKey, blob, commitment)`; on success push an `AuditRecord { direction: "AUDITOR_VISIBLE", tokenId: p.tokenId, amount: p.amount, commitment, slot, blockTime }`. Skip (don't throw) on null.
- [ ] **Step 4: Test** in `auditor.test.ts`: produce 2 auditor ciphertexts with `encryptAuditorCiphertext` for an auditor keypair, feed them to `auditScan` via `auditorCiphertexts`, assert two `AUDITOR_VISIBLE` records with the right amounts; assert a wrong-key scan yields none. Commit `sdk: auditor.ts decrypts Method-Y auditor ciphertexts`.

---

### Task 5: Populate the blob in the permissioned builders

**Files:** Modify `packages/sdk/src/instructions.ts` (Solana) and `packages/sdk-sui/src/sui-adapter.ts` (Sui), plus a convenience helper.

- [ ] **Step 1: Add** `buildAuditorCiphertextForNote({ auditorViewingPubKey, tokenId, amount, commitment })` (thin wrapper over `encryptAuditorCiphertext`) exported from the SDK, so callers compute the blob from the pool's on-chain `auditor_viewing_pubkey` + the note they're depositing.
- [ ] **Step 2:** The permissioned builders already accept `auditorCiphertext: Uint8Array`. Add doc + an optional convenience overload/param on `shieldPermissioned`/`completeDepositPermissioned` (both chains) that, given `auditorViewingPubKey`, computes the blob internally via Task-1 helper (so callers don't have to). Keep the raw-bytes path for advanced callers.
- [ ] **Step 3:** Typecheck both packages (the commands used previously: `packages/sdk` `bun run build`; `sdk-sui` `bunx tsc --noEmit --skipLibCheck ... src/sui-adapter.ts`). Commit `sdk: compute Method-Y auditor ciphertext in permissioned builders`.

---

### Task 6: End-to-end round-trip test + docs

- [ ] **Step 1:** A single integration-style test: build a note → `buildAuditorCiphertextForNote` → simulate the on-chain emit (commitment + blob) → `parseAuditorCiphertextEvent` → `auditScan` with the auditor priv key → assert the `AUDITOR_VISIBLE` record matches the original `{tokenId, amount}`. This proves the full encode→carry→parse→decrypt path.
- [ ] **Step 2:** Update the spec §2 (Method-Y) to record the final wire format (112-byte blob: eph_pub‖nonce‖ctWithTag; AAD=commitment; domain `utxopia.auditor-ciphertext.v1`) and that it's SDK-only (no contract change). Commit.

---

## Notes / correctness constraints
- **ECDH, not symmetric:** the depositor does NOT know the auditor's private key, so the key MUST come from `ECDH(ephemeral_priv, auditor_pub)`. Do not derive it from a private key the depositor doesn't have.
- **AAD = commitment only.** The leaf index is assigned on-chain at execution and is unknown when the SDK builds the instruction; binding to it is impossible. The commitment is known pre-submission and uniquely identifies the note.
- **No contract changes.** Solana `EVENT_AUDITOR_CIPHERTEXT` (0x16) and Sui `auditor_ciphertext: vector<u8>` already carry the opaque blob; the program never parses it. This plan is entirely in `utxopia/sdk`.
- **Curve:** match the existing viewing-key curve (Ed25519 keys, X25519 ECDH). Reuse `crypto-ed25519.ts` helpers; add `ed25519PrivToX25519`/`x25519PubFromPriv` only if missing.
- **Forward secrecy / replay:** a fresh ephemeral per note + fresh nonce; AAD-commitment binding prevents moving a blob to a different note.
