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
| [8282447](https://dune.com/queries/8282447) | legacy merkle input, hex amounts; superseded, do not use |

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
node derive.mjs --all                       # include system predeploys too
node derive.mjs --min-eth 0.0001            # apply a dust floor at derivation instead
node derive.mjs --exclude-plain-contracts   # drop non-Safe contracts; keeps EOAs and Safes
node derive.mjs --only-safes                # just the multisigs
```

Output is always `[{ address, amount }]` with `amount` as a **decimal wei string**. That is
the only shape the merkle pipeline accepts, and it feeds straight into
`merkle-distributor`'s `build-recipients.mjs` with no conversion.

## Handing off to the pipeline

```bash
cd ../merkle-distributor
yarn distribution ../chain-data-snapshot/eth-holders-snapshot.json --min-eth 0.0001
```

That writes `dist/distribution.json` (root, tokenTotal and every proof) plus
`dist/SUMMARY.txt` recording what the floor excluded. Four stages run, stopping at the
first inconsistency: validate, build the tree, re-verify every proof by an independent
implementation, then cross-check the result against the input.

The snapshot committed here is the **complete** holder record. Any dust floor is a
processing decision applied at this step, not baked into the data, which is why the filter
appears on the command line and in `SUMMARY.txt`.

`--expect-count` and `--expect-total` are the operator's guard against being handed the
wrong file:

```bash
yarn distribution eth-holders-snapshot.json --expect-count 27804 --expect-total 50964771522921970938
```

## This is rehearsal data

Everything here was built from the pre-shutdown Dune snapshot. The distribution that ships
will be built from Conduit's final post-shutdown export.

### Swapping in Conduit's export

The pipeline's only requirement is `[{address, amount}]` with decimal wei, so a file in
that shape drops straight in and nothing downstream changes:

```bash
cd ../merkle-distributor
yarn distribution ../chain-data-snapshot/<conduit-export>.json --min-eth 0.0001
```

If it arrives as CSV or with different field names, the adapter handles it without any
code change:

```bash
yarn distribution export.csv --address-column holder --amount-column balance_wei
yarn distribution export.json --amount-format hex     # only if amounts are 0x-prefixed
```

**Check this before the shutdown date is fixed: does Conduit's export already exclude the
OP-Stack system predeploys?**

`derive.mjs` excludes them here using the Dune-specific `is_system_address` field, which
Conduit's export will not have. The generic adapter only ever sees `{address, amount}`, so
it has no way to know `0x…0016` is not a person. In this snapshot those five addresses hold
**579.63 ETH** between them:

| Address | ETH | What it is |
| --- | --- | --- |
| `0x4200000000000000000000000000000000000016` | 557.3977 | `L2ToL1MessagePasser`, where withdrawal funds accumulate |
| `0x4200000000000000000000000000000000000006` | 10.8033 | `WrappedEther` (backs WETH holders, needs its own snapshot) |
| `0x420000000000000000000000000000000000001a` | 9.7427 | system predeploy |
| `0x4200000000000000000000000000000000000011` | 1.2554 | fee vault / system predeploy |
| `0x4200000000000000000000000000000000000019` | 0.4340 | system predeploy |

Feed a raw list in and those become claimants. The pipeline's funding check would fail the
run (the total exceeds what the proxy holds), so it cannot reach mainnet, but it fails late
and unclearly. Either have Conduit exclude them, or filter the export before handing it to
the pipeline.

Expect counts and totals to change with the real data, so update the guards:

```bash
yarn distribution <export> --min-eth 0.0001 --expect-count <N> --expect-total <WEI>
```

## Dune access

Only `fetch-snapshot.mjs` needs a key. Put `DUNE_API_KEY=` in `.env` (gitignored) or export
it. `derive.mjs` never touches the network.

Source queries: [8282318](https://dune.com/queries/8282318) (raw snapshot and
reconciliation), [8282885](https://dune.com/queries/8282885) (enriched).

## Removed

`build-merkle-input.mjs` used to live here. It is superseded by
`merkle-distributor/scripts/build-recipients.mjs`, which is generic across input shapes
and validates far harder. The old copy emitted the Uniswap `{address, earnings, reasons}`
format with hex amounts, which the pipeline now rejects: hex in a decimal field inflates a
value by ~4096x. `derive.mjs`'s `--format map` and `--format merkle` were dropped for the
same reason.
