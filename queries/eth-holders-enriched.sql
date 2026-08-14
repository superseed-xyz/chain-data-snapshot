/* =====================================================================
   Superseed — enriched native ETH holder snapshot
   ---------------------------------------------------------------------
   Same ledger as query 8282318 (see it for the reconciliation), plus
   per-address context for offboarding triage:

     - account_type / is_contract / contract_name / deployer
     - is_safe + safe_threshold + safe_owner_count, derived from Safe's
       own events. Dune has no safe_superseed spell and no decoded Safe
       tables for this chain, so these come from raw logs. topic0 values
       are computed with keccak() in SQL rather than hardcoded.
       Verified present on this chain: 125 SafeSetup, 36 Safes executing.
     - outbound tx activity: an address that has SENT a tx is provably
       controlled by a live signer, the strongest claimability signal
       available on-chain.

   NOTE ON CODE DETECTION: genesis predeploys (0x42..00-0x42..ff) have
   code but were never deployed by a tx, so they are absent from
   creation_traces. is_contract therefore unions creation_traces, the
   predeploy range, and the decoded-contract registry; deployer and
   deployed_at_block stay NULL for genesis accounts.

   No balance floor - dust included, filter downstream.
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
        block_number,
        block_time,
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

activity AS (
    SELECT
        sender AS address,
        COUNT(*)          AS sent_tx_count,
        MIN(block_number) AS first_tx_block,
        MIN(block_time)   AS first_tx_time,
        MAX(block_number) AS last_tx_block,
        MAX(block_time)   AS last_tx_time
    FROM txs
    WHERE type <> '126'
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

safe_logs AS (
    SELECT
        contract_address AS address,
        block_number,
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
           3=fallbackHandler, 4=owners length. bytearray_substring is 1-indexed. */
        MAX(bytearray_to_uint256(bytearray_substring(data, 33, 32)))  FILTER (WHERE kind = 'setup') AS setup_threshold,
        MAX(bytearray_to_uint256(bytearray_substring(data, 129, 32))) FILTER (WHERE kind = 'setup') AS setup_owner_count,
        MAX_BY(bytearray_to_uint256(bytearray_substring(data, 1, 32)), block_number)
            FILTER (WHERE kind = 'threshold') AS latest_threshold,
        COUNT_IF(kind = 'added')   AS owners_added,
        COUNT_IF(kind = 'removed') AS owners_removed
    FROM safe_logs
    GROUP BY 1
),

enriched AS (
    SELECT
        b.address,
        b.balance_wei,
        -- OP-Stack predeploys live at 0x42..0000 - 0x42..00ff and are genesis
        -- accounts, so they never appear in creation_traces.
        b.address BETWEEN 0x4200000000000000000000000000000000000000
                      AND 0x42000000000000000000000000000000000000ff AS is_predeploy,
        cr.address IS NOT NULL AS in_creation_traces,
        cr.deployer,
        cr.deployed_at_block,
        cr.bytecode_size,
        cm.contract_name,
        cm.contract_namespace,
        COALESCE(s.is_safe, false) AS is_safe,
        s.safe_exec_count,
        COALESCE(s.latest_threshold, s.setup_threshold) AS safe_threshold,
        s.setup_owner_count + s.owners_added - s.owners_removed AS safe_owner_count,
        COALESCE(a.sent_tx_count, 0) AS sent_tx_count,
        a.first_tx_block, a.first_tx_time, a.last_tx_block, a.last_tx_time
    FROM balances b
    LEFT JOIN creations     cr ON cr.address = b.address
    LEFT JOIN contract_meta cm ON cm.address = b.address
    LEFT JOIN activity      a  ON a.address  = b.address
    LEFT JOIN safe_info     s  ON s.address  = b.address
    WHERE b.balance_wei > CAST(0 AS int256)
      AND b.balance_wei / 1e18 >= {{min_balance_eth}}
)

SELECT
    ROW_NUMBER() OVER (ORDER BY balance_wei DESC) AS holder_rank,
    '0x' || lower(to_hex(address)) AS address,
    balance_wei / 1e18 AS balance_eth,
    '0x' || COALESCE(NULLIF(ltrim(lower(to_hex(CAST(balance_wei AS varbinary))), '0'), ''), '0') AS balance_wei_hex,

    in_creation_traces OR is_predeploy OR contract_name IS NOT NULL AS is_contract,
    is_safe,
    CASE
        WHEN is_safe                                                          THEN 'safe_multisig'
        WHEN is_predeploy                                                     THEN 'system_predeploy'
        WHEN in_creation_traces OR contract_name IS NOT NULL                  THEN 'contract'
        WHEN sent_tx_count > 0                                                THEN 'eoa_active'
        ELSE 'eoa_never_sent'
    END AS account_type,

    CAST(safe_threshold   AS bigint) AS safe_threshold,
    CAST(safe_owner_count AS bigint) AS safe_owner_count,
    safe_exec_count,

    contract_name,
    contract_namespace,
    CASE WHEN deployer IS NOT NULL THEN '0x' || lower(to_hex(deployer)) END AS deployer,
    deployed_at_block,
    bytecode_size,

    sent_tx_count,
    first_tx_block,
    first_tx_time,
    last_tx_block,
    last_tx_time,

    -- protocol-owned or otherwise not claimable by an end user
    address IN (
        0x0000000000000000000000000000000000000000,
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
FROM enriched
ORDER BY balance_wei DESC
