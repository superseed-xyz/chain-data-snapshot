/* =====================================================================
   Superseed — enriched ERC20 holder snapshot
   ---------------------------------------------------------------------
   ERC20 counterpart to query 8282885 (native ETH). One row per (token,
   holder): tokens ranked by USD value at the snapshot, priced ones
   first and unpriced by holder count; holders ranked within each token,
   each carrying account type, contract metadata, deployer, activity,
   and for Safes the threshold and signer addresses.

   Params: snapshot_block, top_tokens, holders_per_token. No balance
   floor - dust included, filter downstream.

   Balances come from raw logs, NOT tokens.transfers: WETH at 0x42..06
   emits no Transfer when it mints or burns, and tokens.transfers
   synthesises those flows inconsistently, netting WETH to -110.8 ETH
   against a true 10.8033. So the ledger is raw Transfer logs plus
   Deposit/Withdrawal for tokens that never express a mint or burn as a
   Transfer to/from 0x0 - adding those unconditionally would double-count
   a vault emitting both. balance_source records which applied;
   tokens.transfers only classifies which contracts are ERC20.

   Signers are derived, not called: safe_signers replays SafeSetup +
   AddedOwner + RemovedOwner, keeping an owner whose last event is not a
   removal. signer_count_matches cross-checks that decode; if it is
   false, do not trust that row's signer list.

   token_supply_reconciles is false when a token's ledger produced a
   negative balance, which proves its event history is incomplete. Events
   can also contradict state without going negative, so confirm with
   eth_call balanceOf before acting on these numbers.
   ===================================================================== */
WITH cutoff AS (
    SELECT number AS block_number, date AS block_date, time AS block_time
    FROM superseed.blocks
    WHERE number <= {{snapshot_block}}
    ORDER BY number DESC
    LIMIT 1
),

/* ---------- which contracts are ERC20 ---------------------------- */

erc20_tokens AS (
    SELECT DISTINCT contract_address AS token
    FROM tokens.transfers
    WHERE blockchain     = 'superseed'
      AND token_standard = 'erc20'
      AND block_month  <= date_trunc('month', (SELECT block_date FROM cutoff))
      AND block_date   <= (SELECT block_date   FROM cutoff)
      AND block_number <= (SELECT block_number FROM cutoff)
),

/* ---------- the ledger, from raw events -------------------------- */

/* Transfer(address indexed from, address indexed to, uint256 value).
   ERC721 indexes tokenId into topic3, so a NULL topic3 is what marks a
   log as the ERC20 shape. Absent topics are NULL here, NOT empty
   varbinary - bytearray_length(topic3) = 0 evaluates to NULL and
   silently drops every row.
   The CASE guard keeps a pathological uint256 transfer from
   overflowing the int256 cast; CASE is lazy, a WHERE filter is not. */
xfer_logs AS (
    SELECT
        l.contract_address AS token,
        bytearray_substring(l.topic1, 13, 20) AS sender,
        bytearray_substring(l.topic2, 13, 20) AS recipient,
        CASE WHEN bytearray_to_uint256(bytearray_substring(l.data, 1, 32))
                  <= UINT256 '57896044618658097711785492504343953926634992332820282019728792003956564819967'
             THEN CAST(bytearray_to_uint256(bytearray_substring(l.data, 1, 32)) AS int256)
             ELSE CAST(0 AS int256)
        END AS amount
    FROM superseed.logs l
    JOIN erc20_tokens e ON e.token = l.contract_address
    WHERE l.block_date   <= (SELECT block_date   FROM cutoff)
      AND l.block_number <= (SELECT block_number FROM cutoff)
      AND l.topic0 = keccak(to_utf8('Transfer(address,address,uint256)'))
      AND l.topic3 IS NULL
      AND bytearray_length(l.topic1) = 32
      AND bytearray_length(l.topic2) = 32
      AND bytearray_length(l.data)  >= 32
),

