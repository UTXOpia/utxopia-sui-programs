# Sui regtest faucet — making it work on app.utxopia.com

The web faucet route (`web/src/app/api/faucet/regtest/route.ts`) computes the BTC
deposit address + compact OP_RETURN in the SDK (no Docker needed). On Vercel it
**forwards** `{ address, amountSats, opReturn }` to
`${REGTEST_FAUCET_BACKEND_URL}/api/faucet/regtest` with an `X-API-Key` header.

Vercel can't reach the local regtest node or run the relay, so `faucet-server.ts`
implements that endpoint on the machine that has them. It broadcasts the deposit +
mines, then runs `relay-deposit.ts` to SPV-verify and `complete_deposit` on Sui.

No web code change is required — only env wiring.

## 1. Run the relay service (on the machine with the regtest node + Sui key)

```bash
cd sui-programs
FAUCET_API_KEY='<long-random-secret>' \
ESPLORA_URL='http://localhost:3002/regtest/api' \
UTXOPIA_SUI_RPC_URL='https://fullnode.testnet.sui.io:443' \
bun run faucet:serve            # listens on :8790 (FAUCET_PORT to override)
```

Health check: `curl localhost:8790/health` → `{"ok":true,...}`.
Keep it running (pm2 / launchd / `nohup … &`). It only works while the regtest
node (`utxopia-esplora-regtest`) is up and the Sui relayer key has gas.

## 2. Cloudflare tunnel ingress (dashboard — the part only you can do)

The tunnel is token-managed, so add this in the Cloudflare Zero Trust dashboard
(Networks → Tunnels → the existing tunnel → Public Hostname):

- **Hostname:** `faucet.utxopia.com`
- **Service:** `http://host.docker.internal:8790`
  (the `utxopia-cloudflared` container reaches the host service this way on Docker
  Desktop; if you instead containerize the faucet on `utxopia-ops_default`, use
  `http://faucet-svc:8790`)

Then add the matching DNS (CNAME `faucet` → the tunnel) if the dashboard doesn't.

## 3. Vercel env (Production)

```
REGTEST_FAUCET_BACKEND_URL = https://faucet.utxopia.com
BACKEND_API_KEY            = <the same secret as FAUCET_API_KEY>
```

`BACKEND_API_KEY` is what `applyBackendAuthHeaders` sends as `X-API-Key`; the
service rejects requests whose key doesn't match. Redeploy the web app after
setting them.

## 4. Verify end-to-end

On app.utxopia.com (chain = Sui, network = sui-regtest), open the faucet, paste
your `utxo:…` stealth address, and airdrop. The note should appear in
`/vault/activity` within a refresh once `relay-deposit.ts` lands the Sui
`complete_deposit` (auto-advances the light client to the deposit's block).

## Notes / limits

- Quota + validation are enforced on the Vercel side before forwarding; the
  service additionally requires the API key.
- The deposit note is encrypted to the stealth address in the request, so it only
  shows in the history of the vault that owns that identity.
- This is a regtest faucet — it is inherently tied to the local regtest chain.
