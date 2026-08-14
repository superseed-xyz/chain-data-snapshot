# queries

The Dune SQL behind every snapshot in this repository, committed verbatim so the
data can be audited from source rather than taken on trust. The files are exact
copies of the saved queries — no local edits, so a diff against Dune is meaningful.

| File | Query | Parameters (defaults) | What it produces |
| --- | --- | --- | --- |
| `eth-holders-snapshot.sql` | [8282318](https://dune.com/queries/8282318) | `snapshot_block` (tip), `min_balance_eth` (0) | Native ETH balances rebuilt from traces, gas and deposits, plus the L1/L2 reconciliation. |
| `eth-holders-enriched.sql` | [8282885](https://dune.com/queries/8282885) | `snapshot_block` (tip), `min_balance_eth` (0) | The same ledger with per-address context. `fetch-snapshot.mjs --enriched`. |
| `erc20-holders-enriched.sql` | [8328129](https://dune.com/queries/8328129) | `snapshot_block` (tip), `top_tokens` (50), `holders_per_token` (500) | ERC20 holders by token, with Safe signers. `fetch-snapshot.mjs --erc20`. |

All three are public. Pin `snapshot_block` to make a run reproducible; the default
resolves to chain tip, so two runs an hour apart return different data.

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