/* Deposit(address indexed dst, uint256 wad) / Withdrawal(address indexed src, uint256 wad) */
wrapper_logs AS (
    SELECT
        l.contract_address AS token,
        bytearray_substring(l.topic1, 13, 20) AS account,
        CASE WHEN l.topic0 = keccak(to_utf8('Deposit(address,uint256)')) THEN 1 ELSE -1 END AS sign,
        CASE WHEN bytearray_to_uint256(bytearray_substring(l.data, 1, 32))
                  <= UINT256 '57896044618658097711785492504343953926634992332820282019728792003956564819967'
             THEN CAST(bytearray_to_uint256(bytearray_substring(l.data, 1, 32)) AS int256)
             ELSE CAST(0 AS int256)
        END AS amount
    FROM superseed.logs l
    JOIN erc20_tokens e ON e.token = l.contract_address
    WHERE l.block_date   <= (SELECT block_date   FROM cutoff)
      AND l.block_number <= (SELECT block_number FROM cutoff)
      AND l.topic0 IN (
          keccak(to_utf8('Deposit(address,uint256)')),
          keccak(to_utf8('Withdrawal(address,uint256)'))
      )
      AND bytearray_length(l.topic1) = 32
      AND bytearray_length(l.data)  >= 32
),

/* Mints/burns already expressed as Transfer must not be counted twice. */
mints_via_transfer AS (
    SELECT DISTINCT token
    FROM xfer_logs
    WHERE sender    = 0x0000000000000000000000000000000000000000
       OR recipient = 0x0000000000000000000000000000000000000000
),

wrapper_tokens AS (
    SELECT DISTINCT token FROM wrapper_logs
    WHERE token NOT IN (SELECT token FROM mints_via_transfer)
),

ledger AS (
    SELECT token, recipient AS address,  amount AS delta FROM xfer_logs
    UNION ALL
    SELECT token, sender,               -amount              FROM xfer_logs
    UNION ALL
    SELECT w.token, w.account, CAST(w.sign AS int256) * w.amount
    FROM wrapper_logs w
    JOIN wrapper_tokens wt ON wt.token = w.token
),

balances_all AS (
    SELECT token, address, SUM(delta) AS balance_raw
    FROM ledger
    WHERE address <> 0x0000000000000000000000000000000000000000
    GROUP BY 1, 2
),

/* A complete ledger cannot produce a negative balance. */
token_diag AS (
    SELECT
        token,
        COUNT_IF(balance_raw < CAST(0 AS int256)) AS negative_holder_count,
        SUM(balance_raw) AS net_supply_raw
    FROM balances_all
    GROUP BY 1
),

token_balances AS (
    SELECT * FROM balances_all WHERE balance_raw > CAST(0 AS int256)
),

/* ---------- token metadata, price and ranking -------------------- */

token_meta AS (
    SELECT contract_address, MAX(symbol) AS symbol, MAX(name) AS name, MAX(decimals) AS decimals
    FROM tokens.erc20
    WHERE blockchain = 'superseed'
    GROUP BY 1
),

supply_meta AS (
    SELECT token_address, MAX(supply) AS total_supply_latest
    FROM tokens.supply_latest
    WHERE blockchain = 'superseed'
    GROUP BY 1
),

px_day AS (
    SELECT
        contract_address,
        MAX_BY(price, timestamp)    AS price,
        MAX_BY(decimals, timestamp) AS decimals,
        MAX(timestamp)              AS price_time
    FROM prices.day
    WHERE blockchain = 'superseed'
      AND timestamp <= CAST((SELECT block_time FROM cutoff) AS timestamp(3) with time zone)
    GROUP BY 1
),

px_latest AS (
    SELECT contract_address, MAX_BY(price, timestamp) AS price, MAX(timestamp) AS price_time
    FROM prices.latest
    WHERE blockchain = 'superseed'
    GROUP BY 1
),

token_stats AS (
    SELECT token, COUNT(*) AS holder_count, SUM(balance_raw) AS supply_held_raw
    FROM token_balances
    GROUP BY 1
),

