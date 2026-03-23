-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  Institutional DVP Settlement & Clearing System                        ║
-- ║  PostgreSQL Schema + End-to-End Sandbox Demo                           ║
-- ║                                                                        ║
-- ║  ⚠️  SANDBOX / EDUCATIONAL USE ONLY — NOT FOR PRODUCTION               ║
-- ║                                                                        ║
-- ║  Scenario: BlackRock (seller) delivers 500,000 shares of               ║
-- ║  Apple Inc. (AAPL) to State Street (buyer) for $97,500,000 USD         ║
-- ║  via SWIFT MT543 / on-chain atomic swap.                               ║
-- ║                                                                        ║
-- ║  Modeled on: JPMorgan Onyx, DTCC Project Ion, CLS                     ║
-- ╚══════════════════════════════════════════════════════════════════════════╝

-- ─────────────────────────────────────────────────────────────────────────────
-- Extensions
-- ─────────────────────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS "pgcrypto";    -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";   -- uuid_generate_v4()


-- ─────────────────────────────────────────────────────────────────────────────
-- Drop (for sandbox re-runs)
-- ─────────────────────────────────────────────────────────────────────────────

DROP TABLE IF EXISTS reconciliation_reports  CASCADE;
DROP TABLE IF EXISTS hybrid_rail_messages    CASCADE;
DROP TABLE IF EXISTS multisig_approvals      CASCADE;
DROP TABLE IF EXISTS escrow_accounts         CASCADE;
DROP TABLE IF EXISTS settlement_legs         CASCADE;
DROP TABLE IF EXISTS compliance_screenings   CASCADE;
DROP TABLE IF EXISTS outbox_events           CASCADE;
DROP TABLE IF EXISTS dvp_instructions        CASCADE;
DROP TABLE IF EXISTS cash_accounts           CASCADE;
DROP TABLE IF EXISTS custody_positions       CASCADE;
DROP TABLE IF EXISTS registered_entities     CASCADE;


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. registered_entities
--    Institutional participants — LEI-identified.
--    Mirrors GLEIF global entity registry.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE registered_entities (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_name         VARCHAR(256)    NOT NULL,
    lei                 VARCHAR(20)     NOT NULL UNIQUE,  -- ISO 17442 LEI
    entity_type         VARCHAR(50)     NOT NULL,         -- ASSET_MANAGER | CUSTODIAN | PRIME_BROKER | BANK | CCP | CSD
    jurisdiction        VARCHAR(100)    NOT NULL,
    regulator           VARCHAR(100),                     -- SEC | FCA | BaFin | MAS
    bic                 VARCHAR(11),                      -- SWIFT BIC
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE registered_entities IS
  'Institutional counterparty registry — LEI-identified. '
  'All DVP participants must appear here before any instruction can be created.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. custody_positions
--    Tokenized security positions held per entity per ISIN.
--    Two-column balance model: available + locked (prevents double-delivery).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE custody_positions (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            VARCHAR(100)     NOT NULL,    -- References LEI
    isin                 VARCHAR(12)      NOT NULL,    -- ISO 6166
    cusip                VARCHAR(9),                   -- US securities identifier
    sedol                VARCHAR(7),                   -- UK/international
    security_description VARCHAR(256),
    available_quantity   DECIMAL(38,10)   NOT NULL DEFAULT 0,
    locked_quantity      DECIMAL(38,10)   NOT NULL DEFAULT 0,
    token_address        VARCHAR(256),                 -- ERC-1400 / ERC-3643 contract
    wallet_address       VARCHAR(256),                 -- DLT wallet
    custodian            VARCHAR(100),                 -- DTC | Euroclear | Clearstream
    updated_at           TIMESTAMPTZ      NOT NULL DEFAULT NOW(),

    UNIQUE (entity_id, isin),
    CONSTRAINT chk_available_qty  CHECK (available_quantity >= 0),
    CONSTRAINT chk_locked_qty     CHECK (locked_quantity    >= 0)
);

COMMENT ON TABLE custody_positions IS
  'Two-field security ledger per (entity, ISIN). '
  'available_quantity = free to deliver. locked_quantity = reserved for pending DVP legs. '
  'SELECT … FOR UPDATE is used before every delivery reservation.';

CREATE INDEX idx_custody_entity_isin ON custody_positions (entity_id, isin);


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. cash_accounts
--    Cash/tokenized-cash/CBDC accounts per entity per currency.
--    Two-column balance model mirrors custody_positions.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE cash_accounts (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id           VARCHAR(100)    NOT NULL,    -- References LEI
    currency            VARCHAR(10)     NOT NULL,    -- ISO 4217 or token ticker
    balance             DECIMAL(38,2)   NOT NULL DEFAULT 0,
    available_balance   DECIMAL(38,2)   NOT NULL DEFAULT 0,
    locked_balance      DECIMAL(38,2)   NOT NULL DEFAULT 0,
    account_type        VARCHAR(50)     NOT NULL DEFAULT 'TOKENIZED_CASH',  -- FIAT | TOKENIZED_CASH | CBDC | STABLECOIN
    bank_aba            VARCHAR(9),                  -- FedWire routing number
    swift_bic           VARCHAR(11),
    account_number      VARCHAR(50),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    UNIQUE (entity_id, currency),
    CONSTRAINT chk_balance          CHECK (balance          >= 0),
    CONSTRAINT chk_available_balance CHECK (available_balance >= 0),
    CONSTRAINT chk_locked_balance   CHECK (locked_balance   >= 0),
    CONSTRAINT chk_balance_coherence
        CHECK (available_balance + locked_balance <= balance + 0.01)  -- tolerance for rounding
);

COMMENT ON TABLE cash_accounts IS
  'Three-field cash ledger per (entity, currency). '
  'available_balance = free to pay. locked_balance = reserved for pending DVP cash legs. '
  'SELECT … FOR UPDATE is used before every payment reservation.';

CREATE INDEX idx_cash_entity_currency ON cash_accounts (entity_id, currency);


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. dvp_instructions
--    Root record for each DVP settlement instruction.
--    State machine: INITIATED → … → SETTLED | FAILED | REVERSED
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE dvp_instructions (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trade_reference          VARCHAR(256)    NOT NULL,    -- CUSIPxTrade or LEI-based
    isin                     VARCHAR(12)     NOT NULL,
    security_type            VARCHAR(50)     NOT NULL,    -- EQUITY | CORPORATE_BOND | GOV_BOND | MBS | REPO | TOKENIZED_FUND
    quantity                 DECIMAL(38,10)  NOT NULL,
    price_per_unit           DECIMAL(38,10)  NOT NULL,
    settlement_amount        DECIMAL(38,2)   NOT NULL,    -- quantity × price_per_unit
    currency                 VARCHAR(10)     NOT NULL,

    -- Counterparty identities (LEI-based)
    seller_entity_id         VARCHAR(100)    NOT NULL,
    buyer_entity_id          VARCHAR(100)    NOT NULL,

    -- On-chain wallet addresses
    seller_wallet            VARCHAR(256)    NOT NULL,
    buyer_wallet             VARCHAR(256)    NOT NULL,

    -- Custodian identities (SWIFT BIC)
    seller_custodian         VARCHAR(11)     NOT NULL,
    buyer_custodian          VARCHAR(11)     NOT NULL,

    -- Settlement routing
    settlement_rail          VARCHAR(20)     NOT NULL,    -- SWIFT | FEDWIRE | CLS | ONCHAIN | INTERNAL
    intended_settlement_date DATE            NOT NULL,

    -- State machine
    status                   VARCHAR(30)     NOT NULL DEFAULT 'INITIATED',
    reconciliation_status    VARCHAR(20),                  -- MATCHED | SUSPENDED

    -- Settlement finality
    swap_tx_hash             VARCHAR(256),                 -- On-chain atomic swap tx
    settled_at               TIMESTAMPTZ,

    -- Failure tracking
    failure_reason           TEXT,

    -- Idempotency
    idempotency_key          VARCHAR(256)    NOT NULL UNIQUE,

    created_at               TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at               TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_quantity          CHECK (quantity          > 0),
    CONSTRAINT chk_price_per_unit    CHECK (price_per_unit    > 0),
    CONSTRAINT chk_settlement_amount CHECK (settlement_amount > 0),
    CONSTRAINT chk_status CHECK (status IN (
        'INITIATED', 'COMPLIANCE_CHECK', 'LEGS_LOCKED', 'ESCROW_FUNDED',
        'MULTISIG_PENDING', 'MULTISIG_APPROVED', 'ATOMIC_SWAP',
        'SETTLED', 'FAILED', 'REVERSED'
    ))
);

COMMENT ON TABLE dvp_instructions IS
  'Root record for each DVP settlement instruction. '
  'One row per bilateral trade. State machine enforces strict sequencing. '
  'swap_tx_hash is the on-chain atomic swap transaction — irrevocable once set.';

CREATE INDEX idx_dvp_status          ON dvp_instructions (status);
CREATE INDEX idx_dvp_isin            ON dvp_instructions (isin);
CREATE INDEX idx_dvp_seller          ON dvp_instructions (seller_entity_id);
CREATE INDEX idx_dvp_buyer           ON dvp_instructions (buyer_entity_id);
CREATE INDEX idx_dvp_settlement_date ON dvp_instructions (intended_settlement_date);
CREATE INDEX idx_dvp_trade_ref       ON dvp_instructions (trade_reference);


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. compliance_screenings
--    OFAC / sanctions / PEP screening results per instruction.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE compliance_screenings (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id       UUID            NOT NULL REFERENCES dvp_instructions(id),
    seller_entity_id     VARCHAR(100)    NOT NULL,
    buyer_entity_id      VARCHAR(100)    NOT NULL,
    is_cleared           BOOLEAN         NOT NULL,
    reason               TEXT            NOT NULL,
    screening_reference  VARCHAR(256)    NOT NULL,    -- Reference from compliance provider
    screened_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE compliance_screenings IS
  'OFAC/EU/UN sanctions + PEP screening result per DVP instruction. '
  'Both counterparties screened in parallel outside the DB transaction. '
  'Production: ComplyAdvantage, Fircosoft Compliance Link, or direct OFAC API.';

CREATE INDEX idx_screening_instruction ON compliance_screenings (instruction_id);
CREATE INDEX idx_screening_cleared     ON compliance_screenings (is_cleared);


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. settlement_legs
--    Individual security/cash legs of a DVP instruction.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE settlement_legs (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id          UUID            NOT NULL REFERENCES dvp_instructions(id),
    leg_type                VARCHAR(20)     NOT NULL,    -- SECURITY | CASH
    originator_entity_id    VARCHAR(100)    NOT NULL,
    beneficiary_entity_id   VARCHAR(100)    NOT NULL,
    amount                  DECIMAL(38,10)  NOT NULL,
    currency                VARCHAR(20)     NOT NULL,    -- ISIN (security) or ISO 4217 (cash)
    status                  VARCHAR(20)     NOT NULL DEFAULT 'PENDING',
    locked_at               TIMESTAMPTZ,
    delivered_at            TIMESTAMPTZ,
    failure_reason          TEXT,
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_leg_type CHECK (leg_type IN ('SECURITY', 'CASH')),
    CONSTRAINT chk_leg_status CHECK (status IN ('PENDING','LOCKED','IN_ESCROW','DELIVERED','RELEASED','FAILED'))
);

COMMENT ON TABLE settlement_legs IS
  'Security and cash legs of each DVP instruction. '
  'Both legs must reach IN_ESCROW before atomic swap executes. '
  'Pessimistic lock on custody_positions / cash_accounts prevents double-reservation.';

CREATE INDEX idx_legs_instruction ON settlement_legs (instruction_id);
CREATE INDEX idx_legs_type_status ON settlement_legs (leg_type, status);


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. escrow_accounts
--    Dual on-chain escrow accounts created per DVP instruction.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE escrow_accounts (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id      UUID            NOT NULL REFERENCES dvp_instructions(id),
    leg_type            VARCHAR(20)     NOT NULL,    -- SECURITY | CASH
    holder_entity_id    VARCHAR(100)    NOT NULL,    -- Entity funding the escrow
    amount              DECIMAL(38,10)  NOT NULL,
    currency            VARCHAR(20)     NOT NULL,
    status              VARCHAR(20)     NOT NULL DEFAULT 'PENDING',
    escrow_address      VARCHAR(256)    NOT NULL,    -- Smart contract address
    on_chain_tx_hash    VARCHAR(256),               -- Transfer-to-escrow tx
    funded_at           TIMESTAMPTZ,
    released_at         TIMESTAMPTZ,

    CONSTRAINT chk_escrow_leg_type CHECK (leg_type IN ('SECURITY', 'CASH')),
    CONSTRAINT chk_escrow_status   CHECK (status IN ('PENDING','LOCKED','IN_ESCROW','DELIVERED','RELEASED','FAILED'))
);

COMMENT ON TABLE escrow_accounts IS
  'On-chain escrow state per DVP instruction. '
  'Security escrow holds tokenized securities (ERC-1400). '
  'Cash escrow holds tokenized cash / CBDC. '
  'Neither can be released independently — only via atomic swap or multi-sig reversal.';

CREATE INDEX idx_escrow_instruction ON escrow_accounts (instruction_id);
CREATE INDEX idx_escrow_status      ON escrow_accounts (status);


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. multisig_approvals
--    Custodian approval votes for atomic swap authorization.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE multisig_approvals (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id  UUID            NOT NULL REFERENCES dvp_instructions(id),
    custodian_id    VARCHAR(100)    NOT NULL,    -- SWIFT BIC of custodian
    signer_id       VARCHAR(256)    NOT NULL,    -- HSM key identifier / signatory ID
    vote            VARCHAR(10)     NOT NULL,    -- APPROVE | REJECT | ABSTAIN
    signature       VARCHAR(256)    NOT NULL,    -- HSM/MPC signature (simulated in sandbox)
    voted_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    justification   TEXT,

    -- One vote per custodian per instruction
    UNIQUE (instruction_id, custodian_id),

    CONSTRAINT chk_vote CHECK (vote IN ('APPROVE', 'REJECT', 'ABSTAIN'))
);

COMMENT ON TABLE multisig_approvals IS
  'Multi-sig approval votes from custodians. '
  'Default quorum: 2-of-3 (both custodians required, CCP optional). '
  'Production: Fireblocks MPC / Thales Luna HSM / Gnosis Safe. '
  'Signature field holds ECDSA / BIP-340 signature — simulated in sandbox.';

CREATE INDEX idx_multisig_instruction ON multisig_approvals (instruction_id);
CREATE INDEX idx_multisig_vote        ON multisig_approvals (vote);


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. hybrid_rail_messages
--    Off-chain payment messages submitted to SWIFT / FedWire / CLS.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE hybrid_rail_messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id  UUID            NOT NULL REFERENCES dvp_instructions(id),
    rail            VARCHAR(20)     NOT NULL,    -- SWIFT | FEDWIRE | CLS | ONCHAIN | INTERNAL
    message_type    VARCHAR(30)     NOT NULL,    -- MT103 | MT543 | FEDWIRE_CTR | CLS_DVP_MATCHED
    payload         JSONB           NOT NULL,
    status          VARCHAR(20)     NOT NULL DEFAULT 'PENDING',
    submitted_at    TIMESTAMPTZ,
    confirmed_at    TIMESTAMPTZ,
    rail_reference  VARCHAR(256),               -- SWIFT UETR | FedWire IMAD | CLS ref

    CONSTRAINT chk_rail   CHECK (rail IN ('SWIFT','FEDWIRE','CLS','ONCHAIN','INTERNAL')),
    CONSTRAINT chk_status CHECK (status IN ('PENDING','SUBMITTED','CONFIRMED','REJECTED','TIMED_OUT'))
);

COMMENT ON TABLE hybrid_rail_messages IS
  'Off-chain payment messages per DVP instruction. '
  'SWIFT MT543/MT103: securities + cash leg affirmations. '
  'FedWire: USD same-day gross settlement (Tag 3600 CTR). '
  'CLS: FX settlement elimination of Herstatt risk. '
  'rail_reference is reconciled against on-chain settlement in the reconciliation engine.';

CREATE INDEX idx_rail_instruction  ON hybrid_rail_messages (instruction_id);
CREATE INDEX idx_rail_reference    ON hybrid_rail_messages (rail_reference);
CREATE INDEX idx_rail_status       ON hybrid_rail_messages (status);


-- ─────────────────────────────────────────────────────────────────────────────
-- 10. outbox_events
--     Reliable Kafka delivery buffer — transactional outbox pattern.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE outbox_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_id    VARCHAR(256)    NOT NULL,    -- DVP instruction ID
    event_type      VARCHAR(100)    NOT NULL,    -- dvp.initiated | dvp.settled | …
    payload         JSONB           NOT NULL,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    published_at    TIMESTAMPTZ,                -- NULL = pending Kafka delivery
    dlq_at          TIMESTAMPTZ,               -- NULL = not dead-lettered
    retry_count     INT             NOT NULL DEFAULT 0,
    next_retry_at   TIMESTAMPTZ,
    last_error      TEXT
);

