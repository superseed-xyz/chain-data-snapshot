# queries

The Dune SQL behind every snapshot in this repository, committed verbatim so the
data can be audited from source rather than taken on trust. The files are exact
copies of the saved queries — no local edits, so a diff against Dune is meaningful.

| File | Query | What it produces |
| --- | --- | --- |
| `eth-holders-snapshot.sql` | [8282318](https://dune.com/queries/8282318) | Native ETH balances rebuilt from traces, gas and deposits, plus the L1/L2 reconciliation. |
| `eth-holders-enriched.sql` | [8282885](https://dune.com/queries/8282885) | The same ledger with per-address context. `fetch-snapshot.mjs --enriched`. |
| `erc20-holders-enriched.sql` | [8328129](https://dune.com/queries/8328129) | ERC20 holders by token, with Safe signers. `fetch-snapshot.mjs --erc20`. |

All three are public and take `snapshot_block`; the ETH queries also take
`min_balance_eth`, and the ERC20 query takes `top_tokens` and `holders_per_token`.
Defaults resolve to chain tip with no floor.

## The one that is not here

Dune query [8282447](https://dune.com/queries/8282447), "ETH Snapshot → Merkle
Distributor Input", is deliberately not committed. It emitted the old Uniswap
`{address, earnings, reasons}` shape with **hex** `earnings`, which
`merkle-distributor` now rejects: hex in a field parsed as decimal inflates a value by
~4096x. Its ledger was identical to `eth-holders-snapshot.sql`, so it added nothing
but a dangerous encoding.

There is no merkle-input query any more. The claim set is derived offline:

```bash
node derive.mjs --out eth-holders-snapshot.json
```

## Checking these files still match Dune

Nothing enforces that a query edited on Dune gets copied back here. To check for
drift, with `DUNE_API_KEY` set:

```bash
for q in 8282318:eth-holders-snapshot 8282885:eth-holders-enriched \
         8328129:erc20-holders-enriched; do
  id=${q%%:*}; f=${q#*:}
  curl -s -H "X-Dune-API-Key: $DUNE_API_KEY" "https://api.dune.com/api/v1/query/$id" \
    | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["query_sql"].rstrip("\n")+"\n")' \
    | diff -q - "queries/$f.sql" >/dev/null && echo "ok    $f" || echo "DRIFT $f"
done
```

Run it from the repository root. A `DRIFT` line means the query was edited on Dune
without updating the file here, or the reverse — the file is not what produced the
committed data.

The `rstrip` matters: Dune returns `query_sql` with a trailing newline for some
queries and without it for others, so comparing raw output reports drift on files
that are identical. Every `.sql` here ends with exactly one newline.
