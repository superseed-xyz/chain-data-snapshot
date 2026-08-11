#!/usr/bin/env node
/**
 * Derives any snapshot view from eth-holders-enriched.json, the single source
 * of truth. No Dune calls, no API key: the enriched file is a strict superset
 * of every other view, so they never need to be stored separately.
 *
 *   node derive.mjs                          # claim set -> stdout
 *   node derive.mjs --out claim.json         # claim set, {address, amount}
 *   node derive.mjs --all                    # include system addresses
 *   node derive.mjs --min-eth 0.0001         # apply a dust floor
 *   node derive.mjs --exclude-plain-contracts  # drop non-Safe contracts (keeps EOAs + Safes)
 *   node derive.mjs --only-safes             # just the multisigs
 *
 * Output is `[{ address, amount }]` with amount as a DECIMAL wei string. That is
 * the only shape the merkle pipeline accepts, and it feeds straight into
 * `merkle-distributor`'s build-recipients.mjs with no conversion.
 *
 * The former `--format map` and `--format merkle` options emitted 0x-hex amounts
 * for the old Uniswap `{address, earnings, reasons}` input. That format is now
 * rejected by parse-balance-map (hex in a decimal field inflates a value ~4096x),
 * so both were removed rather than left as a trap.
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'

const argv = process.argv.slice(2)
const flag = (n) => argv.includes(n)
const opt = (n, d = null) => {
  const i = argv.indexOf(n)
  return i === -1 ? d : argv[i + 1]
}

const src = opt('--in', 'eth-holders-enriched.json')
const outPath = opt('--out')
const format = opt('--format', 'array')
const minEth = opt('--min-eth')
const includeSystem = flag('--all')

if (!existsSync(src)) {
  throw new Error(
    `${src} not found.\n\n` +
      `The enriched snapshot is not committed to this repository: it is a pre-joined view\n` +
      `of public chain data that anyone can rebuild. Regenerate it with:\n\n` +
      `    DUNE_API_KEY=... node fetch-snapshot.mjs --enriched\n\n` +
      `Source query: https://dune.com/queries/8282885\n` +
      `The derived claim set (eth-holders-snapshot.json) IS committed, so if you only need\n` +
      `that, you do not need this file or a Dune key at all.`
  )
}

const db = JSON.parse(readFileSync(src, 'utf8'))
if (!db.holders) throw new Error(`${src} has no holders[]; expected the enriched snapshot`)

const minWei = minEth === null ? 0n : BigInt(Math.round(Number(minEth) * 1e18))

let rows = db.holders
if (!includeSystem) rows = rows.filter((r) => !r.is_system_address)
if (minWei > 0n) rows = rows.filter((r) => BigInt(r.amount) >= minWei)
// Keeps EOAs and Safes; drops only non-Safe contracts. Named "plain" deliberately:
// a Safe IS a contract, so `--exclude-contracts` would read as dropping Safes too.
if (flag('--exclude-plain-contracts')) rows = rows.filter((r) => !r.is_contract || r.is_safe)
if (flag('--exclude-contracts')) {
  throw new Error(
    '--exclude-contracts was renamed to --exclude-plain-contracts, because it keeps Safes.\n' +
      'A Safe is a contract, so the old name implied Safes were dropped when they are not.'
  )
}
if (flag('--only-safes')) rows = rows.filter((r) => r.is_safe)

const total = rows.reduce((s, r) => s + BigInt(r.amount), 0n)

if (format !== 'array') {
  throw new Error(
    `unknown --format ${format}. Only 'array' ([{address, amount}], decimal wei) is supported; ` +
      `the hex 'map' and 'merkle' shapes were removed because the pipeline now rejects them.`
  )
}
const payload = rows.map((r) => ({ address: r.address, amount: r.amount }))

const json = JSON.stringify(payload, null, 2) + '\n'
if (outPath) writeFileSync(outPath, json)
else process.stdout.write(json)

process.stderr.write(
  `source     : ${src} (block ${db.snapshot_block})\n` +
  `filters    : ${[
    includeSystem ? 'include system' : 'exclude system',
    minWei > 0n ? `>= ${minEth} ETH` : 'no floor',
    flag('--exclude-plain-contracts') ? 'no non-Safe contracts' : null,
    flag('--only-safes') ? 'safes only' : null,
  ].filter(Boolean).join(', ')}\n` +
  `format     : ${format}\n` +
  `entries    : ${rows.length}\n` +
  `total      : ${total} wei (${Number(total) / 1e18} ETH)\n` +
  (outPath ? `wrote      : ${outPath}\n` : '')
)
