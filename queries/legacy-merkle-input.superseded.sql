/* =====================================================================
   Superseed — native ETH snapshot as merkle-distributor input
   ---------------------------------------------------------------------
   Emits the NewFormat rows accepted by
   superseed-xyz/merkle-distributor -> src/parse-balance-map.ts:

       [{ "address": "0x..", "earnings": "0x..", "reasons": "" }, ...]

   `earnings` is a 0x-prefixed HEX wei string, produced by byte-casting
   the int256 balance, so BigNumber.from() reads it exactly.

   Do NOT feed the OldFormat map ({address: amount}) with decimal string
   amounts: the parser does `0x${balances[account].toString(16)}` and
   String.prototype.toString() IGNORES the radix argument, so "1000"
   becomes 0x1000 = 4096. Plain JS numbers lose precision above 2^53.
   The NewFormat array below avoids both traps.

   Ledger construction is identical to "Superseed — Native ETH Holder
   Snapshot" (query 8282318); see that query for the reconciliation.
   ===================================================================== */
WITH cutoff AS (
    SELECT number AS block_number, date AS block_date, time AS block_time
    FROM superseed.blocks
    WHERE number <= {{snapshot_block}}
    ORDER BY number DESC
    LIMIT 1
),

trace_flows AS (
    SELECT
        CASE WHEN type = 'suicide' THEN address ELSE "from" END AS sender,
        CASE WHEN type = 'suicide' THEN refund_address
             WHEN type = 'create'  THEN address
             ELSE "to"
        END AS recipient,
        CAST(value AS int256) AS wei
    FROM superseed.traces
    WHERE block_date   <= (SELECT block_date   FROM cutoff)
      AND block_number <= (SELECT block_number FROM cutoff)
      AND value > UINT256 '0'
      AND success
      AND tx_success
      AND (call_type IS NULL OR call_type NOT IN ('delegatecall', 'callcode', 'staticcall'))
),

txs AS (
    SELECT
        "from" AS sender,
        type,
        CAST(value AS int256) AS value_wei,
        CAST(gas_used AS int256) * CAST(gas_price AS int256) AS l2_fee_wei,
        CAST(COALESCE(l1_fee, 0) AS int256) AS l1_fee_wei,
        CAST(gas_used AS int256) * CAST(COALESCE(priority_fee_per_gas, 0) AS int256) AS priority_fee_wei
    FROM superseed.transactions
    WHERE block_date   <= (SELECT block_date   FROM cutoff)
      AND block_number <= (SELECT block_number FROM cutoff)
      AND (type <> '126' OR value > UINT256 '0')
),

ledger AS (
    SELECT recipient AS address, wei  FROM trace_flows
    UNION ALL
    SELECT sender,              -wei  FROM trace_flows
    UNION ALL
    SELECT sender, -(l2_fee_wei + l1_fee_wei) FROM txs WHERE type <> '126'
    UNION ALL
    SELECT 0x4200000000000000000000000000000000000011, priority_fee_wei              FROM txs WHERE type <> '126'
    UNION ALL
    SELECT 0x4200000000000000000000000000000000000019, l2_fee_wei - priority_fee_wei FROM txs WHERE type <> '126'
    UNION ALL
    SELECT 0x420000000000000000000000000000000000001a, l1_fee_wei                    FROM txs WHERE type <> '126'
    UNION ALL
    SELECT sender, value_wei FROM txs WHERE type = '126'
),

balances AS (
    SELECT address, SUM(wei) AS balance_wei
    FROM ledger
    WHERE LENGTH(address) = 20
    GROUP BY 1
),

contracts AS (
    SELECT DISTINCT address
    FROM superseed.creation_traces
    WHERE block_number <= (SELECT block_number FROM cutoff)
),

eligible AS (
    SELECT
        b.address,
        b.balance_wei,
        c.address IS NOT NULL AS is_contract
    FROM balances b
    LEFT JOIN contracts c ON c.address = b.address
    -- parse-balance-map throws on amounts <= 0
    WHERE b.balance_wei > CAST(0 AS int256)
      AND b.balance_wei / 1e18 >= {{min_balance_eth}}
      -- not claimable by an end user: protocol-owned or contract-locked ETH
      AND b.address NOT IN (
          0x0000000000000000000000000000000000000000,  -- burn / zero address
          0x4200000000000000000000000000000000000006,  -- WETH: backs WETH holders, distribute separately
          0x4200000000000000000000000000000000000007,  -- L2CrossDomainMessenger (in-flight)
          0x4200000000000000000000000000000000000010,  -- L2StandardBridge (in-flight)
          0x4200000000000000000000000000000000000011,  -- SequencerFeeVault
          0x4200000000000000000000000000000000000016,  -- L2ToL1MessagePasser (already withdrawn to L1)
          0x4200000000000000000000000000000000000019,  -- BaseFeeVault
          0x420000000000000000000000000000000000001a   -- L1FeeVault
      )
)

SELECT
    -- ---- the three NewFormat fields, in order ----
    '0x' || lower(to_hex(address)) AS address,
    '0x' || COALESCE(NULLIF(ltrim(lower(to_hex(CAST(balance_wei AS varbinary))), '0'), ''), '0') AS earnings,
    '' AS reasons,

    -- ---- informational; parse-balance-map ignores extra keys ----
    balance_wei / 1e18 AS balance_eth,
    is_contract,
    '0x' || COALESCE(NULLIF(ltrim(lower(to_hex(CAST(SUM(balance_wei) OVER () AS varbinary))), '0'), ''), '0') AS distribution_total_wei_hex,
    SUM(balance_wei) OVER () / 1e18 AS distribution_total_eth,
    COUNT(*) OVER () AS recipient_count,
    (SELECT block_number FROM cutoff) AS snapshot_block,
    (SELECT block_time   FROM cutoff) AS snapshot_block_time
FROM eligible
ORDER BY balance_wei DESC
