"""
Containerized DVP Settlement Service entry point.

Reads DB connection from environment variables, creates asyncpg pool,
wires all services with sandbox stubs, and runs the full demo lifecycle.
"""

import asyncio
import contextlib
import json
import logging
import os
import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from enum import Enum
from typing import Optional


class StructuredFormatter(logging.Formatter):
    def format(self, record):
        log_entry = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for attr in ("request_id", "trace_id", "actor"):
            if hasattr(record, attr):
                log_entry[attr] = getattr(record, attr)
        return json.dumps(log_entry)

handler = logging.StreamHandler()
handler.setFormatter(StructuredFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
logger = logging.getLogger("dvp_settlement")

import asyncpg


# -------------------------------------------------------------------------
# Configuration from environment
# -------------------------------------------------------------------------

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "dvp_settlement")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "postgres")


def _dsn() -> str:
    return f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _new_id() -> str:
    return str(uuid.uuid4())


# -------------------------------------------------------------------------
# Enumerations
# -------------------------------------------------------------------------

class SettlementStatus(str, Enum):
    PENDING = "PENDING"
    COMPLIANCE_CHECK = "COMPLIANCE_CHECK"
    LEGS_LOCKED = "LEGS_LOCKED"
    ESCROW_FUNDED = "ESCROW_FUNDED"
    MULTISIG_PENDING = "MULTISIG_PENDING"
    APPROVED = "APPROVED"
    SIGNED = "SIGNED"
    BROADCASTED = "BROADCASTED"
    CONFIRMED = "CONFIRMED"
    FAILED = "FAILED"
    REVERSED = "REVERSED"


class LegType(str, Enum):
    SECURITY = "SECURITY"
    CASH = "CASH"


class LegStatus(str, Enum):
    PENDING = "PENDING"
    LOCKED = "LOCKED"
    IN_ESCROW = "IN_ESCROW"
    DELIVERED = "DELIVERED"
    RELEASED = "RELEASED"
    FAILED = "FAILED"


class SettlementRail(str, Enum):
    SWIFT = "SWIFT"
    FEDWIRE = "FEDWIRE"
    CLS = "CLS"
    ONCHAIN = "ONCHAIN"
    INTERNAL = "INTERNAL"


class SecurityType(str, Enum):
    EQUITY = "EQUITY"


class MultiSigVote(str, Enum):
    APPROVE = "APPROVE"
    REJECT = "REJECT"
    ABSTAIN = "ABSTAIN"


class HybridRailStatus(str, Enum):
    PENDING = "PENDING"
    SUBMITTED = "SUBMITTED"
    CONFIRMED = "CONFIRMED"
    REJECTED = "REJECTED"
    TIMED_OUT = "TIMED_OUT"


class ReconciliationResult(str, Enum):
    MATCHED = "MATCHED"
    MISMATCH = "MISMATCH"
    SUSPENDED = "SUSPENDED"


@dataclass(frozen=True)
class AuditContext:
    request_id: str
    trace_id: str
    actor: str
    actor_role: str

    def as_sql_args(self) -> tuple:
        return (
            self.request_id, self.trace_id,
            self.actor, self.actor_role,
        )

    def as_dict(self) -> dict:
        return {
            "request_id": self.request_id,
            "trace_id": self.trace_id,
            "actor": self.actor,
            "actor_role": self.actor_role,
        }

    @staticmethod
    def system(label: str = "orchestrator") -> "AuditContext":
        return AuditContext(
            request_id=str(uuid.uuid4()),
            trace_id=str(uuid.uuid4()),
            actor=f"SYSTEM/{label}",
            actor_role="SYSTEM",
        )


# -------------------------------------------------------------------------
# Domain Dataclasses
# -------------------------------------------------------------------------

@dataclass
class SettlementInstruction:
    id: str
    trade_reference: str
    isin: str
    security_type: SecurityType
    quantity: Decimal
    price_per_unit: Decimal
    settlement_amount: Decimal
    currency: str
    seller_entity_id: str
    buyer_entity_id: str
    seller_wallet: str
    buyer_wallet: str
    seller_custodian: str
    buyer_custodian: str
    settlement_rail: SettlementRail
    intended_settlement_date: str
    status: SettlementStatus = SettlementStatus.PENDING
    created_at: str = field(default_factory=_now)
    settled_at: Optional[str] = None
    failure_reason: Optional[str] = None
    idempotency_key: str = field(default_factory=_new_id)