COMMENT ON TABLE outbox_events IS
  'Transactional outbox buffer for Kafka. '
  'Every service writes its event in the SAME DB transaction as the business record. '
  'DVPOutboxPublisher polls this table with FOR UPDATE SKIP LOCKED '
  'and marks published_at only after successful Kafka delivery. '
  'Retry with exponential backoff (5s, 25s, 125s). DLQ after 3 failures.';

CREATE INDEX idx_outbox_unpublished ON outbox_events (created_at)
    WHERE published_at IS NULL;
CREATE INDEX idx_outbox_aggregate   ON outbox_events (aggregate_id);
CREATE INDEX idx_outbox_next_retry  ON outbox_events (next_retry_at)
    WHERE published_at IS NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- 11. reconciliation_reports
--     Post-settlement 4-source reconciliation results.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE reconciliation_reports (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id              UUID            NOT NULL REFERENCES dvp_instructions(id),
    result                      VARCHAR(20)     NOT NULL,    -- MATCHED | MISMATCH | SUSPENDED
    security_leg_verified       BOOLEAN         NOT NULL,
    cash_leg_verified           BOOLEAN         NOT NULL,
    onchain_supply_matched      BOOLEAN         NOT NULL,
    rail_confirmation_matched   BOOLEAN         NOT NULL,
    mismatches                  JSONB           NOT NULL DEFAULT '[]',
    reconciled_at               TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_recon_result CHECK (result IN ('MATCHED','MISMATCH','SUSPENDED'))
);

