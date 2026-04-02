-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  Institutional DVP Settlement & Clearing System                        ║
-- ║  PostgreSQL Schema + End-to-End Sandbox Demo                           ║
-- ║                                                                        ║
-- ║  ⚠️  SANDBOX / EDUCATIONAL USE ONLY — NOT FOR PRODUCTION               ║
-- ║                                                                        ║
-- ║  Architecture: FULLY APPEND-ONLY with event-sourced state machines.    ║
-- ║  Every table is INSERT-only — UPDATE and DELETE are prohibited at       ║
-- ║  the database level via BEFORE triggers.                               ║
-- ║                                                                        ║
-- ║  Financial mutations: Double-entry via security_ledger / cash_ledger.  ║
-- ║  Balances: Derived from ledger sums (custody_balances, cash_balances). ║
-- ║  State machines: Event log tables + current-state views.               ║
-- ║                                                                        ║
-- ║  Scenario: BlackRock (seller) delivers 500,000 shares of               ║
-- ║  Apple Inc. (AAPL) to State Street (buyer) for $97,500,000 USD        ║
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

DROP TABLE IF EXISTS rbac_actor_roles CASCADE;
DROP TABLE IF EXISTS rbac_role_permissions CASCADE;
DROP TABLE IF EXISTS rbac_roles CASCADE;
DROP TABLE IF EXISTS audit_log CASCADE;
DROP VIEW  IF EXISTS outbox_events_current          CASCADE;
DROP VIEW  IF EXISTS hybrid_rail_messages_current    CASCADE;
DROP VIEW  IF EXISTS escrow_accounts_current         CASCADE;
DROP VIEW  IF EXISTS settlement_legs_current         CASCADE;
DROP VIEW  IF EXISTS dvp_instructions_current        CASCADE;
DROP VIEW  IF EXISTS cash_balances                   CASCADE;
DROP VIEW  IF EXISTS custody_balances                CASCADE;
DROP TABLE IF EXISTS consumed_events                 CASCADE;
DROP TABLE IF EXISTS outbox_delivery_log             CASCADE;
DROP TABLE IF EXISTS reconciliation_reports          CASCADE;
DROP TABLE IF EXISTS hybrid_rail_message_events      CASCADE;
DROP TABLE IF EXISTS hybrid_rail_messages            CASCADE;
DROP TABLE IF EXISTS multisig_approvals              CASCADE;
DROP TABLE IF EXISTS escrow_account_events           CASCADE;
DROP TABLE IF EXISTS escrow_accounts                 CASCADE;
DROP TABLE IF EXISTS settlement_leg_events           CASCADE;
DROP TABLE IF EXISTS settlement_legs                 CASCADE;
DROP TABLE IF EXISTS compliance_screenings           CASCADE;
DROP TABLE IF EXISTS dvp_instruction_events          CASCADE;
DROP TABLE IF EXISTS outbox_events                   CASCADE;
DROP TABLE IF EXISTS dvp_instructions                CASCADE;
DROP TABLE IF EXISTS cash_ledger                     CASCADE;
DROP TABLE IF EXISTS security_ledger                 CASCADE;
DROP TABLE IF EXISTS cash_accounts                   CASCADE;
DROP TABLE IF EXISTS custody_positions               CASCADE;
DROP TABLE IF EXISTS registered_entities             CASCADE;

DROP FUNCTION IF EXISTS deny_mutation()              CASCADE;
DROP FUNCTION IF EXISTS check_security_balance()     CASCADE;
DROP FUNCTION IF EXISTS check_cash_balance()         CASCADE;


-- ═══════════════════════════════════════════════════════════════════════════
-- IMMUTABILITY ENFORCEMENT
-- Every table is append-only. UPDATE and DELETE are prohibited.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION deny_mutation() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Append-only: % on table "%" is prohibited',
        TG_OP, TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. registered_entities