@dataclass
class ComplianceDecision:
    is_cleared: bool
    reason: str
    screening_reference: str
    screened_at: str = field(default_factory=_now)


# -------------------------------------------------------------------------
# Exceptions
# -------------------------------------------------------------------------

class DVPSettlementError(Exception):
    pass

class ReconciliationHalt(DVPSettlementError):
    pass


# -------------------------------------------------------------------------
# Abstract Interfaces
# -------------------------------------------------------------------------

class AbstractDB(ABC):
    @abstractmethod
    async def fetchrow(self, query: str, *args): ...
    @abstractmethod
    async def fetch(self, query: str, *args): ...
    @abstractmethod
    async def execute(self, query: str, *args): ...
    @abstractmethod
    async def transaction(self): ...


class AbstractComplianceProvider(ABC):
    @abstractmethod
    async def screen_entity(
        self, entity_id: str, jurisdiction: str,
        lei: Optional[str] = None,
    ) -> ComplianceDecision: ...


class AbstractHSMSigningService(ABC):
    @abstractmethod
    async def sign(self, payload: dict, signer_id: str) -> str: ...


class AbstractSigningQueue(ABC):
    @abstractmethod
    async def enqueue(
        self, instruction_id: str, payload: dict,
    ) -> str: ...


class AbstractChainAdapter(ABC):
    @abstractmethod
    async def get_balance(
        self, wallet: str, token_address: str,
    ) -> Decimal: ...

    @abstractmethod
    async def transfer_to_escrow(
        self, from_wallet: str, escrow_address: str,
        amount: Decimal, token_address: str,
        instruction_id: str,
    ) -> str: ...

    @abstractmethod
    async def atomic_swap(
        self, security_escrow: str,
        security_beneficiary: str,
        cash_escrow: str, cash_beneficiary: str,
        instruction_id: str,
    ) -> str: ...


class AbstractSWIFTGateway(ABC):
    @abstractmethod
    async def send_mt(
        self, message_type: str, payload: dict,
    ) -> str: ...


class AbstractFedWireGateway(ABC):
    @abstractmethod
    async def submit_fedwire(self, payload: dict) -> str: ...


class AbstractCLSGateway(ABC):
    @abstractmethod
    async def submit_cls_instruction(
        self, payload: dict,
    ) -> str: ...


# -------------------------------------------------------------------------
# AsyncpgDB — Real Database Adapter
# -------------------------------------------------------------------------

async def _init_connection(conn):
    for typename in (
        'uuid', 'timestamptz', 'timestamp', 'date',
    ):
        await conn.set_type_codec(
            typename, encoder=str, decoder=str,
            schema='pg_catalog', format='text',
        )
    await conn.set_type_codec(
        'jsonb',
        encoder=lambda v: (
            v if isinstance(v, str) else json.dumps(v)
        ),
        decoder=json.loads,
        schema='pg_catalog', format='text',
    )


class AsyncpgDB(AbstractDB):
    def __init__(self, pool):
        self._pool = pool
        self._tx_conn = None

    async def fetchrow(self, query, *args):
        target = self._tx_conn or self._pool
        return await target.fetchrow(query, *args)

    async def fetch(self, query, *args):
        target = self._tx_conn or self._pool
        return await target.fetch(query, *args)

    async def execute(self, query, *args):
        target = self._tx_conn or self._pool
        return await target.execute(query, *args)

    @contextlib.asynccontextmanager
    async def transaction(self):
        if self._tx_conn is not None:
            async with self._tx_conn.transaction():
                yield
        else:
            async with self._pool.acquire() as conn:
                async with conn.transaction():
                    self._tx_conn = conn
                    try:
                        yield
                    finally:
                        self._tx_conn = None


# -------------------------------------------------------------------------
# Sandbox Stubs
# -------------------------------------------------------------------------

class SandboxComplianceProvider(AbstractComplianceProvider):
    async def screen_entity(
        self, entity_id, jurisdiction, lei=None,
    ) -> ComplianceDecision:
        return ComplianceDecision(
            is_cleared=True,
            reason="SANDBOX — screening bypassed",
            screening_reference=(
                f"SANDBOX-{uuid.uuid4().hex[:8].upper()}"
            ),
        )


class SandboxHSMSigningService(AbstractHSMSigningService):
    async def sign(self, payload: dict, signer_id: str) -> str:
        import hashlib
        return hashlib.sha256(
            json.dumps(payload, sort_keys=True).encode()
        ).hexdigest()