COMMENT ON TABLE reconciliation_reports IS
  'Post-settlement 4-source reconciliation: '
  '(1) Internal Postgres ledger vs on-chain token balances, '
  '(2) Rail payment confirmations (SWIFT ACK / FedWire IMAD / CLS confirm), '
  '(3) Escrow account closure, (4) Custodian statement match. '
  'MISMATCH immediately suspends all future settlements for the instruction '
  'and pages the operations team.';

CREATE INDEX idx_recon_instruction ON reconciliation_reports (instruction_id);
CREATE INDEX idx_recon_result      ON reconciliation_reports (result);


-- ═══════════════════════════════════════════════════════════════════════════
-- END-TO-END SANDBOX DEMO
-- Scenario: BlackRock (seller) → State Street (buyer)
--           500,000 AAPL shares at $195.00 = $97,500,000 USD
--           Settlement rail: SWIFT (MT543 + MT103) + on-chain atomic swap
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Register Institutional Participants
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO registered_entities
    (id, entity_name, lei, entity_type, jurisdiction, regulator, bic)
VALUES
    -- Seller: BlackRock (Asset Manager)
    (
        gen_random_uuid(),
        'BlackRock, Inc.',
        '549300BNMGNFKN6LAD61',
        'ASSET_MANAGER',
        'United States',
        'SEC',
        'BLRKUS33'
    ),

    -- Buyer: State Street (Custodian / Asset Manager)
    (
        gen_random_uuid(),
        'State Street Bank and Trust Company',
        '571474TGEMMWANRLN572',
        'CUSTODIAN',
        'United States',
        'OCC / FRB',
        'SBOSUS33'
    ),

    -- Seller Custodian: BNY Mellon (holds BlackRock's securities)
    (
        gen_random_uuid(),
        'The Bank of New York Mellon',
        'WFLLPEPC7FZXENRZV498',
        'CUSTODIAN',
        'United States',
        'FRB / OCC',
        'IRVTUS3N'
    ),

    -- CCP: DTCC (DTC)
    (
        gen_random_uuid(),
        'Depository Trust & Clearing Corporation',
        '213800ZBKL9BHSL2K459',
        'CCP',
        'United States',
        'SEC / CFTC',
        'DTCCUS3N'
    );


-- ─────────────────────────────────────────────────────────────────────────────
-- B. Initialize Custody Positions
--    BlackRock holds 2,000,000 AAPL shares at BNY Mellon / DTC
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO custody_positions
    (id, entity_id, isin, cusip, security_description,
     available_quantity, locked_quantity, token_address, wallet_address, custodian)
VALUES
    (
        gen_random_uuid(),
        '549300BNMGNFKN6LAD61',          -- BlackRock
        'US0378331005',                   -- AAPL ISIN
        '037833100',                      -- AAPL CUSIP
        'Apple Inc. Common Stock',
        2000000.0000000000,
        0,
        '0xAAPL_TOKEN_CONTRACT_ADDRESS',  -- Production: real ERC-1400 / ERC-3643 address
        '0xBLACKROCK_WALLET_ADDRESS',
        'DTC'
    ),

    -- State Street starts with 0 AAPL (will receive via DVP)
    (
        gen_random_uuid(),
        '571474TGEMMWANRLN572',           -- State Street
        'US0378331005',                   -- AAPL ISIN
        '037833100',
        'Apple Inc. Common Stock',
        0,
        0,
        '0xAAPL_TOKEN_CONTRACT_ADDRESS',
        '0xSTATESTREET_WALLET_ADDRESS',
        'DTC'
    );


-- ─────────────────────────────────────────────────────────────────────────────
-- C. Initialize Cash Accounts
--    State Street holds $500,000,000 USD (tokenized cash)
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO cash_accounts
    (id, entity_id, currency, balance, available_balance, locked_balance,
     account_type, bank_aba, swift_bic)
VALUES
    -- State Street: $500M USD
    (
        gen_random_uuid(),
        '571474TGEMMWANRLN572',      -- State Street
        'USD',
        500000000.00,
        500000000.00,
        0.00,
        'TOKENIZED_CASH',
        '011000028',                 -- State Street ABA routing
        'SBOSUS33'
    ),

    -- BlackRock: $10M USD (will receive $97.5M from DVP)
    (
        gen_random_uuid(),
        '549300BNMGNFKN6LAD61',      -- BlackRock
        'USD',
        10000000.00,
        10000000.00,
        0.00,
        'TOKENIZED_CASH',
        '021000018',                 -- BNY Mellon ABA routing (BlackRock's banking partner)
        'BLRKUS33'
    );


-- ─────────────────────────────────────────────────────────────────────────────
-- D. Create DVP Instruction
--    BlackRock sells 500,000 AAPL @ $195.00 to State Street
--    Settlement: SWIFT MT543 + on-chain atomic swap (T+0)
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO dvp_instructions (
    id, trade_reference, isin, security_type,
    quantity, price_per_unit, settlement_amount, currency,
    seller_entity_id, buyer_entity_id,
    seller_wallet, buyer_wallet,
    seller_custodian, buyer_custodian,
    settlement_rail, intended_settlement_date,
    status, idempotency_key, created_at
)
VALUES (
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',    -- Fixed for demo
    'BLK-SST-AAPL-20260320-001',               -- Trade reference
    'US0378331005',                             -- AAPL ISIN
    'EQUITY',
    500000.0000000000,                          -- 500,000 shares
    195.00,                                     -- $195.00 per share
    97500000.00,                                -- $97,500,000 total
    'USD',
    '549300BNMGNFKN6LAD61',                    -- BlackRock (seller)
    '571474TGEMMWANRLN572',                    -- State Street (buyer)
    '0xBLACKROCK_WALLET_ADDRESS',
    '0xSTATESTREET_WALLET_ADDRESS',
    'IRVTUS3N',                                -- BNY Mellon (seller's custodian)
    'SBOSUS33',                                -- State Street (buyer is also custodian)
    'SWIFT',
    '2026-03-20',                              -- T+0 (today)
    'INITIATED',
    'DVP-BLK-SST-AAPL-20260320-001',
    NOW()
);


-- ─────────────────────────────────────────────────────────────────────────────
-- E. Compliance Screening — Both Counterparties Cleared
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO compliance_screenings
    (id, instruction_id, seller_entity_id, buyer_entity_id,
     is_cleared, reason, screening_reference, screened_at)
VALUES (
    gen_random_uuid(),
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    '549300BNMGNFKN6LAD61',
    '571474TGEMMWANRLN572',
    TRUE,
    'Both counterparties cleared OFAC SDN, EU/UN consolidated, and PEP lists. '
    'No adverse media. LEI verified with GLEIF.',
    'COMPLY-ADV-20260320-BLK-SST-A1B2C3D4|COMPLY-ADV-20260320-SST-BLK-E5F6G7H8',
    NOW()
);

-- Advance status to COMPLIANCE_CHECK
UPDATE dvp_instructions
SET status     = 'COMPLIANCE_CHECK',
    updated_at = NOW()
WHERE id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';


-- ─────────────────────────────────────────────────────────────────────────────
-- F. Lock Settlement Legs
--    Atomically reserve securities (BlackRock) + cash (State Street)
-- ─────────────────────────────────────────────────────────────────────────────

-- Lock security leg (simulates SELECT … FOR UPDATE on custody_positions)
UPDATE custody_positions
SET available_quantity = available_quantity - 500000,
    locked_quantity    = locked_quantity    + 500000,
    updated_at         = NOW()
WHERE entity_id = '549300BNMGNFKN6LAD61'
  AND isin      = 'US0378331005';

-- Lock cash leg (simulates SELECT … FOR UPDATE on cash_accounts)
UPDATE cash_accounts
SET available_balance = available_balance - 97500000,
    locked_balance    = locked_balance    + 97500000,
    updated_at        = NOW()
WHERE entity_id = '571474TGEMMWANRLN572'
  AND currency  = 'USD';

-- Insert security leg
INSERT INTO settlement_legs
    (id, instruction_id, leg_type, originator_entity_id, beneficiary_entity_id,
     amount, currency, status, locked_at)
VALUES (
    'aaaa0001-0000-0000-0000-000000000001',
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'SECURITY',
    '549300BNMGNFKN6LAD61',     -- BlackRock (seller/originator)
    '571474TGEMMWANRLN572',     -- State Street (buyer/beneficiary)
    500000.0000000000,
    'US0378331005',             -- ISIN as currency identifier for securities
    'LOCKED',
    NOW()
);

-- Insert cash leg
INSERT INTO settlement_legs
    (id, instruction_id, leg_type, originator_entity_id, beneficiary_entity_id,
     amount, currency, status, locked_at)
VALUES (
    'bbbb0002-0000-0000-0000-000000000002',
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'CASH',
    '571474TGEMMWANRLN572',     -- State Street (buyer/originator)
    '549300BNMGNFKN6LAD61',    -- BlackRock (seller/beneficiary)
    97500000.00,
    'USD',
    'LOCKED',
    NOW()
);

-- Advance instruction status
UPDATE dvp_instructions
SET status     = 'LEGS_LOCKED',
    updated_at = NOW()
WHERE id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

-- Outbox event: legs_locked
INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at)
VALUES (
    gen_random_uuid(),
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'dvp.legs_locked',
    '{
        "instruction_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "security_leg_id": "aaaa0001-0000-0000-0000-000000000001",
        "cash_leg_id": "bbbb0002-0000-0000-0000-000000000002",
        "isin": "US0378331005",
        "quantity": "500000",
        "settlement_amount": "97500000",
        "currency": "USD"
    }'::jsonb,
    NOW()
);


-- ─────────────────────────────────────────────────────────────────────────────
-- G. Fund Escrow Accounts
--    On-chain transfers to smart contract escrow addresses
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO escrow_accounts
    (id, instruction_id, leg_type, holder_entity_id, amount, currency,
     status, escrow_address, on_chain_tx_hash, funded_at)
VALUES
    -- Security escrow (BlackRock's AAPL tokens)
    (
        'cccc0003-0000-0000-0000-000000000003',
        'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        'SECURITY',
        '549300BNMGNFKN6LAD61',
        500000.0000000000,
        'US0378331005',
        'IN_ESCROW',
        '0xSECURITY_ESCROW_CONTRACT_ADDRESS',
        '0xabc123def456789012345678901234567890123456789012345678901234abcd',  -- Simulated tx hash
        NOW()
    ),

    -- Cash escrow (State Street's USD tokenized cash)
    (
        'dddd0004-0000-0000-0000-000000000004',
        'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        'CASH',
        '571474TGEMMWANRLN572',
        97500000.00,
        'USD',
        'IN_ESCROW',
        '0xCASH_ESCROW_CONTRACT_ADDRESS',
        '0xdef456abc123012345678901234567890123456789012345678901234567def0',   -- Simulated tx hash
        NOW()
    );

-- Update legs to IN_ESCROW
UPDATE settlement_legs
SET status     = 'IN_ESCROW',
    updated_at = NOW()
WHERE instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

-- Advance instruction status
UPDATE dvp_instructions
SET status     = 'ESCROW_FUNDED',
    updated_at = NOW()
WHERE id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

-- Outbox event: escrow_funded
INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at)
VALUES (
    gen_random_uuid(),
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'dvp.escrow_funded',
    '{
        "instruction_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "security_escrow_id": "cccc0003-0000-0000-0000-000000000003",
        "cash_escrow_id": "dddd0004-0000-0000-0000-000000000004",
        "security_tx_hash": "0xabc123def456789012345678901234567890123456789012345678901234abcd",
        "cash_tx_hash": "0xdef456abc123012345678901234567890123456789012345678901234567def0"
    }'::jsonb,
    NOW()
);


-- ─────────────────────────────────────────────────────────────────────────────
-- H. Submit SWIFT Messages (MT543 + MT103)
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO hybrid_rail_messages
    (id, instruction_id, rail, message_type, payload, status, submitted_at, rail_reference)
VALUES
    -- MT543: Deliver Against Payment (Securities Leg — Seller side)
    (
        gen_random_uuid(),
        'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        'SWIFT',
        'MT543',
        '{
            "message_type": "MT543",
            "uetr": "a1b2c3d4-e5f6-7890-abcd-ef0123456789",
            "sender_bic": "IRVTUS3N",
            "receiver_bic": "SBOSUS33",
            "isin": "US0378331005",
            "quantity": "500000",
            "settlement_amount": "97500000",
            "currency": "USD",
            "settlement_date": "2026-03-20",
            "trade_reference": "BLK-SST-AAPL-20260320-001",
            "seller_account": "0xBLACKROCK_WALLET_ADDRESS",
            "buyer_account": "0xSTATESTREET_WALLET_ADDRESS"
        }'::jsonb,
        'SUBMITTED',
        NOW(),
        'a1b2c3d4-e5f6-7890-abcd-ef0123456789'    -- SWIFT UETR
    ),

    -- MT103: Cash Leg Credit Transfer (Buyer pays Seller)
    (
        gen_random_uuid(),
        'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        'SWIFT',
        'MT103',
        '{
            "message_type": "MT103",
            "uetr": "b2c3d4e5-f6a1-8901-bcde-f01234567890",
            "sender_bic": "SBOSUS33",
            "receiver_bic": "IRVTUS3N",
            "amount": "97500000",
            "currency": "USD",
            "value_date": "2026-03-20",
            "remittance_info": "DVP/BLK-SST-AAPL-20260320-001/US0378331005"
        }'::jsonb,
        'SUBMITTED',
        NOW(),
        'b2c3d4e5-f6a1-8901-bcde-f01234567890'    -- SWIFT UETR
    );