--    Institutional participants — LEI-identified. Immutable.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE registered_entities (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_name         VARCHAR(256)    NOT NULL,
    lei                 VARCHAR(20)     NOT NULL UNIQUE,
    entity_type         VARCHAR(50)     NOT NULL,
    jurisdiction        VARCHAR(100)    NOT NULL,
    regulator           VARCHAR(100),
    bic                 VARCHAR(11),
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE registered_entities IS
  'Institutional counterparty registry — LEI-identified. Immutable.';

CREATE TRIGGER trg_deny_update_registered_entities
    BEFORE UPDATE ON registered_entities FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_registered_entities
    BEFORE DELETE ON registered_entities FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. custody_positions
--    Registration table for tokenized security positions. Immutable metadata.
--    Balances derived from security_ledger via custody_balances view.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE custody_positions (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            VARCHAR(100)     NOT NULL,
    isin                 VARCHAR(12)      NOT NULL,
    cusip                VARCHAR(9),
    sedol                VARCHAR(7),
    security_description VARCHAR(256),
    token_address        VARCHAR(256),
    wallet_address       VARCHAR(256),
    custodian            VARCHAR(100),
    created_at           TIMESTAMPTZ      NOT NULL DEFAULT NOW(),

    UNIQUE (entity_id, isin)
);

COMMENT ON TABLE custody_positions IS
  'Registration table per (entity, ISIN). Immutable metadata — no balance columns. '
  'Balances derived from security_ledger via custody_balances view.';

CREATE INDEX idx_custody_entity_isin ON custody_positions (entity_id, isin);

CREATE TRIGGER trg_deny_update_custody_positions
    BEFORE UPDATE ON custody_positions FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_custody_positions
    BEFORE DELETE ON custody_positions FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. cash_accounts
--    Registration table for cash/tokenized-cash accounts. Immutable metadata.
--    Balances derived from cash_ledger via cash_balances view.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE cash_accounts (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id           VARCHAR(100)    NOT NULL,
    currency            VARCHAR(10)     NOT NULL,
    account_type        VARCHAR(50)     NOT NULL DEFAULT 'TOKENIZED_CASH',
    bank_aba            VARCHAR(9),
    swift_bic           VARCHAR(11),
    account_number      VARCHAR(50),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    UNIQUE (entity_id, currency)
);

COMMENT ON TABLE cash_accounts IS
  'Registration table per (entity, currency). Immutable metadata — no balance columns. '
  'Balances derived from cash_ledger via cash_balances view.';

CREATE INDEX idx_cash_entity_currency ON cash_accounts (entity_id, currency);

CREATE TRIGGER trg_deny_update_cash_accounts
    BEFORE UPDATE ON cash_accounts FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_cash_accounts
    BEFORE DELETE ON cash_accounts FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 3a. security_ledger (append-only)
--     Every security balance change is an immutable entry.
--     Signed amounts: +credit, -debit.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE security_ledger (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id       VARCHAR(100)    NOT NULL,
    isin            VARCHAR(12)     NOT NULL,
    pool            VARCHAR(10)     NOT NULL,
    amount          DECIMAL(38,10)  NOT NULL,
    instruction_id  UUID,
    reason          VARCHAR(50)     NOT NULL,
    request_id      UUID,
    trace_id        UUID,
    actor           VARCHAR(256),
    actor_role      VARCHAR(50),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_sec_pool CHECK (pool IN ('AVAILABLE','LOCKED'))
);

COMMENT ON TABLE security_ledger IS
  'Append-only ledger for security position changes. Every lock, unlock, '
  'delivery, and credit is an immutable entry with signed amount. '
  'Current balances derived by summing entries per (entity_id, isin, pool).';

CREATE INDEX idx_sec_ledger_entity_isin ON security_ledger (entity_id, isin);
CREATE INDEX idx_sec_ledger_instruction ON security_ledger (instruction_id);

CREATE TRIGGER trg_deny_update_security_ledger
    BEFORE UPDATE ON security_ledger FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_security_ledger
    BEFORE DELETE ON security_ledger FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 3b. cash_ledger (append-only)
--     Every cash balance change is an immutable entry.
--     Signed amounts: +credit, -debit.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE cash_ledger (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id       VARCHAR(100)    NOT NULL,
    currency        VARCHAR(10)     NOT NULL,
    pool            VARCHAR(10)     NOT NULL,
    amount          DECIMAL(38,2)   NOT NULL,
    instruction_id  UUID,
    reason          VARCHAR(50)     NOT NULL,
    request_id      UUID,
    trace_id        UUID,
    actor           VARCHAR(256),
    actor_role      VARCHAR(50),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_cash_pool CHECK (pool IN ('AVAILABLE','LOCKED'))
);

COMMENT ON TABLE cash_ledger IS
  'Append-only ledger for cash balance changes. Every lock, unlock, '
  'payment, and credit is an immutable entry with signed amount. '
  'Current balances derived by summing entries per (entity_id, currency, pool).';

CREATE INDEX idx_cash_ledger_entity_currency ON cash_ledger (entity_id, currency);
CREATE INDEX idx_cash_ledger_instruction ON cash_ledger (instruction_id);

CREATE TRIGGER trg_deny_update_cash_ledger
    BEFORE UPDATE ON cash_ledger FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_cash_ledger
    BEFORE DELETE ON cash_ledger FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 3c. custody_balances (derived view)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE VIEW custody_balances AS
SELECT entity_id, isin,
    COALESCE(SUM(amount) FILTER (WHERE pool = 'AVAILABLE'), 0) AS available_quantity,
    COALESCE(SUM(amount) FILTER (WHERE pool = 'LOCKED'), 0)    AS locked_quantity
FROM security_ledger
GROUP BY entity_id, isin;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3d. cash_balances (derived view)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE VIEW cash_balances AS
SELECT entity_id, currency,
    COALESCE(SUM(amount), 0)                                     AS balance,
    COALESCE(SUM(amount) FILTER (WHERE pool = 'AVAILABLE'), 0)   AS available_balance,
    COALESCE(SUM(amount) FILTER (WHERE pool = 'LOCKED'), 0)      AS locked_balance
FROM cash_ledger
GROUP BY entity_id, currency;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3e. Non-negative balance triggers
--     AFTER INSERT triggers that validate derived balances >= 0.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION check_security_balance() RETURNS TRIGGER AS $$
DECLARE
    derived_balance DECIMAL(38,10);
BEGIN
    SELECT COALESCE(SUM(amount), 0) INTO derived_balance
    FROM security_ledger
    WHERE entity_id = NEW.entity_id
      AND isin = NEW.isin
      AND pool = NEW.pool;

    IF derived_balance < 0 THEN
        RAISE EXCEPTION 'Negative security balance: entity=%, isin=%, pool=%, balance=%',
            NEW.entity_id, NEW.isin, NEW.pool, derived_balance;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_security_balance
    AFTER INSERT ON security_ledger
    FOR EACH ROW EXECUTE FUNCTION check_security_balance();


CREATE OR REPLACE FUNCTION check_cash_balance() RETURNS TRIGGER AS $$
DECLARE
    derived_balance DECIMAL(38,2);
BEGIN
    SELECT COALESCE(SUM(amount), 0) INTO derived_balance
    FROM cash_ledger
    WHERE entity_id = NEW.entity_id
      AND currency = NEW.currency
      AND pool = NEW.pool;

    IF derived_balance < 0 THEN
        RAISE EXCEPTION 'Negative cash balance: entity=%, currency=%, pool=%, balance=%',
            NEW.entity_id, NEW.currency, NEW.pool, derived_balance;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_cash_balance
    AFTER INSERT ON cash_ledger
    FOR EACH ROW EXECUTE FUNCTION check_cash_balance();


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. dvp_instructions
--    Immutable creation record for each DVP settlement instruction.
--    State machine transitions stored in dvp_instruction_events.
--    Current state derived via dvp_instructions_current view.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE dvp_instructions (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trade_reference          VARCHAR(256)    NOT NULL,
    isin                     VARCHAR(12)     NOT NULL,
    security_type            VARCHAR(50)     NOT NULL,
    quantity                 DECIMAL(38,10)  NOT NULL,
    price_per_unit           DECIMAL(38,10)  NOT NULL,
    settlement_amount        DECIMAL(38,2)   NOT NULL,
    currency                 VARCHAR(10)     NOT NULL,
    seller_entity_id         VARCHAR(100)    NOT NULL,
    buyer_entity_id          VARCHAR(100)    NOT NULL,
    seller_wallet            VARCHAR(256)    NOT NULL,
    buyer_wallet             VARCHAR(256)    NOT NULL,
    seller_custodian         VARCHAR(11)     NOT NULL,
    buyer_custodian          VARCHAR(11)     NOT NULL,
    settlement_rail          VARCHAR(20)     NOT NULL,
    intended_settlement_date DATE            NOT NULL,
    idempotency_key          VARCHAR(256)    NOT NULL UNIQUE,
    request_id               UUID,
    trace_id                 UUID,
    actor                    VARCHAR(256),
    actor_role               VARCHAR(50),
    created_at               TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_quantity          CHECK (quantity          > 0),
    CONSTRAINT chk_price_per_unit    CHECK (price_per_unit    > 0),
    CONSTRAINT chk_settlement_amount CHECK (settlement_amount > 0)
);

COMMENT ON TABLE dvp_instructions IS
  'Immutable creation record for each DVP settlement instruction. '
  'All state transitions stored in dvp_instruction_events. '
  'Query dvp_instructions_current view for current state.';

CREATE INDEX idx_dvp_isin            ON dvp_instructions (isin);
CREATE INDEX idx_dvp_seller          ON dvp_instructions (seller_entity_id);
CREATE INDEX idx_dvp_buyer           ON dvp_instructions (buyer_entity_id);
CREATE INDEX idx_dvp_settlement_date ON dvp_instructions (intended_settlement_date);
CREATE INDEX idx_dvp_trade_ref       ON dvp_instructions (trade_reference);

CREATE TRIGGER trg_deny_update_dvp_instructions
    BEFORE UPDATE ON dvp_instructions FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_dvp_instructions
    BEFORE DELETE ON dvp_instructions FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 4a. dvp_instruction_events (append-only state transitions)
--     Each row records a state transition or field update.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE dvp_instruction_events (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id        UUID            NOT NULL REFERENCES dvp_instructions(id),
    status                VARCHAR(30),
    swap_tx_hash          VARCHAR(256),
    failure_reason        TEXT,
    reconciliation_status VARCHAR(20),
    request_id            UUID,
    trace_id              UUID,
    actor                 VARCHAR(256),
    actor_role            VARCHAR(50),
    created_at            TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_event_status CHECK (
        status IS NULL OR status IN (
            'PENDING', 'COMPLIANCE_CHECK', 'LEGS_LOCKED', 'ESCROW_FUNDED',
            'MULTISIG_PENDING', 'APPROVED', 'SIGNED',
            'BROADCASTED', 'CONFIRMED', 'FAILED', 'REVERSED'
        )
    ),
    CONSTRAINT chk_event_recon CHECK (
        reconciliation_status IS NULL OR reconciliation_status IN ('MATCHED', 'SUSPENDED')
    ),
    CONSTRAINT chk_event_has_content CHECK (
        status IS NOT NULL OR swap_tx_hash IS NOT NULL OR
        failure_reason IS NOT NULL OR reconciliation_status IS NOT NULL
    )
);

COMMENT ON TABLE dvp_instruction_events IS
  'Append-only event log for DVP instruction state transitions. '
  'Each row is an immutable record of a status change or field update. '
  'Current state derived via dvp_instructions_current view.';

CREATE INDEX idx_dvp_events_instruction ON dvp_instruction_events (instruction_id, created_at);
CREATE INDEX idx_dvp_events_status      ON dvp_instruction_events (status) WHERE status IS NOT NULL;

CREATE TRIGGER trg_deny_update_dvp_instruction_events
    BEFORE UPDATE ON dvp_instruction_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_dvp_instruction_events
    BEFORE DELETE ON dvp_instruction_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 4b. dvp_instructions_current (derived view)
--     Presents the same shape as the original mutable dvp_instructions table.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE VIEW dvp_instructions_current AS
SELECT
    d.id, d.trade_reference, d.isin, d.security_type,
    d.quantity, d.price_per_unit, d.settlement_amount, d.currency,
    d.seller_entity_id, d.buyer_entity_id,
    d.seller_wallet, d.buyer_wallet,
    d.seller_custodian, d.buyer_custodian,
    d.settlement_rail, d.intended_settlement_date,
    d.idempotency_key, d.created_at,
    agg.status,
    agg.updated_at,
    agg.swap_tx_hash,
    agg.settled_at,
    agg.failure_reason,
    agg.reconciliation_status
FROM dvp_instructions d
LEFT JOIN LATERAL (
    SELECT
        (array_agg(e.status ORDER BY e.created_at DESC)
            FILTER (WHERE e.status IS NOT NULL))[1]              AS status,
        MAX(e.created_at)                                        AS updated_at,
        (array_agg(e.swap_tx_hash ORDER BY e.created_at DESC)
            FILTER (WHERE e.swap_tx_hash IS NOT NULL))[1]        AS swap_tx_hash,
        MIN(e.created_at) FILTER (WHERE e.status = 'CONFIRMED')  AS settled_at,
        (array_agg(e.failure_reason ORDER BY e.created_at DESC)
            FILTER (WHERE e.failure_reason IS NOT NULL))[1]      AS failure_reason,
        (array_agg(e.reconciliation_status ORDER BY e.created_at DESC)
            FILTER (WHERE e.reconciliation_status IS NOT NULL))[1] AS reconciliation_status
    FROM dvp_instruction_events e
    WHERE e.instruction_id = d.id
) agg ON TRUE;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. compliance_screenings (already append-only)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE compliance_screenings (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id       UUID            NOT NULL REFERENCES dvp_instructions(id),
    seller_entity_id     VARCHAR(100)    NOT NULL,
    buyer_entity_id      VARCHAR(100)    NOT NULL,
    is_cleared           BOOLEAN         NOT NULL,
    reason               TEXT            NOT NULL,
    screening_reference  VARCHAR(256)    NOT NULL,
    request_id           UUID,
    trace_id             UUID,
    actor                VARCHAR(256),
    actor_role           VARCHAR(50),
    screened_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_screening_instruction ON compliance_screenings (instruction_id);
CREATE INDEX idx_screening_cleared     ON compliance_screenings (is_cleared);

CREATE TRIGGER trg_deny_update_compliance_screenings
    BEFORE UPDATE ON compliance_screenings FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_compliance_screenings
    BEFORE DELETE ON compliance_screenings FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. settlement_legs
--    Immutable creation record for each settlement leg.
--    Status transitions stored in settlement_leg_events.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE settlement_legs (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id          UUID            NOT NULL REFERENCES dvp_instructions(id),
    leg_type                VARCHAR(20)     NOT NULL,
    originator_entity_id    VARCHAR(100)    NOT NULL,
    beneficiary_entity_id   VARCHAR(100)    NOT NULL,
    amount                  DECIMAL(38,10)  NOT NULL,
    currency                VARCHAR(20)     NOT NULL,
    request_id              UUID,
    trace_id                UUID,
    actor                   VARCHAR(256),
    actor_role              VARCHAR(50),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_leg_type CHECK (leg_type IN ('SECURITY', 'CASH'))
);

COMMENT ON TABLE settlement_legs IS
  'Immutable creation record for settlement legs. '
  'Status transitions stored in settlement_leg_events. '
  'Query settlement_legs_current view for current state.';

CREATE INDEX idx_legs_instruction ON settlement_legs (instruction_id);

CREATE TRIGGER trg_deny_update_settlement_legs
    BEFORE UPDATE ON settlement_legs FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_settlement_legs
    BEFORE DELETE ON settlement_legs FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 6a. settlement_leg_events (append-only state transitions)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE settlement_leg_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    leg_id          UUID            NOT NULL REFERENCES settlement_legs(id),
    status          VARCHAR(20)     NOT NULL,
    failure_reason  TEXT,
    request_id      UUID,
    trace_id        UUID,
    actor           VARCHAR(256),
    actor_role      VARCHAR(50),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_leg_event_status CHECK (
        status IN ('PENDING','LOCKED','IN_ESCROW','DELIVERED','RELEASED','FAILED')
    )
);

CREATE INDEX idx_leg_events_leg ON settlement_leg_events (leg_id, created_at);

CREATE TRIGGER trg_deny_update_settlement_leg_events
    BEFORE UPDATE ON settlement_leg_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_settlement_leg_events
    BEFORE DELETE ON settlement_leg_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 6b. settlement_legs_current (derived view)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE VIEW settlement_legs_current AS
SELECT
    sl.id, sl.instruction_id, sl.leg_type,
    sl.originator_entity_id, sl.beneficiary_entity_id,
    sl.amount, sl.currency, sl.created_at,
    COALESCE(agg.status, 'PENDING')  AS status,
    agg.updated_at,
    agg.locked_at,
    agg.delivered_at,
    agg.failure_reason
FROM settlement_legs sl
LEFT JOIN LATERAL (
    SELECT
        (array_agg(e.status ORDER BY e.created_at DESC))[1]        AS status,
        MAX(e.created_at)                                          AS updated_at,
        MIN(e.created_at) FILTER (WHERE e.status = 'LOCKED')      AS locked_at,
        MIN(e.created_at) FILTER (WHERE e.status = 'DELIVERED')   AS delivered_at,
        (array_agg(e.failure_reason ORDER BY e.created_at DESC)
            FILTER (WHERE e.failure_reason IS NOT NULL))[1]        AS failure_reason
    FROM settlement_leg_events e
    WHERE e.leg_id = sl.id
) agg ON TRUE;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. escrow_accounts
--    Immutable creation record for dual escrow accounts.
--    Status transitions stored in escrow_account_events.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE escrow_accounts (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id      UUID            NOT NULL REFERENCES dvp_instructions(id),
    leg_type            VARCHAR(20)     NOT NULL,
    holder_entity_id    VARCHAR(100)    NOT NULL,
    amount              DECIMAL(38,10)  NOT NULL,
    currency            VARCHAR(20)     NOT NULL,
    escrow_address      VARCHAR(256)    NOT NULL,
    on_chain_tx_hash    VARCHAR(256),
    request_id          UUID,
    trace_id            UUID,
    actor               VARCHAR(256),
    actor_role          VARCHAR(50),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_escrow_leg_type CHECK (leg_type IN ('SECURITY', 'CASH'))
);

COMMENT ON TABLE escrow_accounts IS
  'Immutable creation record for escrow accounts. '
  'Status transitions stored in escrow_account_events. '
  'Query escrow_accounts_current view for current state.';

CREATE INDEX idx_escrow_instruction ON escrow_accounts (instruction_id);

CREATE TRIGGER trg_deny_update_escrow_accounts
    BEFORE UPDATE ON escrow_accounts FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_escrow_accounts
    BEFORE DELETE ON escrow_accounts FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 7a. escrow_account_events (append-only state transitions)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE escrow_account_events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    escrow_id   UUID            NOT NULL REFERENCES escrow_accounts(id),
    status      VARCHAR(20)     NOT NULL,
    request_id  UUID,
    trace_id    UUID,
    actor       VARCHAR(256),
    actor_role  VARCHAR(50),
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_escrow_event_status CHECK (
        status IN ('PENDING','LOCKED','IN_ESCROW','DELIVERED','RELEASED','FAILED')
    )
);