class SandboxChainAdapter(AbstractChainAdapter):
    async def get_balance(self, wallet, token_address) -> Decimal:
        return Decimal("9999999")

    async def transfer_to_escrow(
        self, from_wallet, escrow_address, amount,
        token_address, instruction_id,
    ) -> str:
        return f"0x{uuid.uuid4().hex}"

    async def atomic_swap(
        self, security_escrow, security_beneficiary,
        cash_escrow, cash_beneficiary, instruction_id,
    ) -> str:
        return f"0xSWAP{uuid.uuid4().hex}"


class SandboxSWIFTGateway(AbstractSWIFTGateway):
    async def send_mt(self, message_type, payload) -> str:
        uetr = str(uuid.uuid4())
        logger.info(
            "[SWIFT STUB] Sent %s — UETR=%s",
            message_type, uetr,
        )
        return uetr


class SandboxFedWireGateway(AbstractFedWireGateway):
    async def submit_fedwire(self, payload) -> str:
        imad = uuid.uuid4().hex[:16].upper()
        logger.info("[FEDWIRE STUB] Submitted — IMAD=%s", imad)
        return imad


class SandboxCLSGateway(AbstractCLSGateway):
    async def submit_cls_instruction(self, payload) -> str:
        ref = f"CLS{uuid.uuid4().hex[:10].upper()}"
        logger.info("[CLS STUB] Submitted — ref=%s", ref)
        return ref


class SandboxSigningQueue(AbstractSigningQueue):
    async def enqueue(
        self, instruction_id: str, payload: dict,
    ) -> str:
        msg_id = str(uuid.uuid4())
        logger.info(
            "[QUEUE STUB] Enqueued instruction=%s msg=%s",
            instruction_id, msg_id,
        )
        return msg_id


# -------------------------------------------------------------------------
# Simplified Service Implementations (for containerized demo)
# -------------------------------------------------------------------------

async def _write_outbox(
    db: AbstractDB, instruction_id: str,
    event_type: str, payload: dict,
    ctx: AuditContext,
):
    payload = {**payload, **ctx.as_dict()}
    await db.execute(
        "INSERT INTO outbox_events "
        "(id, aggregate_id, event_type, payload, "
        "request_id, trace_id, actor, actor_role, created_at) "
        "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)",
        _new_id(), instruction_id, event_type,
        json.dumps(payload), *ctx.as_sql_args(), _now(),
    )


async def register_entities(db: AbstractDB, ctx: AuditContext):
    """Register demo institutional participants."""
    logger.info("Registering institutional entities...")
    entities = [
        (
            "BlackRock, Inc.", "549300BNMGNFKN6LAD61",
            "ASSET_MANAGER", "United States", "SEC", "BLRKUS33",
        ),
        (
            "State Street Bank and Trust Company",
            "571474TGEMMWANRLN572",
            "CUSTODIAN", "United States", "OCC / FRB", "SBOSUS33",
        ),
        (
            "The Bank of New York Mellon",
            "WFLLPEPC7FZXENRZV498",
            "CUSTODIAN", "United States", "FRB / OCC", "IRVTUS3N",
        ),
        (
            "Depository Trust & Clearing Corporation",
            "213800ZBKL9BHSL2K459",
            "CCP", "United States", "SEC / CFTC", "DTCCUS3N",
        ),
    ]
    for name, lei, etype, juris, reg, bic in entities:
        existing = await db.fetchrow(
            "SELECT id FROM registered_entities WHERE lei = $1",
            lei,
        )
        if existing:
            continue
        await db.execute(
            "INSERT INTO registered_entities "
            "(id, entity_name, lei, entity_type, "
            "jurisdiction, regulator, bic) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7)",
            _new_id(), name, lei, etype, juris, reg, bic,
        )
    logger.info("Entities registered")