-- Advance to MULTISIG_PENDING
UPDATE dvp_instructions
SET status     = 'MULTISIG_PENDING',
    updated_at = NOW()
WHERE id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';


-- ─────────────────────────────────────────────────────────────────────────────
-- I. Multi-Sig Approval Votes
--    BNY Mellon (seller's custodian) + State Street (buyer's custodian)
--    Both APPROVE → quorum of 2 reached → MULTISIG_APPROVED
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO multisig_approvals
    (id, instruction_id, custodian_id, signer_id, vote, signature, voted_at)
VALUES
    -- Vote 1: BNY Mellon (BlackRock's custodian) approves
    (
        gen_random_uuid(),
        'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        'IRVTUS3N',                          -- BNY Mellon SWIFT BIC
        'HSM-BNYM-SIGNER-KEY-001',           -- Production: CloudHSM key ID
        'APPROVE',
        'sha256:bnym_simulated_ecdsa_signature_approval_f47ac10b_20260320',
        NOW()
    ),

    -- Vote 2: State Street (buyer, also custodian) approves
    (
        gen_random_uuid(),
        'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        'SBOSUS33',                          -- State Street SWIFT BIC
        'HSM-SST-SIGNER-KEY-007',
        'APPROVE',
        'sha256:sst_simulated_ecdsa_signature_approval_f47ac10b_20260320',
        NOW()
    );

-- Quorum reached (2-of-2 APPROVE, 0 REJECT) — advance to MULTISIG_APPROVED
UPDATE dvp_instructions
SET status     = 'MULTISIG_APPROVED',
    updated_at = NOW()
WHERE id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

-- Outbox event: multisig_approved
INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at)
VALUES (
    gen_random_uuid(),
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'dvp.multisig_approved',
    '{"instruction_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479", "quorum": 2, "required": 2}'::jsonb,
    NOW()
);