CREATE INDEX idx_escrow_events_escrow ON escrow_account_events (escrow_id, created_at);

CREATE TRIGGER trg_deny_update_escrow_account_events
    BEFORE UPDATE ON escrow_account_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_escrow_account_events
    BEFORE DELETE ON escrow_account_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 7b. escrow_accounts_current (derived view)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE VIEW escrow_accounts_current AS
SELECT
    ea.id, ea.instruction_id, ea.leg_type,
    ea.holder_entity_id, ea.amount, ea.currency,
    ea.escrow_address, ea.on_chain_tx_hash, ea.created_at,
    COALESCE(agg.status, 'PENDING')  AS status,
    agg.funded_at,
    agg.released_at
FROM escrow_accounts ea
LEFT JOIN LATERAL (
    SELECT
        (array_agg(e.status ORDER BY e.created_at DESC))[1]              AS status,
        MIN(e.created_at) FILTER (WHERE e.status = 'IN_ESCROW')         AS funded_at,
        MIN(e.created_at) FILTER (WHERE e.status IN ('DELIVERED','RELEASED')) AS released_at
    FROM escrow_account_events e
    WHERE e.escrow_id = ea.id
) agg ON TRUE;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. multisig_approvals (already append-only)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE multisig_approvals (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id  UUID            NOT NULL REFERENCES dvp_instructions(id),
    custodian_id    VARCHAR(100)    NOT NULL,
    signer_id       VARCHAR(256)    NOT NULL,
    vote            VARCHAR(10)     NOT NULL,
    signature       VARCHAR(256)    NOT NULL,
    voted_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    justification   TEXT,
    request_id      UUID,
    trace_id        UUID,
    actor           VARCHAR(256),
    actor_role      VARCHAR(50),

    UNIQUE (instruction_id, custodian_id),

    CONSTRAINT chk_vote CHECK (vote IN ('APPROVE', 'REJECT', 'ABSTAIN'))
);