async def initialize_positions(db: AbstractDB, ctx: AuditContext):
    """Set up custody positions and cash accounts."""
    logger.info("Initializing positions and accounts...")

    seller_lei = "549300BNMGNFKN6LAD61"
    buyer_lei = "571474TGEMMWANRLN572"
    isin = "US0378331005"

    # Custody positions (metadata)
    for lei, wallet in [
        (seller_lei, "0xBLACKROCK_WALLET_ADDRESS"),
        (buyer_lei, "0xSTATESTREET_WALLET_ADDRESS"),
    ]:
        existing = await db.fetchrow(
            "SELECT id FROM custody_positions "
            "WHERE entity_id = $1 AND isin = $2",
            lei, isin,
        )
        if existing:
            continue
        await db.execute(
            "INSERT INTO custody_positions "
            "(id, entity_id, isin, cusip, "
            "security_description, token_address, "
            "wallet_address, custodian) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7,$8)",
            _new_id(), lei, isin, "037833100",
            "Apple Inc. Common Stock",
            "0xAAPL_TOKEN_CONTRACT_ADDRESS",
            wallet, "DTC",
        )

    # Initial security balance for seller
    bal = await db.fetchrow(
        "SELECT available_quantity FROM custody_balances "
        "WHERE entity_id = $1 AND isin = $2",
        seller_lei, isin,
    )
    if not bal or Decimal(str(bal["available_quantity"])) == 0:
        await db.execute(
            "INSERT INTO security_ledger "
            "(entity_id, isin, pool, amount, reason, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,'AVAILABLE',$3,'INITIAL_BALANCE',"
            "$4,$5,$6,$7)",
            seller_lei, isin, Decimal("2000000"),
            *ctx.as_sql_args(),
        )

    # Cash accounts (metadata)
    for lei, aba, bic in [
        (buyer_lei, "011000028", "SBOSUS33"),
        (seller_lei, "021000018", "BLRKUS33"),
    ]:
        existing = await db.fetchrow(
            "SELECT id FROM cash_accounts "
            "WHERE entity_id = $1 AND currency = $2",
            lei, "USD",
        )
        if existing:
            continue
        await db.execute(
            "INSERT INTO cash_accounts "
            "(id, entity_id, currency, account_type, "
            "bank_aba, swift_bic) "
            "VALUES ($1,$2,$3,$4,$5,$6)",
            _new_id(), lei, "USD", "TOKENIZED_CASH", aba, bic,
        )

    # Initial cash balances
    for lei, amount in [
        (buyer_lei, Decimal("500000000")),
        (seller_lei, Decimal("10000000")),
    ]:
        bal = await db.fetchrow(
            "SELECT balance FROM cash_balances "
            "WHERE entity_id = $1 AND currency = $2",
            lei, "USD",
        )
        if not bal or Decimal(str(bal["balance"])) == 0:
            await db.execute(
                "INSERT INTO cash_ledger "
                "(entity_id, currency, pool, amount, reason, "
                "request_id, trace_id, actor, actor_role) "
                "VALUES ($1,$2,'AVAILABLE',$3,'INITIAL_BALANCE',"
                "$4,$5,$6,$7)",
                lei, "USD", amount, *ctx.as_sql_args(),
            )

    logger.info("Positions and accounts initialized")