-- ─────────────────────────────────────────────────────────────────────────────
-- J. Atomic Swap — IRREVOCABLE Settlement
--    Both escrow accounts released simultaneously on-chain
--    Securities → State Street | Cash → BlackRock
-- ─────────────────────────────────────────────────────────────────────────────

-- Mark as ATOMIC_SWAP (irrevocable — crash recovery reads this to avoid re-entry)
UPDATE dvp_instructions
SET status     = 'ATOMIC_SWAP',
    updated_at = NOW()
WHERE id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

-- Simulated on-chain atomic swap tx hash
-- Production: This is the hash of the smart contract atomic swap tx
-- containing BOTH escrow releases in a single tx

-- Finalize settlement — atomic ledger update
BEGIN;

    -- 1. Mark instruction as SETTLED
    UPDATE dvp_instructions
    SET status        = 'SETTLED',
        swap_tx_hash  = '0xATOMIC_SWAP_TX_HASH_f47ac10b_20260320_IRREVOCABLE',
        settled_at    = NOW(),
        updated_at    = NOW()
    WHERE id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

    -- 2. Release security lock from BlackRock (deduct locked_quantity)
    UPDATE custody_positions
    SET locked_quantity = locked_quantity - 500000,
        updated_at      = NOW()
    WHERE entity_id = '549300BNMGNFKN6LAD61'
      AND isin      = 'US0378331005';

    -- 3. Release cash lock from State Street (deduct balance + locked)
    UPDATE cash_accounts
    SET balance         = balance         - 97500000,
        locked_balance  = locked_balance  - 97500000,
        updated_at      = NOW()
    WHERE entity_id = '571474TGEMMWANRLN572'
      AND currency  = 'USD';

    -- 4. Credit AAPL to State Street (buyer receives securities)
    UPDATE custody_positions
    SET available_quantity = available_quantity + 500000,
        updated_at         = NOW()
    WHERE entity_id = '571474TGEMMWANRLN572'
      AND isin      = 'US0378331005';

    -- 5. Credit USD to BlackRock (seller receives cash)
    UPDATE cash_accounts
    SET balance           = balance           + 97500000,
        available_balance = available_balance + 97500000,
        updated_at        = NOW()
    WHERE entity_id = '549300BNMGNFKN6LAD61'
      AND currency  = 'USD';

    -- 6. Mark escrow accounts as DELIVERED
    UPDATE escrow_accounts
    SET status       = 'DELIVERED',
        released_at  = NOW()
    WHERE instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

    -- 7. Mark settlement legs as DELIVERED
    UPDATE settlement_legs
    SET status       = 'DELIVERED',
        delivered_at = NOW(),
        updated_at   = NOW()
    WHERE instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

    -- 8. Outbox event: settled (triggers MiFID II / EMIR reporting, DTCC STP)
    INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at)
    VALUES (
        gen_random_uuid(),
        'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        'dvp.settled',
        '{
            "instruction_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
            "swap_tx_hash": "0xATOMIC_SWAP_TX_HASH_f47ac10b_20260320_IRREVOCABLE",
            "seller_entity_id": "549300BNMGNFKN6LAD61",
            "buyer_entity_id": "571474TGEMMWANRLN572",
            "isin": "US0378331005",
            "security_description": "Apple Inc. Common Stock",
            "quantity": "500000",
            "settlement_amount": "97500000",
            "currency": "USD",
            "rail": "SWIFT"
        }'::jsonb,
        NOW()
    );

