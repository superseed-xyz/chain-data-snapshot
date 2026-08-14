# chain-data-snapshot

Holder data for the Superseed ETH distribution, and the scripts that produce it.

This is the **data** end of the pipeline. Tree building, proof generation and the contract
live in `merkle-distributor`; the claim interface lives in `eth-claim-portal`.

## Contents

| File | What it is |
| --- | --- |
| `eth-holders-snapshot.json` | **The claim set**, committed. 27,804 entries, 50.964771522921970938 ETH. |
| `derive.mjs` | Derives the claim set and every other view from the enriched snapshot. Offline. |
| `fetch-snapshot.mjs` | Pulls a snapshot from Dune. Needs `DUNE_API_KEY`. |
| `verify-balances.mjs` | Checks the ERC20 snapshot against the chain. Needs an archive RPC. |
| `queries/` | Every Dune query, verbatim. |

`eth-holders-enriched.json` and `erc20-holders-enriched.json` are **not** committed. Both
are rebuildable from public queries, and the pipeline consumes neither — it only ever
takes `{address, amount}`. Both carry Safe detail per holder, including the signer
addresses; see [Trust, but call `balanceOf`](#trust-but-call-balanceof) for how far to
trust a derived signer list.

Pin `--snapshot_block` when rebuilding the ETH view, or it runs at chain tip and
`derive.mjs` stops reproducing the committed claim set. The committed set is block
**30095249**:

```bash
node fetch-snapshot.mjs --enriched --execution <id-of-a-run-pinned-to-30095249>
```

## Rebuilding

```bash
DUNE_API_KEY=... node fetch-snapshot.mjs --enriched   # -> eth-holders-enriched.json
DUNE_API_KEY=... node fetch-snapshot.mjs --erc20      # -> erc20-holders-enriched.json
```

| Query | File | Contents |
| --- | --- | --- |
| [8282318](https://dune.com/queries/8282318) | `eth-holders-snapshot.sql` | raw holder snapshot and the L1/L2 reconciliation |
| [8282885](https://dune.com/queries/8282885) | `eth-holders-enriched.sql` | enriched snapshot (`--enriched`) |
| [8328129](https://dune.com/queries/8328129) | `erc20-holders-enriched.sql` | ERC20 holders (`--erc20`) |

A free Dune account is enough. For the claim set alone you need neither a key nor these
files — it is committed. See [`queries/README.md`](queries/README.md) for parameters and a
drift check.

## Producing the claim set

```bash
node derive.mjs --out eth-holders-snapshot.json
```

That reproduces the committed file byte-for-byte, which is the check that it has not
silently drifted:

```bash
node derive.mjs --out /tmp/check.json && diff /tmp/check.json eth-holders-snapshot.json
```

| Flag | Effect |
| --- | --- |
| `--all` | include the system predeploys |
| `--min-eth 0.0001` | apply a dust floor at derivation |
| `--exclude-plain-contracts` | drop non-Safe contracts; keeps EOAs and Safes |
| `--only-safes` | just the multisigs |

Output is always `[{address, amount}]` with `amount` a **decimal wei string** — the only
shape the merkle pipeline accepts, feeding `build-recipients.mjs` with no conversion.

## Handing off to the pipeline

```bash
cd ../merkle-distributor
yarn distribution ../chain-data-snapshot/eth-holders-snapshot.json --min-eth 0.0001 \
  --expect-count 27804 --expect-total 50964771522921970938
```

Writes `dist/distribution.json` (root, tokenTotal and every proof) plus `dist/SUMMARY.txt`
recording what the floor excluded. Four stages run, stopping at the first inconsistency:
validate, build the tree, re-verify every proof by an independent implementation, then
cross-check the result against the input.

The snapshot committed here is the **complete** holder record. Any dust floor is a
processing decision applied at this step, not baked into the data, which is why it appears
on the command line and in `SUMMARY.txt`. `--expect-count` and `--expect-total` are the
operator's guard against being handed the wrong file.

## This is rehearsal data

Everything here was built from the pre-shutdown Dune snapshot. The distribution that ships
will be built from Conduit's final post-shutdown export. That drops straight in, since the
pipeline's only requirement is `[{address, amount}]` with decimal wei:

```bash
yarn distribution <export>.json --min-eth 0.0001 --expect-count <N> --expect-total <WEI>
yarn distribution export.csv  --address-column holder --amount-column balance_wei
yarn distribution export.json --amount-format hex     # only if amounts are 0x-prefixed
```

**Check before the shutdown date is fixed: does Conduit's export already exclude the
OP-Stack system predeploys?** `derive.mjs` excludes them using Dune's `is_system_address`,
a field Conduit's export will not have, and the generic adapter only ever sees
`{address, amount}` — it cannot know `0x…0016` is not a person. These five hold
**579.63 ETH** between them:

| Address | ETH | What it is |
| --- | --- | --- |
| `0x4200000000000000000000000000000000000016` | 557.3977 | `L2ToL1MessagePasser`, where withdrawal funds accumulate |
| `0x4200000000000000000000000000000000000006` | 10.8033 | `WrappedEther` (backs WETH holders, see below) |
| `0x420000000000000000000000000000000000001a` | 9.7427 | system predeploy |
| `0x4200000000000000000000000000000000000011` | 1.2554 | fee vault / system predeploy |
| `0x4200000000000000000000000000000000000019` | 0.4340 | system predeploy |

Feed a raw list in and those become claimants. The funding check would fail the run — the
total exceeds what the proxy holds — so it cannot reach mainnet, but it fails late and
unclearly. Either have Conduit exclude them, or filter the export first.

## ERC20 holders

A different asset and a different question. The ETH snapshot answers "who gets paid"; this
one answers "who is holding what, and can they still sign for it".

```bash
DUNE_API_KEY=... node fetch-snapshot.mjs --erc20
node verify-balances.mjs --rpc <superseed-rpc-url>
```

Tokens ranked by USD value, each with its own holders. Amounts are exact decimal strings
in the token's own base units, so read `decimals` before comparing them:

```jsonc
{
  "snapshot_block": 30276524,
  "tokens": [{
    "symbol": "SUPR", "decimals": 18, "value_usd": 881167.10526316,
    "holder_count": 7008, "supply_reconciles": true,
    "holders": [
      { "address": "0xee64bc3f…", "amount": "9433092011038452525998726111",
        "account_type": "contract", "deployer": "0xca1c0881…" },
      { "address": "0x75f834f1…", "amount": "2468613402976407485041011",
        "account_type": "safe_multisig", "safe_threshold": 4, "signer_count": 7,
        "safe_signers": ["0x02c27cd4…", "0x432170f4…", "…"] }
    ]
  }]
}
```

Defaults to the top 50 tokens and top 500 holders per token; raise the query parameters
for more. This file feeds nobody — it is a triage artifact, not pipeline input, since the
merkle distributor only ever distributes native ETH.

### Why it does not use `tokens.transfers`

WETH at `0x42..06` emits **no** `Transfer` event when it mints or burns: 99,920 `Deposit`
and 69,947 `Withdrawal` events are invisible to a transfer-derived ledger. Dune's
`tokens.transfers` synthesises some of them inconsistently, netting WETH to *minus* 110.8
ETH and leaving a bogus +114.46 across whichever addresses survive a `> 0` filter. The
true figure is deposits minus withdrawals, 10.8033 ETH — exactly the native balance the
table above attributes to that predeploy.

So balances come from raw `Transfer` logs, with `Deposit`/`Withdrawal` flows added for
tokens that never express a mint or burn as a `Transfer` to or from `0x0`. Dune's
`tokens.supply_latest` is no cross-check either: it disagreed with `totalSupply()` on five
of the top eight tokens.

### Trust, but call `balanceOf`

Every balance in that file is derived from event logs, and events can lie. Run
`verify-balances.mjs` before acting on the numbers: it replays every holder row as
`balanceOf` at the snapshot block and every token as `totalSupply`, and exits non-zero on
any disagreement. At block 30276524 it was 4,148 exact of 4,149, all 50 supplies matching.

| Flag | Effect |
| --- | --- |
| `--rpc <url>` | archive RPC; or set `SUPERSEED_RPC_URL`. Reads at the snapshot block, not head |
| `--tokens N` | check only the top N tokens |
| `--ignore-token 0x…` | skip a token entirely |

Two known-bad cases, both the token's fault and neither fixable from log data:

- **YGD** (`0x0e63d339…`) emitted two mint `Transfer`s to `0x469e7e5b…` in block 11463173,
  50M and 500M, but credited only 500M. That holder reads 50M high forever. Pass
  `--ignore-token 0x0e63d339b9147bf1bc72f34e2a19761d8214622b` for a clean exit.
- **`supply_reconciles: false`** means a token's own ledger produced a negative balance,
  which is impossible on chain and so proves its event history is incomplete. `ionUSDC`
  and `ionWETH` currently trip it. Their positive balances still verified against the
  chain, but treat those two as unreliable rather than assuming the check was noise.

## Credentials

| Script | Needs |
| --- | --- |
| `fetch-snapshot.mjs` | `DUNE_API_KEY`, from the environment or `.env` |
| `verify-balances.mjs` | an archive RPC — `--rpc` or `SUPERSEED_RPC_URL`. Superseed is chain 5330 |
| `derive.mjs` | nothing; it never touches the network |

`.env` is gitignored. Keep keyed endpoints out of the repo.