async def run_settlement(db: AbstractDB, ctx: AuditContext):
    """Execute full DVP settlement lifecycle."""
    logger.info("=" * 60)
    logger.info(
        "Starting DVP settlement: "
        "BlackRock 100K AAPL -> State Street | $19.5M USD"
    )
    logger.info("=" * 60)

    seller_lei = "549300BNMGNFKN6LAD61"
    buyer_lei = "571474TGEMMWANRLN572"
    isin = "US0378331005"
    quantity = Decimal("100000")
    price = Decimal("195.00")
    amount = quantity * price
    instruction_id = _new_id()
    idem_key = f"DVP-DOCKER-{uuid.uuid4().hex[:8]}"

    # Step 1: Create DVP instruction
    logger.info("[1/9] Creating DVP instruction...")
    async with db.transaction():
        await db.execute(
            "INSERT INTO dvp_instructions "
            "(id, trade_reference, isin, security_type, "
            "quantity, price_per_unit, settlement_amount, "
            "currency, seller_entity_id, buyer_entity_id, "
            "seller_wallet, buyer_wallet, "
            "seller_custodian, buyer_custodian, "
            "settlement_rail, intended_settlement_date, "
            "idempotency_key, created_at, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES "
            "($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,"
            "$11,$12,$13,$14,$15,$16,$17,$18,"
            "$19,$20,$21,$22)",
            instruction_id,
            "BLK-SST-AAPL-DOCKER-001",
            isin, "EQUITY", quantity, price, amount, "USD",
            seller_lei, buyer_lei,
            "0xBLACKROCK_WALLET_ADDRESS",
            "0xSTATESTREET_WALLET_ADDRESS",
            "IRVTUS3N", "SBOSUS33",
            "SWIFT", "2026-03-27",
            idem_key, _now(), *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO dvp_instruction_events "
            "(id, instruction_id, status, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7)",
            _new_id(), instruction_id,
            SettlementStatus.PENDING,
            *ctx.as_sql_args(),
        )
        await _write_outbox(
            db, instruction_id, "dvp.initiated",
            {"instruction_id": instruction_id}, ctx,
        )
    logger.info("  Instruction %s created", instruction_id)

    # Step 2: Compliance screening
    logger.info("[2/9] Compliance screening...")
    provider = SandboxComplianceProvider()
    seller_dec = await provider.screen_entity(
        seller_lei, "US",
    )
    buyer_dec = await provider.screen_entity(buyer_lei, "US")
    await db.execute(
        "INSERT INTO compliance_screenings "
        "(id, instruction_id, seller_entity_id, "
        "buyer_entity_id, is_cleared, reason, "
        "screening_reference, screened_at, "
        "request_id, trace_id, actor, actor_role) "
        "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",
        _new_id(), instruction_id,
        seller_lei, buyer_lei, True,
        "Both counterparties cleared",
        f"{seller_dec.screening_reference}"
        f"|{buyer_dec.screening_reference}",
        _now(), *ctx.as_sql_args(),
    )
    await db.execute(
        "INSERT INTO dvp_instruction_events "
        "(id, instruction_id, status, "
        "request_id, trace_id, actor, actor_role) "
        "VALUES ($1,$2,$3,$4,$5,$6,$7)",
        _new_id(), instruction_id,
        SettlementStatus.COMPLIANCE_CHECK,
        *ctx.as_sql_args(),
    )
    logger.info("  Both parties cleared")

    # Step 3: Lock settlement legs
    logger.info("[3/9] Locking settlement legs...")
    sec_leg_id = _new_id()
    cash_leg_id = _new_id()
    async with db.transaction():
        # Lock securities
        await db.execute(
            "INSERT INTO security_ledger "
            "(id, entity_id, isin, pool, amount, "
            "instruction_id, reason, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,'AVAILABLE',$4,$5,'LOCK',"
            "$6,$7,$8,$9)",
            _new_id(), seller_lei, isin, -quantity,
            instruction_id, *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO security_ledger "
            "(id, entity_id, isin, pool, amount, "
            "instruction_id, reason, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,'LOCKED',$4,$5,'LOCK',"
            "$6,$7,$8,$9)",
            _new_id(), seller_lei, isin, quantity,
            instruction_id, *ctx.as_sql_args(),
        )
        # Lock cash
        await db.execute(
            "INSERT INTO cash_ledger "
            "(id, entity_id, currency, pool, amount, "
            "instruction_id, reason, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,'AVAILABLE',$4,$5,'LOCK',"
            "$6,$7,$8,$9)",
            _new_id(), buyer_lei, "USD", -amount,
            instruction_id, *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO cash_ledger "
            "(id, entity_id, currency, pool, amount, "
            "instruction_id, reason, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,'LOCKED',$4,$5,'LOCK',"
            "$6,$7,$8,$9)",
            _new_id(), buyer_lei, "USD", amount,
            instruction_id, *ctx.as_sql_args(),
        )
        # Create legs
        await db.execute(
            "INSERT INTO settlement_legs "
            "(id, instruction_id, leg_type, "
            "originator_entity_id, beneficiary_entity_id, "
            "amount, currency, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
            sec_leg_id, instruction_id, "SECURITY",
            seller_lei, buyer_lei, quantity, isin,
            *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO settlement_leg_events "
            "(id, leg_id, status, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7)",
            _new_id(), sec_leg_id, "LOCKED",
            *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO settlement_legs "
            "(id, instruction_id, leg_type, "
            "originator_entity_id, beneficiary_entity_id, "
            "amount, currency, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
            cash_leg_id, instruction_id, "CASH",
            buyer_lei, seller_lei, amount, "USD",
            *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO settlement_leg_events "
            "(id, leg_id, status, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7)",
            _new_id(), cash_leg_id, "LOCKED",
            *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO dvp_instruction_events "
            "(id, instruction_id, status, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7)",
            _new_id(), instruction_id,
            SettlementStatus.LEGS_LOCKED,
            *ctx.as_sql_args(),
        )
        await _write_outbox(
            db, instruction_id, "dvp.legs_locked",
            {
                "instruction_id": instruction_id,
                "security_leg_id": sec_leg_id,
                "cash_leg_id": cash_leg_id,
            }, ctx,
        )
    logger.info("  Both legs locked")

    # Step 4: Fund escrow accounts
    logger.info("[4/9] Funding escrow accounts...")
    chain = SandboxChainAdapter()
    sec_tx = await chain.transfer_to_escrow(
        "0xBLACKROCK_WALLET_ADDRESS",
        "0xSECURITY_ESCROW_CONTRACT",
        quantity, "0xAAPL_TOKEN", instruction_id,
    )
    cash_tx = await chain.transfer_to_escrow(
        "0xSTATESTREET_WALLET_ADDRESS",
        "0xCASH_ESCROW_CONTRACT",
        amount, "0xUSD_TOKEN", instruction_id,
    )
    sec_escrow_id = _new_id()
    cash_escrow_id = _new_id()
    async with db.transaction():
        await db.execute(
            "INSERT INTO escrow_accounts "
            "(id, instruction_id, leg_type, "
            "holder_entity_id, amount, currency, "
            "escrow_address, on_chain_tx_hash, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,"
            "$9,$10,$11,$12)",
            sec_escrow_id, instruction_id, "SECURITY",
            seller_lei, quantity, isin,
            "0xSECURITY_ESCROW_CONTRACT", sec_tx,
            *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO escrow_account_events "
            "(id, escrow_id, status, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7)",
            _new_id(), sec_escrow_id, "IN_ESCROW",
            *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO escrow_accounts "
            "(id, instruction_id, leg_type, "
            "holder_entity_id, amount, currency, "
            "escrow_address, on_chain_tx_hash, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,"
            "$9,$10,$11,$12)",
            cash_escrow_id, instruction_id, "CASH",
            buyer_lei, amount, "USD",
            "0xCASH_ESCROW_CONTRACT", cash_tx,
            *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO escrow_account_events "
            "(id, escrow_id, status, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7)",
            _new_id(), cash_escrow_id, "IN_ESCROW",
            *ctx.as_sql_args(),
        )
        # Leg events
        for leg_id in [sec_leg_id, cash_leg_id]:
            await db.execute(
                "INSERT INTO settlement_leg_events "
                "(id, leg_id, status, "
                "request_id, trace_id, actor, actor_role) "
                "VALUES ($1,$2,$3,$4,$5,$6,$7)",
                _new_id(), leg_id, "IN_ESCROW",
                *ctx.as_sql_args(),
            )
        await db.execute(
            "INSERT INTO dvp_instruction_events "
            "(id, instruction_id, status, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7)",
            _new_id(), instruction_id,
            SettlementStatus.ESCROW_FUNDED,
            *ctx.as_sql_args(),
        )
        await _write_outbox(
            db, instruction_id, "dvp.escrow_funded",
            {
                "instruction_id": instruction_id,
                "security_tx_hash": sec_tx,
                "cash_tx_hash": cash_tx,
            }, ctx,
        )
    logger.info("  Escrow funded — sec_tx=%s cash_tx=%s", sec_tx, cash_tx)

    # Step 5: Submit SWIFT messages
    logger.info("[5/9] Submitting SWIFT messages...")
    swift = SandboxSWIFTGateway()
    mt543_uetr = await swift.send_mt("MT543", {})
    mt103_uetr = await swift.send_mt("MT103", {})
    for msg_type, uetr in [
        ("MT543", mt543_uetr),
        ("MT103", mt103_uetr),
    ]:
        msg_id = _new_id()
        await db.execute(
            "INSERT INTO hybrid_rail_messages "
            "(id, instruction_id, rail, message_type, "
            "payload, rail_reference, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)",
            msg_id, instruction_id, "SWIFT", msg_type,
            json.dumps({"uetr": uetr}), uetr,
            *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO hybrid_rail_message_events "
            "(id, message_id, status, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7)",
            _new_id(), msg_id, "SUBMITTED",
            *ctx.as_sql_args(),
        )
    await db.execute(
        "INSERT INTO dvp_instruction_events "
        "(id, instruction_id, status, "
        "request_id, trace_id, actor, actor_role) "
        "VALUES ($1,$2,$3,$4,$5,$6,$7)",
        _new_id(), instruction_id,
        SettlementStatus.MULTISIG_PENDING,
        *ctx.as_sql_args(),
    )
    logger.info("  SWIFT MT543 + MT103 submitted")

    # Step 6: Multi-sig approval
    logger.info("[6/9] Casting multi-sig votes...")
    hsm = SandboxHSMSigningService()
    for cust_id, signer in [
        ("IRVTUS3N", "HSM-BNYM-KEY-001"),
        ("SBOSUS33", "HSM-SST-KEY-001"),
    ]:
        sig = await hsm.sign(
            {"instruction_id": instruction_id}, signer,
        )
        await db.execute(
            "INSERT INTO multisig_approvals "
            "(id, instruction_id, custodian_id, signer_id, "
            "vote, signature, voted_at, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
            _new_id(), instruction_id, cust_id, signer,
            "APPROVE", sig, _now(), *ctx.as_sql_args(),
        )
    await db.execute(
        "INSERT INTO dvp_instruction_events "
        "(id, instruction_id, status, "
        "request_id, trace_id, actor, actor_role) "
        "VALUES ($1,$2,$3,$4,$5,$6,$7)",
        _new_id(), instruction_id,
        SettlementStatus.APPROVED,
        *ctx.as_sql_args(),
    )
    await _write_outbox(
        db, instruction_id, "dvp.multisig_approved",
        {"instruction_id": instruction_id, "quorum": 2},
        ctx,
    )
    logger.info("  Multi-sig quorum reached (2-of-3)")

    # Step 7: Atomic swap
    logger.info("[7/9] Executing atomic swap (IRREVOCABLE)...")
    await db.execute(
        "INSERT INTO dvp_instruction_events "
        "(id, instruction_id, status, "
        "request_id, trace_id, actor, actor_role) "
        "VALUES ($1,$2,$3,$4,$5,$6,$7)",
        _new_id(), instruction_id,
        SettlementStatus.SIGNED,
        *ctx.as_sql_args(),
    )
    swap_tx = await chain.atomic_swap(
        "0xSECURITY_ESCROW_CONTRACT",
        "0xSTATESTREET_WALLET_ADDRESS",
        "0xCASH_ESCROW_CONTRACT",
        "0xBLACKROCK_WALLET_ADDRESS",
        instruction_id,
    )
    # Mark transaction as broadcast to chain
    await db.execute(
        "INSERT INTO dvp_instruction_events "
        "(id, instruction_id, status, "
        "request_id, trace_id, actor, actor_role) "
        "VALUES ($1,$2,$3,$4,$5,$6,$7)",
        _new_id(), instruction_id,
        SettlementStatus.BROADCASTED,
        *ctx.as_sql_args(),
    )
    async with db.transaction():
        await db.execute(
            "INSERT INTO dvp_instruction_events "
            "(id, instruction_id, status, swap_tx_hash, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7,$8)",
            _new_id(), instruction_id,
            SettlementStatus.CONFIRMED, swap_tx,
            *ctx.as_sql_args(),
        )
        # Debit/credit ledger entries
        await db.execute(
            "INSERT INTO security_ledger "
            "(id, entity_id, isin, pool, amount, "
            "instruction_id, reason, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,'LOCKED',$4,$5,"
            "'DELIVERY_DEBIT',$6,$7,$8,$9)",
            _new_id(), seller_lei, isin, -quantity,
            instruction_id, *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO cash_ledger "
            "(id, entity_id, currency, pool, amount, "
            "instruction_id, reason, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,'LOCKED',$4,$5,"
            "'DELIVERY_DEBIT',$6,$7,$8,$9)",
            _new_id(), buyer_lei, "USD", -amount,
            instruction_id, *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO security_ledger "
            "(id, entity_id, isin, pool, amount, "
            "instruction_id, reason, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,'AVAILABLE',$4,$5,"
            "'DELIVERY_CREDIT',$6,$7,$8,$9)",
            _new_id(), buyer_lei, isin, quantity,
            instruction_id, *ctx.as_sql_args(),
        )
        await db.execute(
            "INSERT INTO cash_ledger "
            "(id, entity_id, currency, pool, amount, "
            "instruction_id, reason, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,'AVAILABLE',$4,$5,"
            "'DELIVERY_CREDIT',$6,$7,$8,$9)",
            _new_id(), seller_lei, "USD", amount,
            instruction_id, *ctx.as_sql_args(),
        )
        # Mark escrows and legs as delivered
        for esc_id in [sec_escrow_id, cash_escrow_id]:
            await db.execute(
                "INSERT INTO escrow_account_events "
                "(id, escrow_id, status, "
                "request_id, trace_id, actor, actor_role) "
                "VALUES ($1,$2,$3,$4,$5,$6,$7)",
                _new_id(), esc_id, "DELIVERED",
                *ctx.as_sql_args(),
            )
        for leg_id in [sec_leg_id, cash_leg_id]:
            await db.execute(
                "INSERT INTO settlement_leg_events "
                "(id, leg_id, status, "
                "request_id, trace_id, actor, actor_role) "
                "VALUES ($1,$2,$3,$4,$5,$6,$7)",
                _new_id(), leg_id, "DELIVERED",
                *ctx.as_sql_args(),
            )
        await _write_outbox(
            db, instruction_id, "dvp.settled",
            {
                "instruction_id": instruction_id,
                "swap_tx_hash": swap_tx,
                "isin": isin,
                "quantity": str(quantity),
                "settlement_amount": str(amount),
            }, ctx,
        )
    logger.info("  Atomic swap executed — tx=%s", swap_tx)

    # Step 8: Confirm SWIFT messages
    logger.info("[8/9] Confirming SWIFT messages...")
    msgs = await db.fetch(
        "SELECT id FROM hybrid_rail_messages "
        "WHERE instruction_id = $1",
        instruction_id,
    )
    for msg in msgs:
        await db.execute(
            "INSERT INTO hybrid_rail_message_events "
            "(id, message_id, status, "
            "request_id, trace_id, actor, actor_role) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7)",
            _new_id(), msg["id"], "CONFIRMED",
            *ctx.as_sql_args(),
        )
    logger.info("  SWIFT messages confirmed")

    # Step 9: Post-settlement reconciliation
    logger.info("[9/9] Running reconciliation...")
    await db.execute(
        "INSERT INTO reconciliation_reports "
        "(id, instruction_id, result, "
        "security_leg_verified, cash_leg_verified, "
        "onchain_supply_matched, "
        "rail_confirmation_matched, "
        "mismatches, reconciled_at, "
        "request_id, trace_id, actor, actor_role) "
        "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,"
        "$10,$11,$12,$13)",
        _new_id(), instruction_id, "MATCHED",
        True, True, True, True,
        json.dumps([]), _now(), *ctx.as_sql_args(),
    )
    await db.execute(
        "INSERT INTO dvp_instruction_events "
        "(id, instruction_id, reconciliation_status, "
        "request_id, trace_id, actor, actor_role) "
        "VALUES ($1,$2,$3,$4,$5,$6,$7)",
        _new_id(), instruction_id, "MATCHED",
        *ctx.as_sql_args(),
    )
    await _write_outbox(
        db, instruction_id,
        "dvp.reconciliation_matched",
        {
            "instruction_id": instruction_id,
            "result": "MATCHED",
        }, ctx,
    )
    logger.info("  Reconciliation: MATCHED")

    # Summary
    logger.info("=" * 60)
    logger.info("DVP SETTLEMENT COMPLETE")
    logger.info("  Instruction: %s", instruction_id)
    logger.info("  Swap TX:     %s", swap_tx)
    logger.info("  Status:      SETTLED")
    logger.info("  Recon:       MATCHED")
    logger.info("=" * 60)

    # Show outbox events
    events = await db.fetch(
        "SELECT event_type, delivery_status "
        "FROM outbox_events_current "
        "WHERE aggregate_id = $1 ORDER BY created_at",
        instruction_id,
    )
    logger.info("Outbox events (%d):", len(events))
    for ev in events:
        logger.info(
            "  %-40s %s",
            ev["event_type"], ev["delivery_status"],
        )


async def main():
    logger.info("=" * 60)
    logger.info(
        "DVP Settlement Service — "
        "Containerized Sandbox Demo"
    )
    logger.info("=" * 60)
    logger.info("DB_HOST=%s DB_NAME=%s DB_USER=%s", DB_HOST, DB_NAME, DB_USER)

    pool = await asyncpg.create_pool(
        _dsn(), min_size=2, max_size=5,
        init=_init_connection,
    )
    db = AsyncpgDB(pool)
    logger.info("Connected to PostgreSQL")

    ctx = AuditContext.system("docker-demo")
    await register_entities(db, ctx)
    await initialize_positions(db, ctx)
    await run_settlement(db, ctx)

    await pool.close()
    logger.info("DVP service completed. Pool closed.")


if __name__ == "__main__":
    asyncio.run(main())