COMMIT;


-- ─────────────────────────────────────────────────────────────────────────────
-- K. Confirm SWIFT Messages (simulating ACK from SWIFT network)
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE hybrid_rail_messages
SET status       = 'CONFIRMED',
    confirmed_at = NOW()
WHERE instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479'
  AND rail = 'SWIFT';


-- ─────────────────────────────────────────────────────────────────────────────
-- L. Post-Settlement Reconciliation
--    4-source check: ledger ✓ | escrow ✓ | legs ✓ | rail ✓ → MATCHED
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO reconciliation_reports
    (id, instruction_id, result,
     security_leg_verified, cash_leg_verified,
     onchain_supply_matched, rail_confirmation_matched,
     mismatches, reconciled_at)
VALUES (
    gen_random_uuid(),
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'MATCHED',
    TRUE,   -- State Street now holds 500,000 AAPL on-chain and in ledger
    TRUE,   -- BlackRock now holds $107.5M USD ($10M + $97.5M) in ledger
    TRUE,   -- Escrow accounts marked DELIVERED, on-chain balances match
    TRUE,   -- MT543 + MT103 both CONFIRMED
    '[]'::jsonb,
    NOW()
);

-- Mark reconciliation status on instruction
UPDATE dvp_instructions
SET reconciliation_status = 'MATCHED',
    updated_at            = NOW()