token_priced AS (
    SELECT
        s.token,
        s.holder_count,
        s.supply_held_raw,
        m.symbol,
        m.name,
        COALESCE(m.decimals, d.decimals, 18) AS decimals,
        sm.total_supply_latest,
        dg.negative_holder_count,
        dg.net_supply_raw,
        CASE WHEN wt.token IS NOT NULL THEN 'transfer_events + wrapper deposit/withdrawal'
             ELSE 'transfer_events'
        END AS balance_source,
        COALESCE(d.price, l.price) AS price_usd,
        CASE
            WHEN d.price IS NOT NULL THEN 'prices.day @ snapshot'
            WHEN l.price IS NOT NULL THEN 'prices.latest'
        END AS price_source,
        COALESCE(d.price_time, l.price_time) AS price_time
    FROM token_stats s
    LEFT JOIN token_diag      dg ON dg.token           = s.token
    LEFT JOIN wrapper_tokens  wt ON wt.token           = s.token
    LEFT JOIN token_meta      m  ON m.contract_address = s.token
    LEFT JOIN supply_meta     sm ON sm.token_address   = s.token
    LEFT JOIN px_day          d  ON d.contract_address = s.token
    LEFT JOIN px_latest       l  ON l.contract_address = s.token
),

token_ranked AS (
    SELECT
        *,
        CAST(supply_held_raw AS double) / POWER(10, decimals) AS supply_held,
        CASE WHEN price_usd IS NOT NULL
             THEN CAST(supply_held_raw AS double) / POWER(10, decimals) * price_usd
        END AS token_value_usd,
        ROW_NUMBER() OVER (
            ORDER BY
                CASE WHEN price_usd IS NOT NULL THEN 0 ELSE 1 END,          -- priced tier first
                COALESCE(CAST(supply_held_raw AS double) / POWER(10, decimals) * price_usd, -1) DESC,
                holder_count DESC,
                CAST(supply_held_raw AS double) / POWER(10, decimals) DESC,
                token ASC
        ) AS token_rank
    FROM token_priced
),

top_tokens AS (
    SELECT * FROM token_ranked WHERE token_rank <= {{top_tokens}}
),

/* ---------- the holder set we actually enrich --------------------- */

holders AS (
    SELECT
        t.token_rank, t.token, t.symbol, t.name, t.decimals,
        t.price_usd, t.price_source, t.price_time,
        t.holder_count, t.supply_held, t.supply_held_raw, t.total_supply_latest,
        t.token_value_usd, t.balance_source,
        t.negative_holder_count, t.net_supply_raw,
        b.address,
        b.balance_raw,
        ROW_NUMBER() OVER (PARTITION BY b.token ORDER BY b.balance_raw DESC, b.address ASC) AS holder_rank
    FROM token_balances b
    JOIN top_tokens t ON t.token = b.token
),

holder_set AS (
    SELECT * FROM holders WHERE holder_rank <= {{holders_per_token}}
),

/* ---------- per-address enrichment ------------------------------- */

txs AS (
    SELECT "from" AS sender, block_time
    FROM superseed.transactions
    WHERE block_date   <= (SELECT block_date   FROM cutoff)
      AND block_number <= (SELECT block_number FROM cutoff)
      AND type <> '126'                       -- deposit txs are not user-signed
),

activity AS (
    SELECT sender AS address, COUNT(*) AS sent_tx_count,
           MIN(block_time) AS first_tx_time, MAX(block_time) AS last_tx_time
    FROM txs
    GROUP BY 1
),

creations AS (
    SELECT
        address,
        MIN(block_number)       AS deployed_at_block,
        ARBITRARY("from")       AS deployer,
        ARBITRARY(LENGTH(code)) AS bytecode_size
    FROM superseed.creation_traces
    WHERE block_number <= (SELECT block_number FROM cutoff)
    GROUP BY 1
),

contract_meta AS (
    SELECT address, MAX(name) AS contract_name, MAX(namespace) AS contract_namespace
    FROM superseed.contracts
    GROUP BY 1
),

/* ---------- Safe detection, threshold and signers ----------------- */

