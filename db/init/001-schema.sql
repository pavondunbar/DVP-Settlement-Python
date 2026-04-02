-- ========================================================================
-- DVP Settlement & Clearing System — Database Schema
-- Append-only architecture: every table is INSERT-only.
-- UPDATE and DELETE prohibited via BEFORE triggers.
-- ========================================================================


-- Extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- =========================================================================
-- IMMUTABILITY ENFORCEMENT
-- Every table is append-only. UPDATE and DELETE are prohibited.
-- =========================================================================

CREATE OR REPLACE FUNCTION deny_mutation() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Append-only: % on table "%" is prohibited',
        TG_OP, TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;


-- -------------------------------------------------------------------------
-- 1. registered_entities
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 2. custody_positions
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 3. cash_accounts
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 3a. security_ledger (append-only)
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 3b. cash_ledger (append-only)
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 3c. custody_balances (derived view)
-- -------------------------------------------------------------------------

CREATE VIEW custody_balances AS
SELECT entity_id, isin,
    COALESCE(SUM(amount) FILTER (WHERE pool = 'AVAILABLE'), 0) AS available_quantity,
    COALESCE(SUM(amount) FILTER (WHERE pool = 'LOCKED'), 0)    AS locked_quantity
FROM security_ledger
GROUP BY entity_id, isin;


-- -------------------------------------------------------------------------
-- 3d. cash_balances (derived view)
-- -------------------------------------------------------------------------

CREATE VIEW cash_balances AS
SELECT entity_id, currency,
    COALESCE(SUM(amount), 0)                                     AS balance,
    COALESCE(SUM(amount) FILTER (WHERE pool = 'AVAILABLE'), 0)   AS available_balance,
    COALESCE(SUM(amount) FILTER (WHERE pool = 'LOCKED'), 0)      AS locked_balance
FROM cash_ledger
GROUP BY entity_id, currency;


-- -------------------------------------------------------------------------
-- 3e. Non-negative balance triggers
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 4. dvp_instructions
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 4a. dvp_instruction_events (append-only state transitions)
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 4b. dvp_instructions_current (derived view)
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 5. compliance_screenings
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 6. settlement_legs
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 6a. settlement_leg_events (append-only state transitions)
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 6b. settlement_legs_current (derived view)
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 7. escrow_accounts
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 7a. escrow_account_events (append-only state transitions)
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 7b. escrow_accounts_current (derived view)
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 8. multisig_approvals
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 9. hybrid_rail_messages
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 9a. hybrid_rail_message_events (append-only state transitions)
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 9b. hybrid_rail_messages_current (derived view)
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 10. outbox_events
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 10a. outbox_delivery_log (append-only delivery tracking)
-- -------------------------------------------------------------------------

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
  'Append-only delivery tracking for outbox events.';

CREATE UNIQUE INDEX idx_delivery_published ON outbox_delivery_log (event_id) WHERE status = 'PUBLISHED';
CREATE UNIQUE INDEX idx_delivery_dlq       ON outbox_delivery_log (event_id) WHERE status = 'DLQ';
CREATE INDEX idx_delivery_event            ON outbox_delivery_log (event_id, created_at);

CREATE TRIGGER trg_deny_update_outbox_delivery_log
    BEFORE UPDATE ON outbox_delivery_log FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_outbox_delivery_log
    BEFORE DELETE ON outbox_delivery_log FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- -------------------------------------------------------------------------
-- 10c. consumed_events (consumer-side idempotency)
--      Tracks which events each consumer group has already processed.
--      Enables exactly-once semantics on top of at-least-once delivery.
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 10d. outbox_events_current (derived view)
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 11. reconciliation_reports
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 12. audit_log — Append-only audit trail for all operations
-- -------------------------------------------------------------------------

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

COMMENT ON TABLE audit_log IS
  'Append-only audit trail. Every service operation writes an entry '
  'with actor identity, operation type, and resource affected.';

CREATE INDEX idx_audit_log_request   ON audit_log (request_id);
CREATE INDEX idx_audit_log_trace     ON audit_log (trace_id);
CREATE INDEX idx_audit_log_actor     ON audit_log (actor);
CREATE INDEX idx_audit_log_operation ON audit_log (operation);
CREATE INDEX idx_audit_log_created   ON audit_log (created_at);

CREATE TRIGGER trg_deny_update_audit_log
    BEFORE UPDATE ON audit_log FOR EACH ROW EXECUTE FUNCTION deny_mutation();
CREATE TRIGGER trg_deny_delete_audit_log
    BEFORE DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION deny_mutation();


-- -------------------------------------------------------------------------
-- 13. RBAC Tables — Role-Based Access Control
-- -------------------------------------------------------------------------

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


-- -------------------------------------------------------------------------
-- 14. RBAC Seed Data
-- -------------------------------------------------------------------------

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