WHERE id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

-- Outbox event: reconciliation passed
INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at)
VALUES (
    gen_random_uuid(),
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'dvp.reconciliation_matched',
    '{"instruction_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479", "result": "MATCHED"}'::jsonb,
    NOW()
);


-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- V1. Full DVP Instruction Overview
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    d.trade_reference,
    d.isin,
    d.security_type,
    d.quantity                                AS shares_transferred,
    '$' || TO_CHAR(d.settlement_amount, 'FM999,999,999.00') AS settlement_amount_usd,
    d.currency,
    d.settlement_rail,
    d.status,
    d.reconciliation_status,
    d.intended_settlement_date,
    d.settled_at,
    d.swap_tx_hash
FROM dvp_instructions d
WHERE d.id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';


-- ─────────────────────────────────────────────────────────────────────────────
-- V2. Post-Settlement Position Verification
--    Expected:
--      BlackRock AAPL:  1,500,000 available (delivered 500K)
--      State Street AAPL: 500,000 available (received 500K)
--      BlackRock USD:  $107,500,000 ($10M + $97.5M received)
--      State Street USD: $402,500,000 ($500M - $97.5M paid)
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    e.entity_name,
    cp.isin,
    cp.security_description,
    cp.available_quantity,
    cp.locked_quantity,
    cp.custodian
FROM custody_positions cp
JOIN registered_entities e ON e.lei = cp.entity_id
WHERE cp.isin = 'US0378331005'
ORDER BY e.entity_name;

SELECT
    e.entity_name,
    ca.currency,
    '$' || TO_CHAR(ca.balance,           'FM999,999,999.00') AS total_balance,
    '$' || TO_CHAR(ca.available_balance, 'FM999,999,999.00') AS available_balance,
    '$' || TO_CHAR(ca.locked_balance,    'FM999,999,999.00') AS locked_balance,
    ca.account_type
FROM cash_accounts ca
JOIN registered_entities e ON e.lei = ca.entity_id
ORDER BY e.entity_name;


-- ─────────────────────────────────────────────────────────────────────────────
-- V3. Settlement Legs — Delivery Confirmation
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    sl.leg_type,
    sl.originator_entity_id,
    sl.beneficiary_entity_id,
    sl.amount,
    sl.currency,
    sl.status,
    sl.locked_at,
    sl.delivered_at
FROM settlement_legs sl
WHERE sl.instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479'
ORDER BY sl.leg_type;


-- ─────────────────────────────────────────────────────────────────────────────
-- V4. Escrow Account Closure Verification
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    ea.leg_type,
    ea.holder_entity_id,
    ea.amount,
    ea.currency,
    ea.status,
    ea.escrow_address,
    LEFT(ea.on_chain_tx_hash, 20) || '...' AS tx_hash_preview,
    ea.funded_at,
    ea.released_at
FROM escrow_accounts ea
WHERE ea.instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';


-- ─────────────────────────────────────────────────────────────────────────────
-- V5. Multi-Sig Approval Audit Trail
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    ma.custodian_id,
    ma.signer_id,
    ma.vote,
    LEFT(ma.signature, 40) || '...' AS signature_preview,
    ma.voted_at
