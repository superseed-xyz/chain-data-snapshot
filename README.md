# chain-data-snapshot

Holder data for the Superseed ETH distribution, and the scripts that produce it.

This is the **data** end of the pipeline. Tree building, proof generation and the contract
live in `merkle-distributor`; the claim interface lives in `eth-claim-portal`.

## Contents

| File | What it is |
| --- | --- |
| `eth-holders-snapshot.json` | **The claim set.** Every holder, dust included: 27,804 entries, 50.964771522921970938 ETH. This is what the distribution is built from. |
| `derive.mjs` | Derives the claim set from the enriched snapshot. Offline, no API key. |
| `fetch-snapshot.mjs` | Rebuilds the enriched snapshot from Dune. Needs an API key. |

### Why the enriched snapshot is not committed

`eth-holders-enriched.json` is a pre-joined view of 27,809 holders carrying account type,
Safe threshold and owner counts, deployer links, bytecode size and activity windows. Every
field is public chain data, but the joined file is a convenient profiling artifact that the
distribution does not need: the pipeline only ever consumes `{address, amount}`.

So it is rebuildable rather than published. Nothing about verification depends on us
hosting it, because the underlying queries are public.

## Rebuilding the enriched view

```bash
DUNE_API_KEY=... node fetch-snapshot.mjs --enriched     # -> eth-holders-enriched.json
```

Source queries, all public:

| Query | Contents |
| --- | --- |
| [8282318](https://dune.com/queries/8282318) | raw holder snapshot and the L1/L2 reconciliation |
| [8282885](https://dune.com/queries/8282885) | enriched snapshot (what `--enriched` pulls) |
| [8282447](https://dune.com/queries/8282447) | legacy merkle input, hex amounts — superseded, do not use |

A free Dune account is enough. If you only want the claim set, you need neither the key nor
the enriched file: `eth-holders-snapshot.json` is committed.

## Producing the claim set

With the enriched file present:

```bash
node derive.mjs --out eth-holders-snapshot.json
```

That reproduces the committed file byte-for-byte, which is the check that the snapshot has
not silently drifted:

```bash
node derive.mjs --out /tmp/check.json && diff /tmp/check.json eth-holders-snapshot.json
```

Other views:

```bash
node derive.mjs --all                 # include system addresses too
node derive.mjs --min-eth 0.0001      # apply a dust floor (NOT used for the shipped set)
node derive.mjs --exclude-contracts   # EOAs and Safes only
node derive.mjs --only-safes          # just the multisigs
```

Output is always `[{ address, amount }]` with `amount` as a **decimal wei string**. That is
the only shape the merkle pipeline accepts, and it feeds straight into
`merkle-distributor`'s `build-merkle-input.mjs` with no conversion.

## Handing off to the pipeline

```bash
cd ../merkle-distributor
yarn pipeline ../chain-data-snapshot/eth-holders-snapshot.json \
  --expect-count 27804 --expect-total 50964771522921970938
```

`--expect-*` are the operator's guard against being handed the wrong file. The pipeline
then validates, builds the tree, re-verifies every proof independently, and cross-checks
the result against the input.

## This is rehearsal data

Everything here was built from the pre-shutdown Dune snapshot. The distribution that ships
will be built from Conduit's final post-shutdown export. When it arrives, it only has to
reach `[{address, amount}]` with decimal wei; the rest of the pipeline is unchanged.

## Dune access

Only `fetch-snapshot.mjs` needs a key. Put `DUNE_API_KEY=` in `.env` (gitignored) or export
it. `derive.mjs` never touches the network.

Source queries: [8282318](https://dune.com/queries/8282318) (raw snapshot and
reconciliation), [8282885](https://dune.com/queries/8282885) (enriched).

## Removed

`build-merkle-input.mjs` used to live here. It is superseded by
`merkle-distributor/scripts/build-merkle-input.mjs`, which is generic across input shapes
and validates far harder. The old copy emitted the Uniswap `{address, earnings, reasons}`
format with hex amounts, which the pipeline now rejects: hex in a decimal field inflates a
value by ~4096x. `derive.mjs`'s `--format map` and `--format merkle` were dropped for the
same reason.