safe_logs AS (
    SELECT
        contract_address AS address,
        block_number,
        index,
        data,
        CASE topic0
            WHEN keccak(to_utf8('SafeSetup(address,address[],uint256,address,address)')) THEN 'setup'
            WHEN keccak(to_utf8('ExecutionSuccess(bytes32,uint256)'))                    THEN 'exec'
            WHEN keccak(to_utf8('ExecutionFailure(bytes32,uint256)'))                    THEN 'exec'
            WHEN keccak(to_utf8('AddedOwner(address)'))                                  THEN 'added'
            WHEN keccak(to_utf8('RemovedOwner(address)'))                                THEN 'removed'
            WHEN keccak(to_utf8('ChangedThreshold(uint256)'))                            THEN 'threshold'
        END AS kind
    FROM superseed.logs
    WHERE block_date   <= (SELECT block_date   FROM cutoff)
      AND block_number <= (SELECT block_number FROM cutoff)
      AND topic0 IN (
          keccak(to_utf8('SafeSetup(address,address[],uint256,address,address)')),
          keccak(to_utf8('ExecutionSuccess(bytes32,uint256)')),
          keccak(to_utf8('ExecutionFailure(bytes32,uint256)')),
          keccak(to_utf8('AddedOwner(address)')),
          keccak(to_utf8('RemovedOwner(address)')),
          keccak(to_utf8('ChangedThreshold(uint256)'))
      )
),

safe_info AS (
    SELECT
        address,
        COUNT_IF(kind IN ('setup', 'exec')) > 0 AS is_safe,
        COUNT_IF(kind = 'exec') AS safe_exec_count,
        /* SafeSetup(address indexed initiator, address[] owners, uint256 threshold,
                     address initializer, address fallbackHandler)
           non-indexed words: 0=owners offset, 1=threshold, 2=initializer,
           3=fallbackHandler, 4=owners length, 5..=owners.
           bytearray_substring is 1-indexed. */
        MAX(bytearray_to_uint256(bytearray_substring(data, 33, 32)))  FILTER (WHERE kind = 'setup') AS setup_threshold,
        MAX(bytearray_to_uint256(bytearray_substring(data, 129, 32))) FILTER (WHERE kind = 'setup') AS setup_owner_count,
        MAX_BY(bytearray_to_uint256(bytearray_substring(data, 1, 32)), block_number)
            FILTER (WHERE kind = 'threshold') AS latest_threshold,
        COUNT_IF(kind = 'added')   AS owners_added,
        COUNT_IF(kind = 'removed') AS owners_removed
    FROM safe_logs
    GROUP BY 1
),

/* Unroll owners[] from SafeSetup: word 4 is the length, owner i sits at
   byte 161 + 32*i, right-aligned. owner_count is clamped in a CASE so a
   malformed log cannot hand sequence() an absurd length. */
setup_logs AS (
    SELECT
        address,
        block_number,
        index,
        data,
        CASE WHEN bytearray_to_uint256(bytearray_substring(data, 129, 32)) BETWEEN UINT256 '1' AND UINT256 '100'
             THEN CAST(bytearray_to_uint256(bytearray_substring(data, 129, 32)) AS integer)
             ELSE 0
        END AS owner_count
    FROM safe_logs
    WHERE kind = 'setup'
),

setup_owners AS (
    SELECT
        l.address,
        bytearray_substring(w.word, 13, 20) AS owner,
        l.block_number * CAST(1000000 AS bigint) + l.index AS ord
    FROM setup_logs l
    CROSS JOIN UNNEST(
        transform(
            sequence(0, l.owner_count - 1),
            i -> bytearray_substring(l.data, 161 + 32 * i, 32)
        )
    ) AS w(word)
    WHERE l.owner_count >= 1
      AND bytearray_length(l.data) >= 160 + 32 * l.owner_count
),

owner_events AS (
    SELECT address, owner, 'add' AS action, ord FROM setup_owners
    UNION ALL
    SELECT
        address,
        bytearray_substring(data, 13, 20),
        CASE WHEN kind = 'added' THEN 'add' ELSE 'remove' END,
        block_number * CAST(1000000 AS bigint) + index
    FROM safe_logs
    WHERE kind IN ('added', 'removed')
      AND bytearray_length(data) >= 32
),

/* Last event wins, so add -> remove -> re-add resolves correctly. */
current_owners AS (
    SELECT address, owner
    FROM (
        SELECT address, owner, MAX_BY(action, ord) AS last_action
        FROM owner_events
        GROUP BY 1, 2
    )
    WHERE last_action = 'add'
),

safe_signers AS (
    SELECT
        address,
        ARRAY_AGG('0x' || lower(to_hex(owner)) ORDER BY owner) AS safe_signers,
        COUNT(*) AS signer_count
    FROM current_owners
    GROUP BY 1
)