FROM multisig_approvals ma
WHERE ma.instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479'
ORDER BY ma.voted_at;

-- Quorum check
SELECT
    COUNT(*) FILTER (WHERE vote = 'APPROVE') AS approve_votes,
    COUNT(*) FILTER (WHERE vote = 'REJECT')  AS reject_votes,
    COUNT(*) FILTER (WHERE vote = 'ABSTAIN') AS abstain_votes,
    CASE
        WHEN COUNT(*) FILTER (WHERE vote = 'APPROVE') >= 2
         AND COUNT(*) FILTER (WHERE vote = 'REJECT')  = 0
        THEN 'QUORUM MET — ATOMIC SWAP AUTHORIZED'
        ELSE 'QUORUM NOT MET'
    END AS quorum_status
FROM multisig_approvals
WHERE instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';


-- ─────────────────────────────────────────────────────────────────────────────
-- V6. Hybrid Rail Message Status (SWIFT ACK verification)
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    hrm.rail,
    hrm.message_type,
    hrm.status,
    hrm.rail_reference                        AS uetr_or_imad,
    hrm.submitted_at,
    hrm.confirmed_at
FROM hybrid_rail_messages hrm
WHERE hrm.instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479'
ORDER BY hrm.submitted_at;


-- ─────────────────────────────────────────────────────────────────────────────
-- V7. Outbox Event Delivery Queue (Kafka feed)
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    event_type,
    created_at,
    published_at,
    CASE WHEN published_at IS NULL THEN 'PENDING' ELSE 'DELIVERED' END AS kafka_status
FROM outbox_events
WHERE aggregate_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479'
ORDER BY created_at;


-- ─────────────────────────────────────────────────────────────────────────────
-- V8. Reconciliation Report
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    rr.result,
    rr.security_leg_verified,
    rr.cash_leg_verified,
    rr.onchain_supply_matched,
    rr.rail_confirmation_matched,
    jsonb_array_length(rr.mismatches)   AS mismatch_count,
    rr.reconciled_at
FROM reconciliation_reports rr
WHERE rr.instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';


-- ─────────────────────────────────────────────────────────────────────────────
-- V9. Full Settlement Summary Dashboard
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    d.trade_reference,
    d.status                                                AS settlement_status,
    d.reconciliation_status,
    TO_CHAR(d.quantity, 'FM9,999,999')                      AS shares_settled,
    '$' || TO_CHAR(d.settlement_amount, 'FM999,999,999.00') AS notional_settled,
    cs.is_cleared                                           AS compliance_cleared,
    (
        SELECT COUNT(*) FROM multisig_approvals ma
        WHERE ma.instruction_id = d.id AND ma.vote = 'APPROVE'
    )                                                       AS multisig_approvals,
    (
        SELECT COUNT(*) FROM hybrid_rail_messages hrm
        WHERE hrm.instruction_id = d.id AND hrm.status = 'CONFIRMED'
    )                                                       AS rail_messages_confirmed,
    rr.result                                               AS reconciliation_result,
    LEFT(d.swap_tx_hash, 30) || '...'                       AS atomic_swap_tx,
    d.settled_at
FROM dvp_instructions d
LEFT JOIN compliance_screenings cs  ON cs.instruction_id = d.id
LEFT JOIN reconciliation_reports rr ON rr.instruction_id = d.id
WHERE d.id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';


-- ─────────────────────────────────────────────────────────────────────────────
-- V10. Full State Machine Audit Trail
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    event_type                          AS state_transition,
    created_at                          AS occurred_at,
    payload->>'instruction_id'          AS instruction_id
FROM outbox_events
WHERE aggregate_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479'
ORDER BY created_at;

/*
══════════════════════════════════════════════════════════════════════════════
EXPECTED FINAL STATE (V9 Summary Query)
══════════════════════════════════════════════════════════════════════════════

  trade_reference           = BLK-SST-AAPL-20260320-001
  settlement_status         = SETTLED
  reconciliation_status     = MATCHED
  shares_settled            = 500,000
  notional_settled          = $97,500,000.00
  compliance_cleared        = true
  multisig_approvals        = 2
  rail_messages_confirmed   = 2     (MT543 + MT103)
  reconciliation_result     = MATCHED
  atomic_swap_tx            = 0xATOMIC_SWAP_TX_HASH_f47ac10...
  settled_at                = [timestamp]

EXPECTED POSITION STATE (V2 Queries)
══════════════════════════════════════════════════════════════════════════════

  Custody Positions (AAPL):
  ┌──────────────────────────────┬─────────────────────────┬────────────┐
  │ Entity                       │ Available Quantity       │ Locked     │
  ├──────────────────────────────┼─────────────────────────┼────────────┤
  │ BlackRock, Inc.              │ 1,500,000               │ 0          │
  │ State Street Bank and Trust  │   500,000               │ 0          │
  └──────────────────────────────┴─────────────────────────┴────────────┘

  Cash Accounts (USD):
  ┌──────────────────────────────┬────────────────────┬────────┐
  │ Entity                       │ Available Balance   │ Locked │
  ├──────────────────────────────┼────────────────────┼────────┤
  │ BlackRock, Inc.              │ $107,500,000.00    │ $0     │
  │ State Street Bank and Trust  │ $402,500,000.00    │ $0     │
  └──────────────────────────────┴────────────────────┴────────┘

STATE MACHINE TRACE:
  dvp.initiated              → INITIATED
  dvp.legs_locked            → LEGS_LOCKED
  dvp.escrow_funded          → ESCROW_FUNDED
  dvp.multisig_approved      → MULTISIG_APPROVED
  dvp.atomic_swap_initiated  → ATOMIC_SWAP
  dvp.settled                → SETTLED (irrevocable)
  dvp.reconciliation_matched → MATCHED

KAFKA TOPICS PRODUCED:
  dvp.initiated | dvp.legs_locked | dvp.escrow_funded
  dvp.multisig_vote (×2) | dvp.multisig_approved
  dvp.atomic_swap_initiated | dvp.settled | dvp.reconciliation_matched

══════════════════════════════════════════════════════════════════════════════
*/
