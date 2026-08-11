#!/usr/bin/env node
/**
 * REHEARSAL TOOLING. This pulls the pre-shutdown snapshot from Dune, which is how
 * the committed eth-holders-*.json files were produced. The distribution that
 * actually ships will be built from the final post-shutdown export supplied by
 * Conduit, not from here. Kept as the reproducibility record for the rehearsal
 * data, and as a worked example of the shape the real export must arrive in.
 *
 * Pulls the full result set of Dune query 8282447
 * ("Superseed: ETH Snapshot to Merkle Distributor Input")
 * and writes it as JSON in { address, amount } form.
 *
 *   amount = balance in WEI as a DECIMAL STRING (exact, never a JS number)
 *
 * NOTE: --hex and --map emit shapes the merkle pipeline now REJECTS. Use the
 * default decimal { address, amount } output, which feeds it directly.
 *
 * Usage:
 *   node fetch-snapshot.mjs                       # -> eth-snapshot.json
 *   node fetch-snapshot.mjs --out custom.json
 *   node fetch-snapshot.mjs --map                 # { "0xaddr": "amount", ... }
 *   node fetch-snapshot.mjs --hex                 # amount as 0x-hex instead of decimal
 *   node fetch-snapshot.mjs --execute             # force a fresh run before fetching
 *   node fetch-snapshot.mjs --from-csv export.csv # skip the API, use a UI CSV export
 *
 * The API key is read from $DUNE_API_KEY, or from a `.env` file in this
 * directory containing:  DUNE_API_KEY=xxxxxxxx
 * Do not commit that file.
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs'

const PAGE = 5000
const API = 'https://api.dune.com/api/v1'

const argv = process.argv.slice(2)
const flag = (n) => argv.includes(n)
const opt = (n, d = null) => {
  const i = argv.indexOf(n)
  return i === -1 ? d : argv[i + 1]
}

// --enriched pulls the context query (8282885) and writes a metadata-wrapped
// object with every per-holder field. Otherwise: the plain {address, amount} set.
const enriched = flag('--enriched')
const QUERY_ID = Number(opt('--query', enriched ? 8282885 : 8282447))
const outPath = opt('--out', enriched ? 'eth-holders-enriched.json' : 'eth-snapshot.json')
const asMap = flag('--map')
const asHex = flag('--hex')
const fromCsv = opt('--from-csv')
// The plain query names the amount `earnings`; the enriched one `balance_wei_hex`.
const amountCol = opt('--amount-column', enriched ? 'balance_wei_hex' : 'earnings')

function loadKey() {
  if (process.env.DUNE_API_KEY) return process.env.DUNE_API_KEY.trim()
  for (const f of ['.env', '.env.local']) {
    if (!existsSync(f)) continue
    const m = readFileSync(f, 'utf8').match(/^\s*(?:export\s+)?DUNE_API_KEY\s*=\s*["']?([^"'\s#]+)/m)
    if (m) return m[1]
  }
  throw new Error(
    'No Dune API key. Either `export DUNE_API_KEY=...` or create a .env file here containing DUNE_API_KEY=...'
  )
}

/** Minimal RFC-4180 parser: quoted fields, escaped quotes, CRLF. */
function parseCsv(text) {
  const rows = []
  let row = [], field = '', quoted = false
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    if (quoted) {
      if (ch === '"') { if (text[i + 1] === '"') { field += '"'; i++ } else quoted = false }
      else field += ch
      continue
    }
    if (ch === '"') quoted = true
    else if (ch === ',') { row.push(field); field = '' }
    else if (ch === '\n') { row.push(field); rows.push(row); row = []; field = '' }
    else if (ch !== '\r') field += ch
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row) }
  const kept = rows.filter((r) => r.length > 1 || r[0] !== '')
  const header = kept[0].map((h) => h.trim())
  return kept.slice(1).map((r) => Object.fromEntries(header.map((h, i) => [h, r[i]])))
}

async function duneFetch(path, key) {
  const res = await fetch(`${API}${path}`, { headers: { 'X-Dune-API-Key': key } })
  if (!res.ok) {
    throw new Error(`Dune API ${res.status} ${res.statusText} on ${path}\n${(await res.text()).slice(0, 400)}`)
  }
  return res.json()
}

async function fetchRows(key) {
  if (flag('--execute')) {
    const { execution_id } = await duneFetch(`/query/${QUERY_ID}/execute`, key).catch(async () => {
      const res = await fetch(`${API}/query/${QUERY_ID}/execute`, {
        method: 'POST',
        headers: { 'X-Dune-API-Key': key, 'Content-Type': 'application/json' },
        body: '{"performance":"medium"}',
      })
      if (!res.ok) throw new Error(`execute failed: ${res.status} ${await res.text()}`)
      return res.json()
    })
    process.stderr.write(`started execution ${execution_id}; polling...\n`)
    for (;;) {
      const s = await duneFetch(`/execution/${execution_id}/status`, key)
      if (s.state === 'QUERY_STATE_COMPLETED') break
      if (s.state === 'QUERY_STATE_FAILED' || s.state === 'QUERY_STATE_CANCELLED') {
        throw new Error(`execution ${s.state}: ${JSON.stringify(s.error ?? {})}`)
      }
      await new Promise((r) => setTimeout(r, 5000))
    }
  }

  // Pin to one execution when given. The query-level "latest results" endpoint is
  // ambiguous once non-default parameters are involved, so --execution is the
  // reliable way to fetch a specific parameterised run.
  const execId = opt('--execution')
  const base = execId ? `/execution/${execId}/results` : `/query/${QUERY_ID}/results`

  const rows = []
  for (let offset = 0; ; offset += PAGE) {
    const body = await duneFetch(`${base}?limit=${PAGE}&offset=${offset}`, key)
    if (body.state && body.state !== 'QUERY_STATE_COMPLETED') {
      throw new Error(`latest execution is ${body.state}; re-run with --execute`)
    }
    const page = body.result?.rows ?? []
    rows.push(...page)
    process.stderr.write(`fetched ${rows.length} rows\r`)
    if (page.length < PAGE) break
  }
  process.stderr.write('\n')
  return rows
}

