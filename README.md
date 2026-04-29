# hive-mcp-aml-screen

AML screening broker for the A2A network. Send an address and a chain. Receive a 0–100 observational risk score, an OFAC SDN match flag, and chain-heuristic categories. Cached for 24 hours.

> **Hive does not block, freeze, or settle.** This is observational AML data only. Customer is responsible for compliance decisions.

- **Sources** — daily-refreshed OFAC SDN list (treasury.gov), live Base mainnet RPC reads, conservative mixer-contract seed list
- **Scoring** — 0–100 with bands (`minimal`, `low`, `medium`, `high`, `critical`)
- **Pricing** — $0.03 per single address, $0.025 per address for bulk (10-address minimum), settled via x402 in USDC on Base
- **Cache** — 24 hours per `(chain, address)`
- **Mode** — inbound only, `ENABLE=true` by default

The shim is a broker. It returns observational data. It never blocks, freezes, or settles on behalf of a customer, and it never replaces a regulated KYC/AML provider.

## Endpoints

| Method | Path | Cost | Purpose |
| --- | --- | --- | --- |
| `POST` | `/v1/aml/screen` | $0.03 | Screen one address |
| `POST` | `/v1/aml/bulk` | $0.025/addr (min 10) | Screen many addresses in one call |
| `GET` | `/v1/aml/today` | free | UTC-day counters and OFAC list status |
| `GET` | `/health` | free | Liveness, OFAC list status, pricing |
| `POST` | `/mcp` | — | JSON-RPC 2.0 entry for MCP clients |
| `GET` | `/.well-known/mcp.json` | free | MCP descriptor |
| `POST` | `/v1/x402/submit` | — | Settle a 402 quote, mint an access token |

## MCP tools

| Tool | Cost | Description |
| --- | --- | --- |
| `aml_screen` | $0.03 | Single-address screening |
| `aml_bulk_screen` | $0.025/addr | Bulk screening, 10-address minimum |
| `aml_today` | free | Counters and OFAC list status |

Every response — JSON-RPC and REST alike — carries the disclaimer field:

```json
"disclaimer": "Hive does not block, freeze, or settle. This is observational AML data only. Customer is responsible for compliance decisions."
```

## Quickstart

```bash
curl -sX POST https://hive-mcp-aml-screen.onrender.com/v1/aml/screen \
  -H 'content-type: application/json' \
  -d '{"address":"0x8589427373d6d84e98730d7795d8f6f8731fda16","chain":"base"}'
```

The first call returns a 402 envelope with a quote. Settle on Base in USDC, then resubmit the proof to `/v1/x402/submit` to mint an access token, and replay the request with `X-Hive-Access: <token>`.

```bash
curl -sX POST https://hive-mcp-aml-screen.onrender.com/v1/x402/submit \
  -H 'content-type: application/json' \
  -d '{"nonce":"...","payer":"0x...","chain":"base","tx_hash":"0x..."}'
```

## Response shape

```json
{
  "ok": true,
  "address": "0x8589427373d6d84e98730d7795d8f6f8731fda16",
  "chain": "base",
  "risk_score": 100,
  "risk_band": "critical",
  "flags": [
    {"category": "ofac_sdn_match", "severity": "critical", "detail": "OFAC SDN list match: program=CYBER2 sdn_uid=12345"},
    {"category": "mixer_contract", "severity": "high", "detail": "address is a known mixer/sanctioned-protocol contract"}
  ],
  "sdn_match": true,
  "sdn_record": {"sdn_uid": "12345", "sdn_name": "TORNADO CASH", "program": "CYBER2"},
  "chain_detail": {"nonce": 0, "is_contract": true, "balance_wei": "0", "head_block": 12345678},
  "sources": {
    "ofac_sdn": {"list_size": 8421, "last_refresh_ms": 1745798400000},
    "heuristics": {"chain": "base", "version": "v1"}
  },
  "cache_hit": false,
  "cache_ttl_seconds": 86400,
  "screened_at": 1745875200000,
  "screening_id": "8a3f...",
  "disclaimer": "Hive does not block, freeze, or settle. This is observational AML data only. Customer is responsible for compliance decisions."
}
```

## Heuristics

For EVM chains the shim performs four real Base RPC reads — `getTransactionCount`, `getCode`, `getBalance`, `getBlockNumber` — plus a binary search over historical blocks to estimate the wallet's earliest activity. Categories returned in `flags`:

| Category | Severity | Trigger |
| --- | --- | --- |
| `ofac_sdn_match` | critical | Address appears in the daily OFAC SDN list |
| `mixer_contract` | high | Address is a known mixer/sanctioned-protocol contract |
| `very_new_wallet` | medium | First on-chain activity within 24 hours |
| `high_velocity` | medium | ≥ 20 outbound tx per hour over wallet lifetime |
| `mixer_adjacent_balance` | low | Balance is exactly 0.1 / 1 / 10 / 100 ETH (Tornado pool denominations) |
| `no_outbound_history` | low | Address has never sent a transaction on this chain |
| `rpc_unavailable` | low | RPC read failed; SDN-only signal returned |
| `heuristic_error` | low | Internal heuristic error; SDN-only signal returned |

Non-EVM chains return the SDN match signal only with a `note` in `chain_detail`.

## Configuration

| Env | Default | Purpose |
| --- | --- | --- |
| `PORT` | `3000` | HTTP port |
| `ENABLE` | `true` | Master switch. Set `false` to short-circuit all paid endpoints with `503` |
| `WALLET_ADDRESS` | `0x15184bf50b3d3f52b60434f8942b7d52f2eb436e` | x402 settlement recipient (W1 MONROE) |
| `BASE_RPC_URL` | `https://mainnet.base.org` | Base mainnet RPC for chain heuristics |
| `OFAC_SDN_URL` | `https://www.treasury.gov/ofac/downloads/sdn.csv` | Source URL for the SDN list |
| `DB_PATH` | `/tmp/aml.db` | SQLite database file |
| `MIXER_ADDRESSES` | _(empty)_ | Comma-separated list of extra mixer contract addresses to flag |
| `X402_BYPASS` | _(unset)_ | Set to any value to bypass payment in development |

## Persistence

SQLite at `/tmp/aml.db` with WAL journaling.

- `ofac_sdn` — `(address PK, sdn_uid, sdn_name, program, list_type, inserted_at)` — wiped and re-inserted on each refresh
- `ofac_meta` — refresh timestamp, count, byte size, last error
- `screenings` — every screen call, billed or cached
- `cache` — `(chain:address) → JSON payload`, 24-hour TTL

## Operational notes

- The OFAC list is refreshed at boot and every 24 hours thereafter
- Cache entries are pruned hourly
- Body limit is 256 KB on JSON requests
- Inbound only — the shim never initiates outbound calls beyond the OFAC fetch and Base RPC reads

## License

MIT — see [LICENSE](LICENSE).

## Hive Civilization Directory

Part of the Hive Civilization — agent-native financial infrastructure.

- Endpoint Directory: https://thehiveryiq.com
- Live Leaderboard: https://hive-a2amev.onrender.com/leaderboard
- Revenue Dashboard: https://hivemine-dashboard.onrender.com
- Other MCP Servers: https://github.com/srotzin?tab=repositories&q=hive-mcp

Brand: #C08D23
<!-- /hive-footer -->