CREATE INDEX idx_multisig_instruction ON multisig_approvals (instruction_id);
CREATE INDEX idx_multisig_vote        ON multisig_approvals (vote);

CREATE TRIGGER trg_deny_update_multisig_approvals
    BEFORE UPDATE ON multisig_approvals FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_multisig_approvals
    BEFORE DELETE ON multisig_approvals FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. hybrid_rail_messages
--    Immutable creation record for off-chain payment messages.
--    Status transitions stored in hybrid_rail_message_events.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE hybrid_rail_messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id  UUID            NOT NULL REFERENCES dvp_instructions(id),
    rail            VARCHAR(20)     NOT NULL,
    message_type    VARCHAR(30)     NOT NULL,
    payload         JSONB           NOT NULL,
    rail_reference  VARCHAR(256),
    request_id      UUID,
    trace_id        UUID,
    actor           VARCHAR(256),
    actor_role      VARCHAR(50),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_rail CHECK (rail IN ('SWIFT','FEDWIRE','CLS','ONCHAIN','INTERNAL'))
);

COMMENT ON TABLE hybrid_rail_messages IS
  'Immutable creation record for off-chain payment messages. '
  'Status transitions stored in hybrid_rail_message_events. '
  'Query hybrid_rail_messages_current view for current state.';

CREATE INDEX idx_rail_instruction  ON hybrid_rail_messages (instruction_id);
CREATE INDEX idx_rail_reference    ON hybrid_rail_messages (rail_reference);

CREATE TRIGGER trg_deny_update_hybrid_rail_messages
    BEFORE UPDATE ON hybrid_rail_messages FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_hybrid_rail_messages
    BEFORE DELETE ON hybrid_rail_messages FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 9a. hybrid_rail_message_events (append-only state transitions)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE hybrid_rail_message_events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id  UUID            NOT NULL REFERENCES hybrid_rail_messages(id),
    status      VARCHAR(20)     NOT NULL,
    request_id  UUID,
    trace_id    UUID,
    actor       VARCHAR(256),
    actor_role  VARCHAR(50),
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_rail_event_status CHECK (
        status IN ('PENDING','SUBMITTED','CONFIRMED','REJECTED','TIMED_OUT')
    )
);

CREATE INDEX idx_rail_events_message ON hybrid_rail_message_events (message_id, created_at);

CREATE TRIGGER trg_deny_update_hybrid_rail_message_events
    BEFORE UPDATE ON hybrid_rail_message_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_hybrid_rail_message_events
    BEFORE DELETE ON hybrid_rail_message_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 9b. hybrid_rail_messages_current (derived view)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE VIEW hybrid_rail_messages_current AS
SELECT
    m.id, m.instruction_id, m.rail, m.message_type,
    m.payload, m.rail_reference, m.created_at,
    COALESCE(agg.status, 'PENDING')  AS status,
    agg.submitted_at,
    agg.confirmed_at
FROM hybrid_rail_messages m
LEFT JOIN LATERAL (
    SELECT
        (array_agg(e.status ORDER BY e.created_at DESC))[1]               AS status,
        MIN(e.created_at) FILTER (WHERE e.status = 'SUBMITTED')           AS submitted_at,
        MIN(e.created_at) FILTER (WHERE e.status = 'CONFIRMED')           AS confirmed_at
    FROM hybrid_rail_message_events e
    WHERE e.message_id = m.id
) agg ON TRUE;


-- ─────────────────────────────────────────────────────────────────────────────
-- 10. outbox_events (immutable)
--     Reliable Kafka delivery buffer — transactional outbox pattern.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE outbox_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_id    VARCHAR(256)    NOT NULL,
    event_type      VARCHAR(100)    NOT NULL,
    payload         JSONB           NOT NULL,
    request_id      UUID,
    trace_id        UUID,
    actor           VARCHAR(256),
    actor_role      VARCHAR(50),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE outbox_events IS
  'Immutable transactional outbox buffer for Kafka. '
  'Delivery status tracked in outbox_delivery_log (append-only). '
  'Query outbox_events_current view for delivery status.';

CREATE INDEX idx_outbox_aggregate ON outbox_events (aggregate_id);
CREATE INDEX idx_outbox_created   ON outbox_events (created_at);

CREATE TRIGGER trg_deny_update_outbox_events
    BEFORE UPDATE ON outbox_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_outbox_events
    BEFORE DELETE ON outbox_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 10a. outbox_delivery_log (append-only delivery tracking)
--      Tracks Kafka delivery attempts, retries, and DLQ.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE outbox_delivery_log (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id    UUID            NOT NULL REFERENCES outbox_events(id),
    status      VARCHAR(20)     NOT NULL,
    error       TEXT,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_delivery_status CHECK (
        status IN ('PUBLISHED', 'RETRY', 'DLQ')
    )
);

COMMENT ON TABLE outbox_delivery_log IS
  'Append-only delivery tracking for outbox events. '
  'Each row is an immutable record of a delivery attempt or result. '
  'PUBLISHED: successfully delivered to Kafka. '
  'RETRY: failed attempt with error. DLQ: dead-lettered after max retries.';

CREATE UNIQUE INDEX idx_delivery_published ON outbox_delivery_log (event_id) WHERE status = 'PUBLISHED';
CREATE UNIQUE INDEX idx_delivery_dlq       ON outbox_delivery_log (event_id) WHERE status = 'DLQ';
CREATE INDEX idx_delivery_event            ON outbox_delivery_log (event_id, created_at);

CREATE TRIGGER trg_deny_update_outbox_delivery_log
    BEFORE UPDATE ON outbox_delivery_log FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_outbox_delivery_log
    BEFORE DELETE ON outbox_delivery_log FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 10c. consumed_events (consumer-side idempotency)
--      Tracks which events each consumer group has already processed.
--      Enables exactly-once semantics on top of at-least-once delivery.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE consumed_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id        UUID            NOT NULL,
    consumer_group  VARCHAR(100)    NOT NULL,
    processed_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    UNIQUE (event_id, consumer_group)
);

CREATE INDEX idx_consumed_event_id ON consumed_events (event_id);
CREATE INDEX idx_consumed_consumer ON consumed_events (consumer_group);

CREATE TRIGGER trg_deny_update_consumed_events
    BEFORE UPDATE ON consumed_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_consumed_events
    BEFORE DELETE ON consumed_events FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 10d. outbox_events_current (derived view)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE VIEW outbox_events_current AS
SELECT
    oe.id, oe.aggregate_id, oe.event_type, oe.payload, oe.created_at,
    COALESCE(agg.delivery_status, 'PENDING') AS delivery_status,
    agg.published_at,
    agg.dlq_at,
    COALESCE(agg.retry_count, 0)             AS retry_count,
    agg.last_error
FROM outbox_events oe
LEFT JOIN LATERAL (
    SELECT
        (array_agg(dl.status ORDER BY dl.created_at DESC))[1]             AS delivery_status,
        MIN(dl.created_at) FILTER (WHERE dl.status = 'PUBLISHED')         AS published_at,
        MIN(dl.created_at) FILTER (WHERE dl.status = 'DLQ')              AS dlq_at,
        COUNT(*) FILTER (WHERE dl.status = 'RETRY')                       AS retry_count,
        (array_agg(dl.error ORDER BY dl.created_at DESC)
            FILTER (WHERE dl.error IS NOT NULL))[1]                       AS last_error
    FROM outbox_delivery_log dl
    WHERE dl.event_id = oe.id
) agg ON TRUE;


-- ─────────────────────────────────────────────────────────────────────────────
-- 11. reconciliation_reports (already append-only)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE reconciliation_reports (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instruction_id              UUID            NOT NULL REFERENCES dvp_instructions(id),
    result                      VARCHAR(20)     NOT NULL,
    security_leg_verified       BOOLEAN         NOT NULL,
    cash_leg_verified           BOOLEAN         NOT NULL,
    onchain_supply_matched      BOOLEAN         NOT NULL,
    rail_confirmation_matched   BOOLEAN         NOT NULL,
    mismatches                  JSONB           NOT NULL DEFAULT '[]',
    request_id                  UUID,
    trace_id                    UUID,
    actor                       VARCHAR(256),
    actor_role                  VARCHAR(50),
    reconciled_at               TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_recon_result CHECK (result IN ('MATCHED','MISMATCH','SUSPENDED'))
);

