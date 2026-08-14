#!/usr/bin/env node
/**
 * Checks erc20-holders-enriched.json against the chain itself.
 *
 * Every balance in that file is derived from event logs. That is the only way to
 * get a full holder set out of Dune, but events can lie: a token can emit a
 * Transfer that does not match its own state change, and no amount of internal
 * consistency checking will catch it. eth_call is the arbiter, so this script
 * replays every holder row as `balanceOf(holder)` at the snapshot block and
 * every token as `totalSupply()`.
 *
 *   node verify-balances.mjs --rpc https://rpc-superseed-mainnet-0.t.conduit.xyz/<key>
 *   SUPERSEED_RPC_URL=... node verify-balances.mjs
 *   node verify-balances.mjs --tokens 5           # only the top 5 tokens
 *   node verify-balances.mjs --ignore-token 0x0e63d339b9147bf1bc72f34e2a19761d8214622b
 *
 * Exits non-zero if any balance disagrees, so it works as a gate.
 *
 * KNOWN BAD TOKEN: YGD (0x0e63d339b9147bf1bc72f34e2a19761d8214622b) emitted two
 * mint Transfers to 0x469e7e5bd6a29b08c6e4fe0b9c002ce7e0010959 in block 11463173
 * (50M and 500M) but credited only 500M. The token's events contradict its own
 * state, so that one holder always reads 50M high and no log-derived snapshot can
 * fix it. Pass --ignore-token for it if you want a clean exit code.
 *
 * Needs an ARCHIVE rpc: balances are read at the snapshot block, not at head.
 */
import { existsSync, readFileSync } from 'node:fs'

const argv = process.argv.slice(2)
const flag = (n) => argv.includes(n)
const opt = (n, d = null) => {
  const i = argv.indexOf(n)
  return i === -1 ? d : argv[i + 1]
}
const opts = (n) => argv.reduce((a, v, i) => (v === n ? [...a, argv[i + 1]] : a), [])

const src = opt('--in', 'erc20-holders-enriched.json')
const rpc = opt('--rpc', process.env.SUPERSEED_RPC_URL)
const batchSize = Number(opt('--batch', 50))
const tokenLimit = opt('--tokens') === null ? Infinity : Number(opt('--tokens'))
const ignored = new Set(opts('--ignore-token').map((t) => String(t).toLowerCase()))

if (!rpc) {
  throw new Error(
    'No RPC url. Pass --rpc <url> or set SUPERSEED_RPC_URL.\n' +
      'Superseed mainnet is chain 5330; the public endpoint is https://mainnet.superseed.xyz\n' +
      'but it must be an ARCHIVE node to answer at a historical block.'
  )
}
if (!existsSync(src)) {
  throw new Error(
    `${src} not found. Rebuild it first:\n\n` +
      `    DUNE_API_KEY=... node fetch-snapshot.mjs --erc20\n\n` +
      `Source query: https://dune.com/queries/8328129`
  )
}

const db = JSON.parse(readFileSync(src, 'utf8'))
if (!db.tokens) throw new Error(`${src} has no tokens[]; expected the ERC20 snapshot`)

const block = '0x' + Number(db.snapshot_block).toString(16)
const SELECTOR = { balanceOf: '0x70a08231', totalSupply: '0x18160ddd' }
const pad = (addr) => '0'.repeat(24) + addr.slice(2)

let rpcCalls = 0

/** One JSON-RPC batch. Node's fetch is fine here; some providers 403 odd agents. */
async function batchCall(calls) {
  const body = calls.map((c, id) => ({
    jsonrpc: '2.0',
    id,
    method: 'eth_call',
    params: [{ to: c.to, data: c.data }, block],
  }))
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await fetch(rpc, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'User-Agent': 'superseed-offboarding-verify/1.0' },
        body: JSON.stringify(body),
      })
      if (!res.ok) throw new Error(`rpc ${res.status} ${res.statusText}: ${(await res.text()).slice(0, 200)}`)
      const json = await res.json()
      rpcCalls += calls.length
      const byId = new Map(json.map((r) => [r.id, r]))
      return calls.map((_, id) => byId.get(id))
    } catch (err) {
      if (attempt >= 2) throw err
      await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)))
    }
  }
}

