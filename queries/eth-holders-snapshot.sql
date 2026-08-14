/* =====================================================================
   Superseed — native ETH holder snapshot
   ---------------------------------------------------------------------
   Dune has no `balances_superseed` spell and `tokens.transfers` only
   carries Superseed native rows from 2025-05-08 (chain launched
   2024-09-12), so balances are rebuilt from raw data as a full ledger:

     + / -  every successful value-carrying trace  (external + internal
            transfers, contract-creation endowments, selfdestruct sweeps)
     -      gas paid by each tx sender: gas_used * gas_price + l1_fee
            (failed txs pay too, so they are NOT filtered out)
     +      the same gas credited to the OP-Stack fee vaults that
            actually receive it, so the ledger stays balanced
     +      ETH minted into L2 by deposit transactions (type '126'),
            which no trace records

   Sum over the ledger = native ETH balance at the snapshot block.
   ===================================================================== */
WITH cutoff AS (
    -- newest block at or below {{snapshot_block}}; the default resolves to chain tip
    SELECT number AS block_number, date AS block_date, time AS block_time
    FROM superseed.blocks
    WHERE number <= {{snapshot_block}}
    ORDER BY number DESC
    LIMIT 1
),

trace_flows AS (
    SELECT
        CASE WHEN type = 'suicide' THEN address ELSE "from" END AS sender,
        CASE WHEN type = 'suicide' THEN refund_address   -- selfdestruct beneficiary
             WHEN type = 'create'  THEN address          -- newly deployed contract
             ELSE "to"
        END AS recipient,
        CAST(value AS int256) AS wei
    FROM superseed.traces
    WHERE block_date   <= (SELECT block_date   FROM cutoff)
      AND block_number <= (SELECT block_number FROM cutoff)
      AND value > UINT256 '0'
      AND success
      AND tx_success
      -- delegatecall/callcode echo the parent's value without moving ETH
      AND (call_type IS NULL OR call_type NOT IN ('delegatecall', 'callcode', 'staticcall'))
),

txs AS (
    -- one pass; the value-0 L1-attributes deposit in every block is dropped here
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

    -- gas leaves the sender ...
    UNION ALL
    SELECT sender, -(l2_fee_wei + l1_fee_wei) FROM txs WHERE type <> '126'
    -- ... and lands in the three fee vaults
    UNION ALL
    SELECT 0x4200000000000000000000000000000000000011, priority_fee_wei              FROM txs WHERE type <> '126'
    UNION ALL
    SELECT 0x4200000000000000000000000000000000000019, l2_fee_wei - priority_fee_wei FROM txs WHERE type <> '126'
    UNION ALL
    SELECT 0x420000000000000000000000000000000000001a, l1_fee_wei                    FROM txs WHERE type <> '126'

    -- deposit mint: credited to `from` before the tx forwards `value` onward
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
)

SELECT
    ROW_NUMBER() OVER (ORDER BY b.balance_wei DESC) AS holder_rank,
    b.address,
    b.balance_wei / 1e18 AS balance_eth,
    b.balance_wei,
    100.0 * (b.balance_wei / 1e18) / SUM(b.balance_wei / 1e18) OVER () AS pct_of_snapshot_supply,
    c.address IS NOT NULL AS is_contract,
    b.address IN (
        0x4200000000000000000000000000000000000007,  -- L2CrossDomainMessenger
        0x4200000000000000000000000000000000000010,  -- L2StandardBridge
        0x4200000000000000000000000000000000000011,  -- SequencerFeeVault
        0x4200000000000000000000000000000000000016,  -- L2ToL1MessagePasser (withdrawal burns)
        0x4200000000000000000000000000000000000019,  -- BaseFeeVault
        0x420000000000000000000000000000000000001a,  -- L1FeeVault
        0x0000000000000000000000000000000000000000   -- burn / zero address
    ) AS is_system_address,
    (SELECT block_number FROM cutoff) AS snapshot_block,
    (SELECT block_time   FROM cutoff) AS snapshot_block_time
FROM balances b
LEFT JOIN contracts c ON c.address = b.address
WHERE b.balance_wei > CAST(0 AS int256)
  AND b.balance_wei / 1e18 >= {{min_balance_eth}}
ORDER BY b.balance_wei DESC