const rows = fromCsv ? parseCsv(readFileSync(fromCsv, 'utf8')) : await fetchRows(loadKey())
if (!rows.length) throw new Error('no rows returned; run the query on Dune first, or pass --execute')
if (!('address' in rows[0]) || !(amountCol in rows[0])) {
  throw new Error(`expected address/${amountCol} columns, got: ${Object.keys(rows[0]).join(', ')}`)
}

const seen = new Set()
let total = 0n
const entries = []
const records = []

for (const [i, r] of rows.entries()) {
  const address = String(r.address).trim().toLowerCase()
  const rawAmount = String(r[amountCol]).trim().toLowerCase()

  if (!/^0x[0-9a-f]{40}$/.test(address)) throw new Error(`row ${i}: malformed address ${address}`)
  if (!/^0x[0-9a-f]+$/.test(rawAmount)) throw new Error(`row ${i}: malformed ${amountCol} ${rawAmount}`)
  if (seen.has(address)) throw new Error(`row ${i}: duplicate address ${address}`)
  seen.add(address)

  const wei = BigInt(rawAmount)
  if (wei <= 0n) throw new Error(`row ${i}: non-positive amount for ${address}`)
  total += wei

  const amount = asHex ? '0x' + wei.toString(16) : wei.toString()
  entries.push([address, amount])

  if (enriched) {
    const num = (v) => (v === null || v === undefined || v === '' ? null : Number(v))
    const bool = (v) => (typeof v === 'boolean' ? v : v === 'true' ? true : v === 'false' ? false : null)
    const str = (v) => (v === null || v === undefined || v === '' ? null : String(v))
    records.push({
      address,
      amount,                                  // wei, exact
      balance_eth: num(r.balance_eth),         // convenience only; lossy double
      account_type: str(r.account_type),
      is_contract: bool(r.is_contract),
      is_safe: bool(r.is_safe),
      safe_threshold: num(r.safe_threshold),
      safe_owner_count: num(r.safe_owner_count),
      safe_exec_count: num(r.safe_exec_count),
      contract_name: str(r.contract_name),
      contract_namespace: str(r.contract_namespace),
      deployer: str(r.deployer),
      deployed_at_block: num(r.deployed_at_block),
      bytecode_size: num(r.bytecode_size),
      sent_tx_count: num(r.sent_tx_count),
      first_tx_time: str(r.first_tx_time),
      last_tx_time: str(r.last_tx_time),
      is_system_address: bool(r.is_system_address),
    })
  }
}

// The query repeats the run-wide total on every row; use it as an integrity check.
const declared = rows[0].distribution_total_wei_hex
if (declared && BigInt(String(declared).trim()) !== total) {
  throw new Error(`total mismatch: rows sum to ${total} wei, query reported ${BigInt(String(declared))} wei`)
}

// Descending by amount. The query already returns this order; re-sort so the
// output is stable even if pagination ever hands back pages out of order.
entries.sort((a, b) => {
  const [x, y] = [BigInt(a[1]), BigInt(b[1])]
  return x < y ? 1 : x > y ? -1 : a[0] < b[0] ? -1 : 1
})

let payload
if (enriched) {
  const order = new Map(entries.map(([a], i) => [a, i]))
  records.sort((x, y) => order.get(x.address) - order.get(y.address))
  const tally = (k) =>
    records.reduce((m, r) => ((m[r[k] ?? 'null'] = (m[r[k] ?? 'null'] ?? 0) + 1), m), {})
  payload = {
    chain: 'superseed',
    asset: 'native ETH',
    snapshot_block: Number(rows[0].snapshot_block),
    snapshot_block_time: String(rows[0].snapshot_block_time),
    source_query: `https://dune.com/queries/${QUERY_ID}`,
    holder_count: records.length,
    total_wei: total.toString(),
    total_eth: Number(total) / 1e18,
    account_type_counts: tally('account_type'),
    safe_count: records.filter((r) => r.is_safe).length,
    holders: records,
  }
} else {
  payload = asMap
    ? Object.fromEntries(entries)
    : entries.map(([address, amount]) => ({ address, amount }))
}

writeFileSync(outPath, JSON.stringify(payload, null, 2) + '\n')

const eth = Number(total) / 1e18
process.stderr.write(
  `wrote ${outPath}\n` +
  `  recipients : ${entries.length}\n` +
  `  total      : ${total} wei (${eth} ETH)\n` +
  `  block      : ${rows[0].snapshot_block ?? 'n/a'} @ ${rows[0].snapshot_block_time ?? 'n/a'}\n` +
  `  amount fmt : ${asHex ? '0x-hex' : 'decimal'} wei string\n` +
  `  shape      : ${asMap ? '{ address: amount }' : '[ { address, amount } ]'}\n`
)