const tokens = db.tokens.filter((t) => !ignored.has(t.token_address)).slice(0, tokenLimit)
const skipped = db.tokens.length - tokens.length

// ---- totalSupply() per token -------------------------------------------------
const supplyResults = await batchCall(
  tokens.map((t) => ({ to: t.token_address, data: SELECTOR.totalSupply }))
)

const supplyIssues = []
for (const [i, t] of tokens.entries()) {
  const r = supplyResults[i]
  if (!r || r.error) {
    supplyIssues.push({ t, note: `rpc error: ${r?.error?.message ?? 'no response'}` })
    continue
  }
  const chain = Number(BigInt(r.result)) / 10 ** t.decimals
  // supply_held is the sum of positive holder balances, so it can legitimately sit
  // just under totalSupply when a token parks supply somewhere we exclude.
  const drift = chain === 0 ? 0 : ((t.supply_held - chain) / chain) * 100
  if (Math.abs(drift) > 1e-6) supplyIssues.push({ t, chain, drift })
}

// ---- balanceOf() for every holder row ---------------------------------------
const rows = tokens.flatMap((t) => t.holders.map((h) => ({ t, h })))
let exact = 0
const mismatches = []

for (let i = 0; i < rows.length; i += batchSize) {
  const chunk = rows.slice(i, i + batchSize)
  const res = await batchCall(
    chunk.map(({ t, h }) => ({ to: t.token_address, data: SELECTOR.balanceOf + pad(h.address) }))
  )
  for (const [j, { t, h }] of chunk.entries()) {
    const r = res[j]
    if (!r || r.error) {
      mismatches.push({ t, h, chain: null, note: r?.error?.message ?? 'no response' })
      continue
    }
    const chain = BigInt(r.result)
    if (chain === BigInt(h.amount)) exact++
    else mismatches.push({ t, h, chain })
  }
  // Carriage-return progress only makes sense on a terminal; piped to a file or a
  // CI log it just smears every update onto one enormous line.
  if (process.stderr.isTTY) {
    process.stderr.write(`  checked ${Math.min(i + batchSize, rows.length)}/${rows.length}\r`)
  }
}
if (process.stderr.isTTY) process.stderr.write('\n')

// ---- report ------------------------------------------------------------------
const out = []
out.push(`snapshot   : block ${db.snapshot_block} @ ${db.snapshot_block_time}`)
out.push(`source     : ${src}`)
out.push(`tokens     : ${tokens.length}${skipped ? ` (${skipped} skipped)` : ''}`)
out.push(`eth_calls  : ${rpcCalls}`)
out.push('')
out.push(`balanceOf  : ${exact} exact, ${mismatches.length} mismatched, of ${rows.length}`)

if (supplyIssues.length) {
  out.push('')
  out.push(`totalSupply: ${tokens.length - supplyIssues.length}/${tokens.length} match exactly`)
  for (const s of supplyIssues.slice(0, 20)) {
    out.push(
      s.note
        ? `  ${(s.t.symbol ?? s.t.token_address).padEnd(18)} ${s.note}`
        : `  ${(s.t.symbol ?? s.t.token_address).padEnd(18)} chain ${s.chain} vs snapshot ${s.t.supply_held} (${s.drift.toFixed(6)}%)`
    )
  }
} else {
  out.push(`totalSupply: all ${tokens.length} match exactly`)
}

if (mismatches.length) {
  out.push('')
  out.push('MISMATCHES (chain is authoritative; the snapshot is wrong here):')
  for (const m of mismatches.slice(0, 40)) {
    out.push(
      `  ${(m.t.symbol ?? m.t.token_address).padEnd(18)} ${m.h.address}` +
        (m.note ? `  ${m.note}` : `\n      chain    ${m.chain}\n      snapshot ${m.h.amount}`)
    )
  }
  if (mismatches.length > 40) out.push(`  ... and ${mismatches.length - 40} more`)
}

process.stdout.write(out.join('\n') + '\n')
process.exit(mismatches.length ? 1 : 0)