CREATE INDEX idx_recon_instruction ON reconciliation_reports (instruction_id);
CREATE INDEX idx_recon_result      ON reconciliation_reports (result);

CREATE TRIGGER trg_deny_update_reconciliation_reports
    BEFORE UPDATE ON reconciliation_reports FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_reconciliation_reports
    BEFORE DELETE ON reconciliation_reports FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 12. audit_log — Append-only audit trail for all operations
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE audit_log (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id  UUID            NOT NULL,
    trace_id    UUID            NOT NULL,
    actor       VARCHAR(256)    NOT NULL,
    actor_role  VARCHAR(50)     NOT NULL,
    operation   VARCHAR(100)    NOT NULL,
    resource    VARCHAR(256)    NOT NULL,
    detail      JSONB,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_log_request ON audit_log (request_id);
CREATE INDEX idx_audit_log_trace ON audit_log (trace_id);
CREATE INDEX idx_audit_log_actor ON audit_log (actor);

CREATE TRIGGER trg_deny_update_audit_log
    BEFORE UPDATE ON audit_log FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_audit_log
    BEFORE DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 13. RBAC Tables — Role-Based Access Control
-- ─────────────────────────────────────────────────────────────────────────────

-- 13a. rbac_roles
CREATE TABLE rbac_roles (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_name   VARCHAR(50)     NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_deny_update_rbac_roles
    BEFORE UPDATE ON rbac_roles FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_rbac_roles
    BEFORE DELETE ON rbac_roles FOR EACH ROW EXECUTE FUNCTION deny_mutation();

-- 13b. rbac_role_permissions
CREATE TABLE rbac_role_permissions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_id     UUID            NOT NULL REFERENCES rbac_roles(id),
    permission  VARCHAR(100)    NOT NULL,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    UNIQUE (role_id, permission)
);

CREATE INDEX idx_rbac_perms_role ON rbac_role_permissions (role_id);

CREATE TRIGGER trg_deny_update_rbac_role_permissions
    BEFORE UPDATE ON rbac_role_permissions FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_rbac_role_permissions
    BEFORE DELETE ON rbac_role_permissions FOR EACH ROW EXECUTE FUNCTION deny_mutation();

-- 13c. rbac_actor_roles
CREATE TABLE rbac_actor_roles (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor       VARCHAR(256)    NOT NULL,
    role_id     UUID            NOT NULL REFERENCES rbac_roles(id),
    granted_by  VARCHAR(256),
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    UNIQUE (actor, role_id)
);

CREATE INDEX idx_rbac_actor_roles_actor ON rbac_actor_roles (actor);

CREATE TRIGGER trg_deny_update_rbac_actor_roles
    BEFORE UPDATE ON rbac_actor_roles FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_rbac_actor_roles
    BEFORE DELETE ON rbac_actor_roles FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- ─────────────────────────────────────────────────────────────────────────────
-- 14. RBAC Seed Data
-- ─────────────────────────────────────────────────────────────────────────────

-- Roles
INSERT INTO rbac_roles (id, role_name, description) VALUES
    ('00000000-0000-0000-0000-000000000001', 'ADMIN',
     'Full system access — all permissions'),
    ('00000000-0000-0000-0000-000000000002', 'ORIGINATOR',
     'Can initiate settlement instructions'),
    ('00000000-0000-0000-0000-000000000003', 'CUSTODIAN',
     'Can vote on multi-sig, fund/release escrow'),
    ('00000000-0000-0000-0000-000000000004', 'COMPLIANCE_OFFICER',
     'Can run compliance screenings'),
    ('00000000-0000-0000-0000-000000000005', 'SYSTEM',
     'Internal system operations — seeding, orchestration'),
    ('00000000-0000-0000-0000-000000000006', 'SIGNER',
     'Can cast multi-sig votes');

-- Permissions per role
-- ADMIN: wildcard
INSERT INTO rbac_role_permissions (role_id, permission) VALUES
    ('00000000-0000-0000-0000-000000000001', '*');

-- ORIGINATOR
INSERT INTO rbac_role_permissions (role_id, permission) VALUES
    ('00000000-0000-0000-0000-000000000002', 'settlement.initiate');

-- CUSTODIAN
INSERT INTO rbac_role_permissions (role_id, permission) VALUES
    ('00000000-0000-0000-0000-000000000003', 'multisig.vote'),
    ('00000000-0000-0000-0000-000000000003', 'escrow.fund'),
    ('00000000-0000-0000-0000-000000000003', 'escrow.release');

-- COMPLIANCE_OFFICER
INSERT INTO rbac_role_permissions (role_id, permission) VALUES
    ('00000000-0000-0000-0000-000000000004', 'compliance.screen');

-- SYSTEM
INSERT INTO rbac_role_permissions (role_id, permission) VALUES
    ('00000000-0000-0000-0000-000000000005', 'settlement.initiate'),
    ('00000000-0000-0000-0000-000000000005', 'settlement.finalize'),
    ('00000000-0000-0000-0000-000000000005', 'compliance.screen'),
    ('00000000-0000-0000-0000-000000000005', 'escrow.fund'),
    ('00000000-0000-0000-0000-000000000005', 'escrow.release'),
    ('00000000-0000-0000-0000-000000000005', 'multisig.vote'),
    ('00000000-0000-0000-0000-000000000005', 'swap.execute'),
    ('00000000-0000-0000-0000-000000000005', 'rail.submit'),
    ('00000000-0000-0000-0000-000000000005', 'reconciliation.run');

-- SIGNER
INSERT INTO rbac_role_permissions (role_id, permission) VALUES
    ('00000000-0000-0000-0000-000000000006', 'multisig.vote');

-- Actor-role assignments for sandbox entities
INSERT INTO rbac_actor_roles (actor, role_id, granted_by) VALUES
    ('SYSTEM/seed', '00000000-0000-0000-0000-000000000005', 'BOOTSTRAP'),
    ('SYSTEM/sandbox', '00000000-0000-0000-0000-000000000005', 'BOOTSTRAP'),
    ('SYSTEM/orchestrator', '00000000-0000-0000-0000-000000000005', 'BOOTSTRAP'),
    ('549300BNMGNFKN6LAD61', '00000000-0000-0000-0000-000000000002', 'BOOTSTRAP'),
    ('571474TGEMMWANRLN572', '00000000-0000-0000-0000-000000000002', 'BOOTSTRAP'),
    ('IRVTUS3N', '00000000-0000-0000-0000-000000000003', 'BOOTSTRAP'),
    ('SBOSUS33', '00000000-0000-0000-0000-000000000003', 'BOOTSTRAP'),
    ('DTCCUS3N', '00000000-0000-0000-0000-000000000003', 'BOOTSTRAP'),
    ('IRVTUS3N', '00000000-0000-0000-0000-000000000006', 'BOOTSTRAP'),
    ('SBOSUS33', '00000000-0000-0000-0000-000000000006', 'BOOTSTRAP'),
    ('DTCCUS3N', '00000000-0000-0000-0000-000000000006', 'BOOTSTRAP'),
    ('COMPLIANCE/sandbox', '00000000-0000-0000-0000-000000000004', 'BOOTSTRAP');


-- ═══════════════════════════════════════════════════════════════════════════
-- END-TO-END SANDBOX DEMO
-- Scenario: BlackRock (seller) → State Street (buyer)
--           500,000 AAPL shares at $195.00 = $97,500,000 USD
--           Settlement rail: SWIFT (MT543 + MT103) + on-chain atomic swap
--
-- EVERY operation is an INSERT. No UPDATEs. No DELETEs.
-- ═══════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- A. Register Institutional Participants
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO registered_entities
    (id, entity_name, lei, entity_type, jurisdiction, regulator, bic)
VALUES
    (gen_random_uuid(), 'BlackRock, Inc.',
     '549300BNMGNFKN6LAD61', 'ASSET_MANAGER', 'United States', 'SEC', 'BLRKUS33'),
    (gen_random_uuid(), 'State Street Bank and Trust Company',
     '571474TGEMMWANRLN572', 'CUSTODIAN', 'United States', 'OCC / FRB', 'SBOSUS33'),
    (gen_random_uuid(), 'The Bank of New York Mellon',
     'WFLLPEPC7FZXENRZV498', 'CUSTODIAN', 'United States', 'FRB / OCC', 'IRVTUS3N'),
    (gen_random_uuid(), 'Depository Trust & Clearing Corporation',
     '213800ZBKL9BHSL2K459', 'CCP', 'United States', 'SEC / CFTC', 'DTCCUS3N');


-- ─────────────────────────────────────────────────────────────────────────────
-- B. Initialize Custody Positions (metadata only)
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO custody_positions
    (id, entity_id, isin, cusip, security_description,
     token_address, wallet_address, custodian)
VALUES
    (gen_random_uuid(), '549300BNMGNFKN6LAD61', 'US0378331005', '037833100',
     'Apple Inc. Common Stock', '0xAAPL_TOKEN_CONTRACT_ADDRESS',
     '0xBLACKROCK_WALLET_ADDRESS', 'DTC'),
    (gen_random_uuid(), '571474TGEMMWANRLN572', 'US0378331005', '037833100',
     'Apple Inc. Common Stock', '0xAAPL_TOKEN_CONTRACT_ADDRESS',
     '0xSTATESTREET_WALLET_ADDRESS', 'DTC');

-- Initial security balance via ledger entry
INSERT INTO security_ledger
    (entity_id, isin, pool, amount, reason,
     request_id, trace_id, actor, actor_role)
VALUES
    ('549300BNMGNFKN6LAD61', 'US0378331005', 'AVAILABLE', 2000000.0000000000, 'INITIAL_BALANCE',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');


-- ─────────────────────────────────────────────────────────────────────────────
-- C. Initialize Cash Accounts (metadata only)
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO cash_accounts
    (id, entity_id, currency, account_type, bank_aba, swift_bic)
VALUES
    (gen_random_uuid(), '571474TGEMMWANRLN572', 'USD', 'TOKENIZED_CASH', '011000028', 'SBOSUS33'),
    (gen_random_uuid(), '549300BNMGNFKN6LAD61', 'USD', 'TOKENIZED_CASH', '021000018', 'BLRKUS33');

-- Initial cash balances via ledger entries
INSERT INTO cash_ledger
    (entity_id, currency, pool, amount, reason,
     request_id, trace_id, actor, actor_role)
VALUES
    ('571474TGEMMWANRLN572', 'USD', 'AVAILABLE', 500000000.00, 'INITIAL_BALANCE',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'),
    ('549300BNMGNFKN6LAD61', 'USD', 'AVAILABLE', 10000000.00, 'INITIAL_BALANCE',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');


-- ─────────────────────────────────────────────────────────────────────────────
-- D. Create DVP Instruction + PENDING event
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO dvp_instructions (
    id, trade_reference, isin, security_type,
    quantity, price_per_unit, settlement_amount, currency,
    seller_entity_id, buyer_entity_id,
    seller_wallet, buyer_wallet,
    seller_custodian, buyer_custodian,
    settlement_rail, intended_settlement_date,
    idempotency_key,
    request_id, trace_id, actor, actor_role,
    created_at
)
VALUES (
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'BLK-SST-AAPL-20260320-001',
    'US0378331005', 'EQUITY',
    500000.0000000000, 195.00, 97500000.00, 'USD',
    '549300BNMGNFKN6LAD61', '571474TGEMMWANRLN572',
    '0xBLACKROCK_WALLET_ADDRESS', '0xSTATESTREET_WALLET_ADDRESS',
    'IRVTUS3N', 'SBOSUS33',
    'SWIFT', '2026-03-20',
    'DVP-BLK-SST-AAPL-20260320-001',
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM',
    NOW()
);

-- PENDING event
INSERT INTO dvp_instruction_events
    (instruction_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('f47ac10b-58cc-4372-a567-0e02b2c3d479', 'PENDING',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');


-- ─────────────────────────────────────────────────────────────────────────────
-- E. Compliance Screening — Both Counterparties Cleared
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO compliance_screenings
    (id, instruction_id, seller_entity_id, buyer_entity_id,
     is_cleared, reason, screening_reference,
     request_id, trace_id, actor, actor_role,
     screened_at)
VALUES (
    gen_random_uuid(),
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    '549300BNMGNFKN6LAD61', '571474TGEMMWANRLN572',
    TRUE,
    'Both counterparties cleared OFAC SDN, EU/UN consolidated, and PEP lists. '
    'No adverse media. LEI verified with GLEIF.',
    'COMPLY-ADV-20260320-BLK-SST-A1B2C3D4|COMPLY-ADV-20260320-SST-BLK-E5F6G7H8',
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM',
    NOW()
);

-- Advance status: COMPLIANCE_CHECK
INSERT INTO dvp_instruction_events
    (instruction_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('f47ac10b-58cc-4372-a567-0e02b2c3d479', 'COMPLIANCE_CHECK',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');


-- ─────────────────────────────────────────────────────────────────────────────
-- F. Lock Settlement Legs
--    Atomically reserve securities (BlackRock) + cash (State Street)
--    via append-only ledger entries
-- ─────────────────────────────────────────────────────────────────────────────

-- Lock security leg: move 500,000 from AVAILABLE to LOCKED for BlackRock
INSERT INTO security_ledger
    (entity_id, isin, pool, amount, instruction_id, reason,
     request_id, trace_id, actor, actor_role)
VALUES
    ('549300BNMGNFKN6LAD61', 'US0378331005', 'AVAILABLE', -500000.0000000000,
     'f47ac10b-58cc-4372-a567-0e02b2c3d479', 'LOCK',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'),
    ('549300BNMGNFKN6LAD61', 'US0378331005', 'LOCKED', 500000.0000000000,
     'f47ac10b-58cc-4372-a567-0e02b2c3d479', 'LOCK',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Lock cash leg: move $97,500,000 from AVAILABLE to LOCKED for State Street
INSERT INTO cash_ledger
    (entity_id, currency, pool, amount, instruction_id, reason,
     request_id, trace_id, actor, actor_role)
VALUES
    ('571474TGEMMWANRLN572', 'USD', 'AVAILABLE', -97500000.00,
     'f47ac10b-58cc-4372-a567-0e02b2c3d479', 'LOCK',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'),
    ('571474TGEMMWANRLN572', 'USD', 'LOCKED', 97500000.00,
     'f47ac10b-58cc-4372-a567-0e02b2c3d479', 'LOCK',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Create security leg (immutable record)
INSERT INTO settlement_legs
    (id, instruction_id, leg_type, originator_entity_id, beneficiary_entity_id,
     amount, currency,
     request_id, trace_id, actor, actor_role)
VALUES (
    'aaaa0001-0000-0000-0000-000000000001',
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'SECURITY', '549300BNMGNFKN6LAD61', '571474TGEMMWANRLN572',
    500000.0000000000, 'US0378331005',
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'
);

-- Security leg status: LOCKED
INSERT INTO settlement_leg_events
    (leg_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('aaaa0001-0000-0000-0000-000000000001', 'LOCKED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Create cash leg (immutable record)
INSERT INTO settlement_legs
    (id, instruction_id, leg_type, originator_entity_id, beneficiary_entity_id,
     amount, currency,
     request_id, trace_id, actor, actor_role)
VALUES (
    'bbbb0002-0000-0000-0000-000000000002',
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'CASH', '571474TGEMMWANRLN572', '549300BNMGNFKN6LAD61',
    97500000.00, 'USD',
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'
);

-- Cash leg status: LOCKED
INSERT INTO settlement_leg_events
    (leg_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('bbbb0002-0000-0000-0000-000000000002', 'LOCKED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Advance instruction status: LEGS_LOCKED
INSERT INTO dvp_instruction_events
    (instruction_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('f47ac10b-58cc-4372-a567-0e02b2c3d479', 'LEGS_LOCKED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Outbox event: legs_locked
INSERT INTO outbox_events
    (id, aggregate_id, event_type, payload,
     request_id, trace_id, actor, actor_role,
     created_at)
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
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM',
    NOW()
);


-- ─────────────────────────────────────────────────────────────────────────────
-- G. Fund Escrow Accounts
-- ─────────────────────────────────────────────────────────────────────────────

-- Create security escrow (immutable record)
INSERT INTO escrow_accounts
    (id, instruction_id, leg_type, holder_entity_id, amount, currency,
     escrow_address, on_chain_tx_hash,
     request_id, trace_id, actor, actor_role)
VALUES (
    'cccc0003-0000-0000-0000-000000000003',
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'SECURITY', '549300BNMGNFKN6LAD61', 500000.0000000000, 'US0378331005',
    '0xSECURITY_ESCROW_CONTRACT_ADDRESS',
    '0xabc123def456789012345678901234567890123456789012345678901234abcd',
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'
);

-- Security escrow status: IN_ESCROW
INSERT INTO escrow_account_events
    (escrow_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('cccc0003-0000-0000-0000-000000000003', 'IN_ESCROW',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Create cash escrow (immutable record)
INSERT INTO escrow_accounts
    (id, instruction_id, leg_type, holder_entity_id, amount, currency,
     escrow_address, on_chain_tx_hash,
     request_id, trace_id, actor, actor_role)
VALUES (
    'dddd0004-0000-0000-0000-000000000004',
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'CASH', '571474TGEMMWANRLN572', 97500000.00, 'USD',
    '0xCASH_ESCROW_CONTRACT_ADDRESS',
    '0xdef456abc123012345678901234567890123456789012345678901234567def0',
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'
);

-- Cash escrow status: IN_ESCROW
INSERT INTO escrow_account_events
    (escrow_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('dddd0004-0000-0000-0000-000000000004', 'IN_ESCROW',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Leg status: IN_ESCROW
INSERT INTO settlement_leg_events
    (leg_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('aaaa0001-0000-0000-0000-000000000001', 'IN_ESCROW',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'),
    ('bbbb0002-0000-0000-0000-000000000002', 'IN_ESCROW',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Advance instruction status: ESCROW_FUNDED
INSERT INTO dvp_instruction_events
    (instruction_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('f47ac10b-58cc-4372-a567-0e02b2c3d479', 'ESCROW_FUNDED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Outbox event: escrow_funded
INSERT INTO outbox_events
    (id, aggregate_id, event_type, payload,
     request_id, trace_id, actor, actor_role,
     created_at)
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
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM',
    NOW()
);


-- ─────────────────────────────────────────────────────────────────────────────
-- H. Submit SWIFT Messages (MT543 + MT103)
-- ─────────────────────────────────────────────────────────────────────────────

-- Create MT543 message (immutable record)
INSERT INTO hybrid_rail_messages
    (id, instruction_id, rail, message_type, payload, rail_reference,
     request_id, trace_id, actor, actor_role)
VALUES (
    'ee110001-0000-0000-0000-000000000005',
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'SWIFT', 'MT543',
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
    'a1b2c3d4-e5f6-7890-abcd-ef0123456789',
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'
);

-- MT543 status: SUBMITTED
INSERT INTO hybrid_rail_message_events
    (message_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('ee110001-0000-0000-0000-000000000005', 'SUBMITTED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Create MT103 message (immutable record)
INSERT INTO hybrid_rail_messages
    (id, instruction_id, rail, message_type, payload, rail_reference,
     request_id, trace_id, actor, actor_role)
VALUES (
    'ff220002-0000-0000-0000-000000000006',
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'SWIFT', 'MT103',
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
    'b2c3d4e5-f6a1-8901-bcde-f01234567890',
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'
);

-- MT103 status: SUBMITTED
INSERT INTO hybrid_rail_message_events
    (message_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('ff220002-0000-0000-0000-000000000006', 'SUBMITTED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Advance to MULTISIG_PENDING
INSERT INTO dvp_instruction_events
    (instruction_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('f47ac10b-58cc-4372-a567-0e02b2c3d479', 'MULTISIG_PENDING',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');


-- ─────────────────────────────────────────────────────────────────────────────
-- I. Multi-Sig Approval Votes
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO multisig_approvals
    (id, instruction_id, custodian_id, signer_id, vote, signature,
     request_id, trace_id, actor, actor_role,
     voted_at)
VALUES
    (gen_random_uuid(), 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
     'IRVTUS3N', 'HSM-BNYM-SIGNER-KEY-001', 'APPROVE',
     'sha256:bnym_simulated_ecdsa_signature_approval_f47ac10b_20260320',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM',
     NOW()),
    (gen_random_uuid(), 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
     'SBOSUS33', 'HSM-SST-SIGNER-KEY-007', 'APPROVE',
     'sha256:sst_simulated_ecdsa_signature_approval_f47ac10b_20260320',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM',
     NOW());

-- Quorum reached: APPROVED
INSERT INTO dvp_instruction_events
    (instruction_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('f47ac10b-58cc-4372-a567-0e02b2c3d479', 'APPROVED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Outbox event: multisig_approved
INSERT INTO outbox_events
    (id, aggregate_id, event_type, payload,
     request_id, trace_id, actor, actor_role,
     created_at)
VALUES (
    gen_random_uuid(),
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'dvp.multisig_approved',
    '{"instruction_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479", "quorum": 2, "required": 2}'::jsonb,
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM',
    NOW()
);


-- ─────────────────────────────────────────────────────────────────────────────
-- J. Atomic Swap — IRREVOCABLE Settlement
--    All balance changes via append-only ledger INSERTs.
--    State transitions via event INSERTs. Zero UPDATEs.
-- ─────────────────────────────────────────────────────────────────────────────

-- Mark as SIGNED (crash recovery marker)
INSERT INTO dvp_instruction_events
    (instruction_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('f47ac10b-58cc-4372-a567-0e02b2c3d479', 'SIGNED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Mark as BROADCASTED (tx broadcast to chain)
INSERT INTO dvp_instruction_events
    (instruction_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('f47ac10b-58cc-4372-a567-0e02b2c3d479', 'BROADCASTED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Finalize settlement — atomic ledger update
BEGIN;

    -- 1. Mark instruction as CONFIRMED with swap tx hash
    INSERT INTO dvp_instruction_events
        (instruction_id, status, swap_tx_hash,
         request_id, trace_id, actor, actor_role)
    VALUES
        ('f47ac10b-58cc-4372-a567-0e02b2c3d479', 'CONFIRMED',
         '0xATOMIC_SWAP_TX_HASH_f47ac10b_20260320_IRREVOCABLE',
         'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

    -- 2. Security: debit seller's LOCKED pool
    INSERT INTO security_ledger
        (entity_id, isin, pool, amount, instruction_id, reason,
         request_id, trace_id, actor, actor_role)
    VALUES
        ('549300BNMGNFKN6LAD61', 'US0378331005', 'LOCKED', -500000.0000000000,
         'f47ac10b-58cc-4372-a567-0e02b2c3d479', 'DELIVERY_DEBIT',
         'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

    -- 3. Cash: debit buyer's LOCKED pool
    INSERT INTO cash_ledger
        (entity_id, currency, pool, amount, instruction_id, reason,
         request_id, trace_id, actor, actor_role)
    VALUES
        ('571474TGEMMWANRLN572', 'USD', 'LOCKED', -97500000.00,
         'f47ac10b-58cc-4372-a567-0e02b2c3d479', 'DELIVERY_DEBIT',
         'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

    -- 4. Security: credit buyer's AVAILABLE pool
    INSERT INTO security_ledger
        (entity_id, isin, pool, amount, instruction_id, reason,
         request_id, trace_id, actor, actor_role)
    VALUES
        ('571474TGEMMWANRLN572', 'US0378331005', 'AVAILABLE', 500000.0000000000,
         'f47ac10b-58cc-4372-a567-0e02b2c3d479', 'DELIVERY_CREDIT',
         'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

    -- 5. Cash: credit seller's AVAILABLE pool
    INSERT INTO cash_ledger
        (entity_id, currency, pool, amount, instruction_id, reason,
         request_id, trace_id, actor, actor_role)
    VALUES
        ('549300BNMGNFKN6LAD61', 'USD', 'AVAILABLE', 97500000.00,
         'f47ac10b-58cc-4372-a567-0e02b2c3d479', 'DELIVERY_CREDIT',
         'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

    -- 6. Escrow accounts: DELIVERED
    INSERT INTO escrow_account_events
        (escrow_id, status,
         request_id, trace_id, actor, actor_role)
    VALUES
        ('cccc0003-0000-0000-0000-000000000003', 'DELIVERED',
         'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'),
        ('dddd0004-0000-0000-0000-000000000004', 'DELIVERED',
         'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

    -- 7. Settlement legs: DELIVERED
    INSERT INTO settlement_leg_events
        (leg_id, status,
         request_id, trace_id, actor, actor_role)
    VALUES
        ('aaaa0001-0000-0000-0000-000000000001', 'DELIVERED',
         'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'),
        ('bbbb0002-0000-0000-0000-000000000002', 'DELIVERED',
         'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

    -- 8. Outbox event: settled
    INSERT INTO outbox_events
        (id, aggregate_id, event_type, payload,
         request_id, trace_id, actor, actor_role,
         created_at)
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
        'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM',
        NOW()
    );

COMMIT;


-- ─────────────────────────────────────────────────────────────────────────────
-- K. Confirm SWIFT Messages
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO hybrid_rail_message_events
    (message_id, status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('ee110001-0000-0000-0000-000000000005', 'CONFIRMED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM'),
    ('ff220002-0000-0000-0000-000000000006', 'CONFIRMED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');


-- ─────────────────────────────────────────────────────────────────────────────
-- L. Post-Settlement Reconciliation
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO reconciliation_reports
    (id, instruction_id, result,
     security_leg_verified, cash_leg_verified,
     onchain_supply_matched, rail_confirmation_matched,
     mismatches,
     request_id, trace_id, actor, actor_role,
     reconciled_at)
VALUES (
    gen_random_uuid(),
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'MATCHED', TRUE, TRUE, TRUE, TRUE,
    '[]'::jsonb,
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM',
    NOW()
);

-- Reconciliation status event
INSERT INTO dvp_instruction_events
    (instruction_id, reconciliation_status,
     request_id, trace_id, actor, actor_role)
VALUES
    ('f47ac10b-58cc-4372-a567-0e02b2c3d479', 'MATCHED',
     'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM');

-- Outbox event: reconciliation passed
INSERT INTO outbox_events
    (id, aggregate_id, event_type, payload,
     request_id, trace_id, actor, actor_role,
     created_at)
VALUES (
    gen_random_uuid(),
    'f47ac10b-58cc-4372-a567-0e02b2c3d479',
    'dvp.reconciliation_matched',
    '{"instruction_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479", "result": "MATCHED"}'::jsonb,
    'a0a0a0a0-0000-0000-0000-000000000001', 'b0b0b0b0-0000-0000-0000-000000000001', 'SYSTEM/sandbox', 'SYSTEM',
    NOW()
);


-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- All queries use _current views for derived state.
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
FROM dvp_instructions_current d
WHERE d.id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';


-- ─────────────────────────────────────────────────────────────────────────────
-- V2. Post-Settlement Position Verification (derived from ledger views)
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    e.entity_name,
    cb.isin,
    cp.security_description,
    cb.available_quantity,
    cb.locked_quantity,
    cp.custodian
FROM custody_balances cb
JOIN custody_positions cp ON cp.entity_id = cb.entity_id AND cp.isin = cb.isin
JOIN registered_entities e ON e.lei = cb.entity_id
WHERE cb.isin = 'US0378331005'
ORDER BY e.entity_name;

SELECT
    e.entity_name,
    cb.currency,
    '$' || TO_CHAR(cb.balance,           'FM999,999,999.00') AS total_balance,
    '$' || TO_CHAR(cb.available_balance, 'FM999,999,999.00') AS available_balance,
    '$' || TO_CHAR(cb.locked_balance,    'FM999,999,999.00') AS locked_balance,
    ca.account_type
FROM cash_balances cb
JOIN cash_accounts ca ON ca.entity_id = cb.entity_id AND ca.currency = cb.currency
JOIN registered_entities e ON e.lei = cb.entity_id
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
FROM settlement_legs_current sl
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
FROM escrow_accounts_current ea
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
-- V6. Hybrid Rail Message Status
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    hrm.rail,
    hrm.message_type,
    hrm.status,
    hrm.rail_reference                        AS uetr_or_imad,
    hrm.submitted_at,
    hrm.confirmed_at
FROM hybrid_rail_messages_current hrm
WHERE hrm.instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479'
ORDER BY hrm.submitted_at;


-- ─────────────────────────────────────────────────────────────────────────────
-- V7. Outbox Event Delivery Queue
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    event_type,
    created_at,
    delivery_status,
    published_at
FROM outbox_events_current
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
        SELECT COUNT(*) FROM hybrid_rail_messages_current hrm
        WHERE hrm.instruction_id = d.id AND hrm.status = 'CONFIRMED'
    )                                                       AS rail_messages_confirmed,
    rr.result                                               AS reconciliation_result,
    LEFT(d.swap_tx_hash, 30) || '...'                       AS atomic_swap_tx,
    d.settled_at
FROM dvp_instructions_current d
LEFT JOIN compliance_screenings cs  ON cs.instruction_id = d.id
LEFT JOIN reconciliation_reports rr ON rr.instruction_id = d.id
WHERE d.id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';


-- ─────────────────────────────────────────────────────────────────────────────
-- V10. Full State Machine Audit Trail (from event log)
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    COALESCE(status, 'RECONCILIATION') AS state_transition,
    COALESCE(reconciliation_status, '')  AS reconciliation_status,
    created_at                           AS occurred_at
FROM dvp_instruction_events
WHERE instruction_id = 'f47ac10b-58cc-4372-a567-0e02b2c3d479'
ORDER BY created_at;


-- ─────────────────────────────────────────────────────────────────────────────
-- V11. Ledger Audit Trail (append-only — every entry is immutable)
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'SECURITY' AS ledger, entity_id, isin AS asset, pool, amount, reason, created_at
FROM security_ledger
WHERE isin = 'US0378331005'
ORDER BY created_at;

SELECT 'CASH' AS ledger, entity_id, currency AS asset, pool, amount, reason, created_at
FROM cash_ledger
WHERE currency = 'USD'
ORDER BY created_at;


/*
══════════════════════════════════════════════════════════════════════════════
EXPECTED FINAL STATE (V9 Summary Query)
══════════════════════════════════════════════════════════════════════════════

  trade_reference           = BLK-SST-AAPL-20260320-001
  settlement_status         = CONFIRMED
  reconciliation_status     = MATCHED
  shares_settled            = 500,000
  notional_settled          = $97,500,000.00
  compliance_cleared        = true
  multisig_approvals        = 2
  rail_messages_confirmed   = 2     (MT543 + MT103)
  reconciliation_result     = MATCHED
  atomic_swap_tx            = 0xATOMIC_SWAP_TX_HASH_f47ac10...
  settled_at                = [timestamp]

APPEND-ONLY ARCHITECTURE:
══════════════════════════════════════════════════════════════════════════════

  Every table is INSERT-only. No UPDATEs. No DELETEs.
  Database-level BEFORE triggers prevent any mutation.

  Financial state:   security_ledger / cash_ledger (double-entry, signed amounts)
  Derived balances:  custody_balances / cash_balances (SUM views)
  State machines:    *_events tables (append-only status transitions)
  Current state:     *_current views (latest event per entity)

LEDGER AUDIT TRAIL (V11):
  SECURITY | BlackRock  | AAPL | AVAILABLE | +2,000,000 | INITIAL_BALANCE
  SECURITY | BlackRock  | AAPL | AVAILABLE |   -500,000 | LOCK
  SECURITY | BlackRock  | AAPL | LOCKED    |   +500,000 | LOCK
  SECURITY | BlackRock  | AAPL | LOCKED    |   -500,000 | DELIVERY_DEBIT
  SECURITY | State St   | AAPL | AVAILABLE |   +500,000 | DELIVERY_CREDIT
  CASH     | State St   | USD  | AVAILABLE | +500,000,000 | INITIAL_BALANCE
  CASH     | BlackRock  | USD  | AVAILABLE |  +10,000,000 | INITIAL_BALANCE
  CASH     | State St   | USD  | AVAILABLE |  -97,500,000 | LOCK
  CASH     | State St   | USD  | LOCKED    |  +97,500,000 | LOCK
  CASH     | State St   | USD  | LOCKED    |  -97,500,000 | DELIVERY_DEBIT
  CASH     | BlackRock  | USD  | AVAILABLE |  +97,500,000 | DELIVERY_CREDIT

STATE MACHINE TRACE (from dvp_instruction_events):
  PENDING → COMPLIANCE_CHECK → LEGS_LOCKED → ESCROW_FUNDED
  → MULTISIG_PENDING → APPROVED → SIGNED → BROADCASTED
  → CONFIRMED (irrevocable) → reconciliation_status = MATCHED

══════════════════════════════════════════════════════════════════════════════
*/