/* ---------- output: one row per (token, holder) ------------------- */

SELECT
    h.token_rank,
    '0x' || lower(to_hex(h.token)) AS token_address,
    h.symbol   AS token_symbol,
    h.name     AS token_name,
    h.decimals AS token_decimals,
    h.price_usd,
    h.price_source,
    h.price_time,
    h.holder_count AS token_holder_count,
    h.supply_held  AS token_supply_held,
    h.total_supply_latest,
    h.token_value_usd,
    h.balance_source,
    h.negative_holder_count AS token_negative_holder_count,
    h.negative_holder_count = 0 AS token_supply_reconciles,

    h.holder_rank,
    '0x' || lower(to_hex(h.address)) AS address,
    -- exact integer balance; the double below is a lossy convenience
    '0x' || COALESCE(NULLIF(ltrim(lower(to_hex(CAST(h.balance_raw AS varbinary))), '0'), ''), '0') AS balance_raw_hex,
    CAST(h.balance_raw AS double) / POWER(10, h.decimals) AS balance,
    CASE WHEN h.price_usd IS NOT NULL
         THEN CAST(h.balance_raw AS double) / POWER(10, h.decimals) * h.price_usd
    END AS balance_usd,
    100.0 * CAST(h.balance_raw AS double) / NULLIF(CAST(h.supply_held_raw AS double), 0) AS share_of_supply_pct,

    cr.address IS NOT NULL
        OR cm.contract_name IS NOT NULL
        OR (h.address BETWEEN 0x4200000000000000000000000000000000000000
                          AND 0x42000000000000000000000000000000000000ff) AS is_contract,
    COALESCE(s.is_safe, false) AS is_safe,
    CASE
        WHEN COALESCE(s.is_safe, false)                                        THEN 'safe_multisig'
        WHEN h.address BETWEEN 0x4200000000000000000000000000000000000000
                           AND 0x42000000000000000000000000000000000000ff     THEN 'system_predeploy'
        WHEN cr.address IS NOT NULL OR cm.contract_name IS NOT NULL            THEN 'contract'
        WHEN COALESCE(a.sent_tx_count, 0) > 0                                  THEN 'eoa_active'
        ELSE 'eoa_never_sent'
    END AS account_type,

    CAST(COALESCE(s.latest_threshold, s.setup_threshold) AS bigint) AS safe_threshold,
    CAST(s.setup_owner_count + s.owners_added - s.owners_removed AS bigint) AS safe_owner_count,
    sg.safe_signers,
    sg.signer_count,
    -- decode cross-check: derived signer list vs. the independent count
    CASE WHEN COALESCE(s.is_safe, false)
         THEN sg.signer_count = CAST(s.setup_owner_count + s.owners_added - s.owners_removed AS bigint)
    END AS signer_count_matches,
    s.safe_exec_count,

    cm.contract_name,
    cm.contract_namespace,
    CASE WHEN cr.deployer IS NOT NULL THEN '0x' || lower(to_hex(cr.deployer)) END AS deployer,
    cr.deployed_at_block,
    cr.bytecode_size,

    COALESCE(a.sent_tx_count, 0) AS sent_tx_count,
    a.first_tx_time,
    a.last_tx_time,

    -- protocol-owned or otherwise not claimable by an end user
    h.address IN (
        0x000000000000000000000000000000000000dead,
        0x4200000000000000000000000000000000000006,
        0x4200000000000000000000000000000000000007,
        0x4200000000000000000000000000000000000010,
        0x4200000000000000000000000000000000000011,
        0x4200000000000000000000000000000000000016,
        0x4200000000000000000000000000000000000019,
        0x420000000000000000000000000000000000001a
    ) AS is_system_address,

    (SELECT block_number FROM cutoff) AS snapshot_block,
    (SELECT block_time   FROM cutoff) AS snapshot_block_time
FROM holder_set h
LEFT JOIN creations     cr ON cr.address = h.address
LEFT JOIN contract_meta cm ON cm.address = h.address
LEFT JOIN activity      a  ON a.address  = h.address
LEFT JOIN safe_info     s  ON s.address  = h.address
LEFT JOIN safe_signers  sg ON sg.address = h.address
ORDER BY h.token_rank, h.holder_rank
