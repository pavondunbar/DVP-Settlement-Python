"""
╔══════════════════════════════════════════════════════════════════════════════╗
║      Institutional DVP Settlement & Clearing System (Python)               ║
║      Modeled on: JPMorgan Onyx, DTCC Project Ion                           ║
║                                                                            ║
║  ⚠️  SANDBOX / EDUCATIONAL USE ONLY — NOT FOR PRODUCTION                   ║
║  This is a reference implementation for learning and architectural         ║
║  exploration. It is not audited, not legally reviewed, and must not be     ║
║  used to settle real securities, manage investor funds, or interface with  ║
║  real payment rails (SWIFT, FedWire, CLS).                                ║
╚══════════════════════════════════════════════════════════════════════════════╝
 
Architecture Overview
─────────────────────
                         ┌──────────────────────────────────────────────────┐
                         │              DVP SETTLEMENT ENGINE               │
                         └──────────────────────────────────────────────────┘
 
  Counterparty A                                          Counterparty B
  (Seller — Securities)                                   (Buyer — Cash)
       │                                                        │
       ▼                                                        ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │                    DVPSettlementService                             │
  │   1. ComplianceScreening     ──► OFAC / AML / sanctions            │
  │   2. SettlementLegService    ──► Lock security + cash legs          │
  │   3. EscrowService           ──► Fund escrow accounts (both legs)   │
  │   4. MultiSigApprovalService ──► Gather custodian multi-sig votes   │
  │   5. AtomicSwapExecutor      ──► Simultaneous release of both legs  │
  │   6. HybridSettlementGateway ──► SWIFT / FedWire / CLS integration  │
  │   7. DVPReconciliationEngine ──► Cross-system audit & verification  │
  └─────────────────────────────────────────────────────────────────────┘
                         │                      │
                         ▼                      ▼
                    PostgreSQL             Kafka Topics
                    (source of          (downstream consumers:
                     truth)              CSD, CCP, compliance,
                                         risk, dashboards)
"""
 
import asyncio
import asyncpg
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
 
 
# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────
 
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger("dvp_settlement")
 
 
# ─────────────────────────────────────────────────────────────────────────────
# Enumerations — Settlement Domain
# ─────────────────────────────────────────────────────────────────────────────
 
class SettlementStatus(str, Enum):
    """Top-level DVP instruction lifecycle."""
    INITIATED        = "INITIATED"          # Instruction received
    COMPLIANCE_CHECK = "COMPLIANCE_CHECK"   # Screening in progress
    LEGS_LOCKED      = "LEGS_LOCKED"        # Both legs reserved
    ESCROW_FUNDED    = "ESCROW_FUNDED"      # Escrow accounts credited
    MULTISIG_PENDING = "MULTISIG_PENDING"   # Awaiting multi-sig threshold
    MULTISIG_APPROVED= "MULTISIG_APPROVED"  # Quorum reached
    ATOMIC_SWAP      = "ATOMIC_SWAP"        # Swap in flight (irrevocable)
    SETTLED          = "SETTLED"            # T+0 final settlement
    FAILED           = "FAILED"             # Non-recoverable failure
    REVERSED         = "REVERSED"           # Reversed / unwound
 
 
class LegType(str, Enum):
    SECURITY = "SECURITY"   # Tokenized security (ERC-1400 / ERC-3643)
    CASH     = "CASH"       # Tokenized cash / CBDC / stablecoin
 
 
class LegStatus(str, Enum):
    PENDING   = "PENDING"
    LOCKED    = "LOCKED"
    IN_ESCROW = "IN_ESCROW"
    DELIVERED = "DELIVERED"
    RELEASED  = "RELEASED"   # Unwound back to originator
    FAILED    = "FAILED"
 
 
class SettlementRail(str, Enum):
    """Payment/delivery rail for the cash leg."""
    SWIFT    = "SWIFT"      # SWIFT MT103 / MT202 / ISO 20022
    FEDWIRE  = "FEDWIRE"    # US Fedwire Funds Service
    CLS      = "CLS"        # Continuous Linked Settlement (FX)
    ONCHAIN  = "ONCHAIN"    # Tokenized cash / CBDC on DLT
    INTERNAL = "INTERNAL"   # Intra-institution netting
 
 
class SecurityType(str, Enum):
    EQUITY        = "EQUITY"
    CORPORATE_BOND= "CORPORATE_BOND"
    GOV_BOND      = "GOV_BOND"
    MBS           = "MBS"          # Mortgage-Backed Security
    REPO          = "REPO"         # Repo / Reverse-Repo
    TOKENIZED_FUND= "TOKENIZED_FUND"
    DIGITAL_ASSET = "DIGITAL_ASSET"
 
 
class MultiSigVote(str, Enum):
    APPROVE = "APPROVE"
    REJECT  = "REJECT"
    ABSTAIN = "ABSTAIN"
 
 
class HybridRailStatus(str, Enum):
    PENDING    = "PENDING"
    SUBMITTED  = "SUBMITTED"
    CONFIRMED  = "CONFIRMED"
    REJECTED   = "REJECTED"
    TIMED_OUT  = "TIMED_OUT"
 
 
class ReconciliationResult(str, Enum):
    MATCHED   = "MATCHED"
    MISMATCH  = "MISMATCH"
    SUSPENDED = "SUSPENDED"   # Halted pending manual review
 
 
# ─────────────────────────────────────────────────────────────────────────────
# Domain Dataclasses
# ─────────────────────────────────────────────────────────────────────────────
 
@dataclass
class SettlementInstruction:
    """
    Bilateral trade instruction submitted by both counterparties.
    Both sides must match exactly before a DVP instruction is created.
    Mirrors the DTCC / Euroclear matching workflow.
    """
    id: str
    trade_reference: str                # CUSIPxTrade or LEI-based reference
    isin: str                           # International Security Identifier
    security_type: SecurityType
    quantity: Decimal                   # Number of securities / units
    price_per_unit: Decimal             # Agreed settlement price
    settlement_amount: Decimal          # quantity × price_per_unit (cash leg)
    currency: str                       # ISO 4217 (USD, EUR, GBP, JPY)
    seller_entity_id: str               # LEI of selling institution
    buyer_entity_id: str                # LEI of buying institution
    seller_wallet: str                  # On-chain wallet / DLT address
    buyer_wallet: str                   # On-chain wallet / DLT address
    seller_custodian: str               # Custodian / CSD for seller
    buyer_custodian: str                # Custodian / CSD for buyer
    settlement_rail: SettlementRail
    intended_settlement_date: str       # ISO date YYYY-MM-DD (T+0 or T+1)
    status: SettlementStatus = SettlementStatus.INITIATED
    created_at: str = field(default_factory=lambda: _now())
    settled_at: Optional[str] = None
    failure_reason: Optional[str] = None
    idempotency_key: str = field(default_factory=lambda: str(uuid.uuid4()))
 
 
@dataclass
class EscrowAccount:
    """
    Dual escrow accounts created per DVP instruction — one for each leg.
    Neither party can access funds until both legs are confirmed
    and multi-sig quorum is reached.
    """
    id: str
    instruction_id: str
    leg_type: LegType
    holder_entity_id: str
    amount: Decimal                    # Quantity (securities) or notional (cash)
    currency: str
    status: LegStatus = LegStatus.PENDING
    funded_at: Optional[str] = None
    released_at: Optional[str] = None
 
 
@dataclass
class SettlementLeg:
    """
    Individual leg of a DVP instruction (security or cash).
    Both legs must reach IN_ESCROW before atomic swap executes.
    """
    id: str
    instruction_id: str
    leg_type: LegType
    originator_entity_id: str
    beneficiary_entity_id: str
    amount: Decimal
    currency: str                       # ISO 4217 or token ticker
    status: LegStatus = LegStatus.PENDING
    locked_at: Optional[str] = None
    delivered_at: Optional[str] = None
    failure_reason: Optional[str] = None
 
 
@dataclass
class MultiSigApproval:
    """
    Per-custodian approval vote on a DVP instruction.
    Atomic swap is blocked until threshold is met.
    """
    id: str
    instruction_id: str
    custodian_id: str
    signer_id: str                      # HSM signer / authorized signatory
    vote: MultiSigVote
    signature: str                      # Simulated — production: BIP-340 / ECDSA
    voted_at: str = field(default_factory=lambda: _now())
    justification: Optional[str] = None
 
 
@dataclass
class HybridRailMessage:
    """
    Off-chain payment message submitted to SWIFT, FedWire, or CLS.
    Bridges on-chain DVP with traditional settlement infrastructure.
    """
    id: str
    instruction_id: str
    rail: SettlementRail
    message_type: str                   # MT103, MT202COV, MT540-543, Fedwire Tag
    payload: dict
    status: HybridRailStatus = HybridRailStatus.PENDING
    submitted_at: Optional[str] = None
    confirmed_at: Optional[str] = None
    rail_reference: Optional[str] = None   # SWIFT UETR / FedWire IMAD
 
 
@dataclass
class ComplianceDecision:
    is_cleared: bool
    reason: str
    screening_reference: str
    screened_at: str = field(default_factory=lambda: _now())
 
 
@dataclass
class ReconciliationReport:
    id: str
    instruction_id: str
    result: ReconciliationResult
    security_leg_verified: bool
    cash_leg_verified: bool
    onchain_supply_matched: bool
    rail_confirmation_matched: bool
    mismatches: list
    reconciled_at: str = field(default_factory=lambda: _now())
 
 
# ─────────────────────────────────────────────────────────────────────────────
# Custom Exceptions
# ─────────────────────────────────────────────────────────────────────────────
 
class DVPSettlementError(Exception):         pass
class ComplianceRejectionError(DVPSettlementError): pass
class InsufficientSecuritiesError(DVPSettlementError): pass
class InsufficientFundsError(DVPSettlementError): pass
class EscrowFundingError(DVPSettlementError): pass
class MultiSigQuorumNotMet(DVPSettlementError): pass
class AtomicSwapError(DVPSettlementError):   pass
class SettlementRailError(DVPSettlementError): pass
class ReconciliationHalt(DVPSettlementError): pass
class DuplicateInstructionError(DVPSettlementError): pass
 
 
# ─────────────────────────────────────────────────────────────────────────────
# Helper
# ─────────────────────────────────────────────────────────────────────────────
 
def _now() -> str:
    return datetime.now(timezone.utc).isoformat()
 
def _new_id() -> str:
    return str(uuid.uuid4())
 
 
# ─────────────────────────────────────────────────────────────────────────────
# Abstract Infrastructure Interfaces
# ─────────────────────────────────────────────────────────────────────────────
 
class AbstractDB(ABC):
    """
    Wraps asyncpg pool. Production implementation uses connection pooling,
    read replicas for queries, and write primary for mutations.
    """
    @abstractmethod
    async def fetchrow(self, query: str, *args): ...
    @abstractmethod
    async def fetch(self, query: str, *args): ...
    @abstractmethod
    async def execute(self, query: str, *args): ...
    @abstractmethod
    async def transaction(self): ...   # Returns async context manager
 
 
class AbstractComplianceProvider(ABC):
    """
    Production: Accuity / Fircosoft / ComplyAdvantage / OFAC SDN API.
    Screens both counterparties against sanctions lists, PEP lists,
    and internal blacklists. Called OUTSIDE the database transaction
    to avoid holding row locks during slow external I/O.
    """
    @abstractmethod
    async def screen_entity(
        self,
        entity_id: str,
        jurisdiction: str,
        lei: Optional[str] = None,
    ) -> ComplianceDecision: ...
 
 
class AbstractHSMSigningService(ABC):
    """
    Production: AWS CloudHSM / Thales Luna / Fireblocks MPC.
    Signs multi-sig approval transactions. Never holds raw private keys
    in application memory.
    """
    @abstractmethod
    async def sign(self, payload: dict, signer_id: str) -> str: ...
 
 
class AbstractSigningQueue(ABC):
    """
    Production: AWS SQS FIFO (per-instruction MessageGroupId).
    Ensures swap operations are processed strictly in order.
    """
    @abstractmethod
    async def enqueue(self, instruction_id: str, payload: dict) -> str: ...
 
 
class AbstractChainAdapter(ABC):
    """
    On-chain adapter for tokenized securities and cash.
    Production: web3.py / ethers.js via sidecar, or JPMorgan Onyx SDK,
    or Canton / Daml ledger for permissioned chains.
    """
    @abstractmethod
    async def get_balance(self, wallet: str, token_address: str) -> Decimal: ...
 
    @abstractmethod
    async def transfer_to_escrow(
        self, from_wallet: str, escrow_address: str, amount: Decimal,
        token_address: str, instruction_id: str,
    ) -> str: ...   # Returns tx_hash
 
    @abstractmethod
    async def atomic_swap(
        self,
        security_escrow: str, security_beneficiary: str,
        cash_escrow: str, cash_beneficiary: str,
        instruction_id: str,
    ) -> str: ...   # Returns atomic tx_hash
 
 
class AbstractSWIFTGateway(ABC):
    @abstractmethod
    async def send_mt(self, message_type: str, payload: dict) -> str: ...
 
 
class AbstractFedWireGateway(ABC):
    @abstractmethod
    async def submit_fedwire(self, payload: dict) -> str: ...
 
 
class AbstractCLSGateway(ABC):
    @abstractmethod
    async def submit_cls_instruction(self, payload: dict) -> str: ...
 
 
# ─────────────────────────────────────────────────────────────────────────────
# 1. ComplianceScreeningService
# ─────────────────────────────────────────────────────────────────────────────
 
class ComplianceScreeningService:
    """
    Screens both counterparties (seller + buyer) against:
    - OFAC SDN list
    - EU / HM Treasury / UN consolidated sanctions lists
    - Internal restricted entity register
    - PEP (Politically Exposed Persons) lists
 
    Called OUTSIDE any database transaction.  Both legs are screened
    in parallel for performance.  A single hit on either entity blocks
    the entire instruction.
 
    Production integration: ComplyAdvantage, Fircosoft Compliance Link,
    LexisNexis Bridger, or direct OFAC API.
    """
 
    def __init__(self, db: AbstractDB, provider: AbstractComplianceProvider):
        self._db = db
        self._provider = provider
        self._log = logging.getLogger("dvp.compliance")
 
    async def screen_instruction(
        self,
        instruction: SettlementInstruction,
        seller_jurisdiction: str,
        buyer_jurisdiction: str,
    ) -> ComplianceDecision:
        """
        Screens both counterparties concurrently.  Fails fast if either
        is blocked.  Writes decision to compliance_screenings table.
        """
        self._log.info(
            "Screening instruction %s — seller=%s buyer=%s",
            instruction.id, instruction.seller_entity_id, instruction.buyer_entity_id
        )
 
        # --- Run both screens in parallel (outside DB transaction) ---
        seller_task = self._provider.screen_entity(
            instruction.seller_entity_id, seller_jurisdiction
        )
        buyer_task = self._provider.screen_entity(
            instruction.buyer_entity_id, buyer_jurisdiction
        )
        seller_decision, buyer_decision = await asyncio.gather(seller_task, buyer_task)
 
        # --- Aggregate result ---
        if not seller_decision.is_cleared:
            decision = ComplianceDecision(
                is_cleared=False,
                reason=f"Seller {instruction.seller_entity_id} failed screening: {seller_decision.reason}",
                screening_reference=seller_decision.screening_reference,
            )
        elif not buyer_decision.is_cleared:
            decision = ComplianceDecision(
                is_cleared=False,
                reason=f"Buyer {instruction.buyer_entity_id} failed screening: {buyer_decision.reason}",
                screening_reference=buyer_decision.screening_reference,
            )
        else:
            decision = ComplianceDecision(
                is_cleared=True,
                reason="Both counterparties cleared all sanctions and PEP lists",
                screening_reference=f"{seller_decision.screening_reference}|{buyer_decision.screening_reference}",
            )
 
        # --- Persist decision ---
        await self._db.execute(
            """
            INSERT INTO compliance_screenings
              (id, instruction_id, seller_entity_id, buyer_entity_id,
               is_cleared, reason, screening_reference, screened_at)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
            """,
            _new_id(), instruction.id,
            instruction.seller_entity_id, instruction.buyer_entity_id,
            decision.is_cleared, decision.reason,
            decision.screening_reference, decision.screened_at,
        )
 
        self._log.info(
            "Compliance result for %s: cleared=%s", instruction.id, decision.is_cleared
        )
        return decision
 
 
# ─────────────────────────────────────────────────────────────────────────────
# 2. SettlementLegService
# ─────────────────────────────────────────────────────────────────────────────
 
class SettlementLegService:
    """
    Creates and manages the two legs of a DVP instruction.
 
    Security Leg:  Seller's securities locked against delivery.
    Cash Leg:      Buyer's cash locked against payment.
 
    Both legs must reach IN_ESCROW before the atomic swap can proceed.
    Pessimistic locking (SELECT … FOR UPDATE) prevents double-reservations
    on custody accounts that share ledger rows.
 
    Mirrors DTCC Project Ion leg-matching and DTC position locking.
    """
 
    def __init__(self, db: AbstractDB, chain: AbstractChainAdapter):
        self._db = db
        self._chain = chain
        self._log = logging.getLogger("dvp.legs")
 
    async def create_and_lock_legs(
        self, instruction: SettlementInstruction
    ) -> tuple[SettlementLeg, SettlementLeg]:
        """
        Atomically creates both legs and locks the underlying positions.
        Uses a single DB transaction — either both succeed or neither does.
        """
        security_leg_id = _new_id()
        cash_leg_id     = _new_id()
 
        async with self._db.transaction():
            # ── Lock seller custody account (prevent concurrent withdrawals) ──
            seller_pos = await self._db.fetchrow(
                """
                SELECT id, available_quantity
                FROM custody_positions
                WHERE entity_id = $1 AND isin = $2
                FOR UPDATE
                """,
                instruction.seller_entity_id, instruction.isin,
            )
            if not seller_pos or Decimal(seller_pos["available_quantity"]) < instruction.quantity:
                raise InsufficientSecuritiesError(
                    f"Seller {instruction.seller_entity_id} has insufficient "
                    f"{instruction.isin} — required {instruction.quantity}, "
                    f"available {seller_pos['available_quantity'] if seller_pos else 0}"
                )
 
            # ── Lock buyer cash account ──
            buyer_cash = await self._db.fetchrow(
                """
                SELECT id, available_balance
                FROM cash_accounts
                WHERE entity_id = $1 AND currency = $2
                FOR UPDATE
                """,
                instruction.buyer_entity_id, instruction.currency,
            )
            if not buyer_cash or Decimal(buyer_cash["available_balance"]) < instruction.settlement_amount:
                raise InsufficientFundsError(
                    f"Buyer {instruction.buyer_entity_id} has insufficient "
                    f"{instruction.currency} — required {instruction.settlement_amount}, "
                    f"available {buyer_cash['available_balance'] if buyer_cash else 0}"
                )
 
            now = _now()
 
            # ── Reserve security position ──
            await self._db.execute(
                """
                UPDATE custody_positions
                SET available_quantity  = available_quantity  - $1,
                    locked_quantity     = locked_quantity     + $1,
                    updated_at          = $2
                WHERE id = $3
                """,
                instruction.quantity, now, seller_pos["id"],
            )
 
            # ── Reserve cash balance ──
            await self._db.execute(
                """
                UPDATE cash_accounts
                SET available_balance  = available_balance  - $1,
                    locked_balance     = locked_balance     + $1,
                    updated_at         = $2
                WHERE id = $3
                """,
                instruction.settlement_amount, now, buyer_cash["id"],
            )
 
            # ── Insert security leg ──
            await self._db.execute(
                """
                INSERT INTO settlement_legs
                  (id, instruction_id, leg_type, originator_entity_id,
                   beneficiary_entity_id, amount, currency, status, locked_at)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
                """,
                security_leg_id, instruction.id, LegType.SECURITY,
                instruction.seller_entity_id, instruction.buyer_entity_id,
                instruction.quantity, instruction.isin,
                LegStatus.LOCKED, now,
            )
 
            # ── Insert cash leg ──
            await self._db.execute(
                """
                INSERT INTO settlement_legs
                  (id, instruction_id, leg_type, originator_entity_id,
                   beneficiary_entity_id, amount, currency, status, locked_at)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
                """,
                cash_leg_id, instruction.id, LegType.CASH,
                instruction.buyer_entity_id, instruction.seller_entity_id,
                instruction.settlement_amount, instruction.currency,
                LegStatus.LOCKED, now,
            )
 
            # ── Update instruction status ──
            await self._db.execute(
                "UPDATE dvp_instructions SET status = $1, updated_at = $2 WHERE id = $3",
                SettlementStatus.LEGS_LOCKED, now, instruction.id,
            )
 
            # ── Outbox event (same transaction) ──
            await self._write_outbox_event(
                instruction.id, "dvp.legs_locked",
                {
                    "instruction_id": instruction.id,
                    "security_leg_id": security_leg_id,
                    "cash_leg_id": cash_leg_id,
                    "isin": instruction.isin,
                    "quantity": str(instruction.quantity),
                    "settlement_amount": str(instruction.settlement_amount),
                    "currency": instruction.currency,
                }
            )
 
        security_leg = SettlementLeg(
            id=security_leg_id,
            instruction_id=instruction.id,
            leg_type=LegType.SECURITY,
            originator_entity_id=instruction.seller_entity_id,
            beneficiary_entity_id=instruction.buyer_entity_id,
            amount=instruction.quantity,
            currency=instruction.isin,
            status=LegStatus.LOCKED,
            locked_at=now,
        )
        cash_leg = SettlementLeg(
            id=cash_leg_id,
            instruction_id=instruction.id,
            leg_type=LegType.CASH,
            originator_entity_id=instruction.buyer_entity_id,
            beneficiary_entity_id=instruction.seller_entity_id,
            amount=instruction.settlement_amount,
            currency=instruction.currency,
            status=LegStatus.LOCKED,
            locked_at=now,
        )
 
        self._log.info(
            "Legs locked for instruction %s — sec_leg=%s cash_leg=%s",
            instruction.id, security_leg_id, cash_leg_id
        )
        return security_leg, cash_leg
 
    async def _write_outbox_event(self, instruction_id: str, event_type: str, payload: dict):
        await self._db.execute(
            """
            INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at)
            VALUES ($1, $2, $3, $4, $5)
            """,
            _new_id(), instruction_id, event_type,
            json.dumps(payload), _now(),
        )
 
 
# ─────────────────────────────────────────────────────────────────────────────
# 3. EscrowService
# ─────────────────────────────────────────────────────────────────────────────
 
class EscrowService:
    """
    Manages dual escrow accounts for each DVP instruction.
 
    Security Escrow:  Tokenized securities transferred from seller's wallet
                      to a smart-contract escrow address.
    Cash Escrow:      Tokenized cash / CBDC transferred from buyer's wallet
                      to a separate smart-contract escrow address.
 
    Neither leg can be released independently.  Release requires either:
    (a) atomic swap execution (settlement path), or
    (b) multi-sig reversal after expiry / failure (unwind path).
 
    Mirrors JPMorgan Onyx's repo / swap escrow model and
    DTCC Project Ion's DLT-based escrow mechanism.
    """
 
    def __init__(self, db: AbstractDB, chain: AbstractChainAdapter):
        self._db    = db
        self._chain = chain
        self._log   = logging.getLogger("dvp.escrow")
 
    async def fund_escrow_accounts(
        self,
        instruction: SettlementInstruction,
        security_escrow_address: str,
        cash_escrow_address: str,
        security_token_address: str,
        cash_token_address: str,
    ) -> tuple[EscrowAccount, EscrowAccount]:
        """
        Initiates on-chain transfers into escrow smart contracts.
        The DB record is written AFTER the chain confirms to ensure
        the ledger reflects on-chain reality.
        """
        now = _now()
        sec_escrow_id  = _new_id()
        cash_escrow_id = _new_id()
 
        # ── Step 1: On-chain transfers (outside DB tx — can be slow) ──
        self._log.info("Initiating on-chain escrow funding for %s", instruction.id)
 
        sec_tx_hash = await self._chain.transfer_to_escrow(
            from_wallet=instruction.seller_wallet,
            escrow_address=security_escrow_address,
            amount=instruction.quantity,
            token_address=security_token_address,
            instruction_id=instruction.id,
        )
 
        cash_tx_hash = await self._chain.transfer_to_escrow(
            from_wallet=instruction.buyer_wallet,
            escrow_address=cash_escrow_address,
            amount=instruction.settlement_amount,
            token_address=cash_token_address,
            instruction_id=instruction.id,
        )
 
        # ── Step 2: Persist escrow records + update instruction status ──
        async with self._db.transaction():
            funded_at = _now()
 
            await self._db.execute(
                """
                INSERT INTO escrow_accounts
                  (id, instruction_id, leg_type, holder_entity_id, amount,
                   currency, status, escrow_address, on_chain_tx_hash, funded_at)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
                """,
                sec_escrow_id, instruction.id, LegType.SECURITY,
                instruction.seller_entity_id, instruction.quantity,
                instruction.isin, LegStatus.IN_ESCROW,
                security_escrow_address, sec_tx_hash, funded_at,
            )
 
            await self._db.execute(
                """
                INSERT INTO escrow_accounts
                  (id, instruction_id, leg_type, holder_entity_id, amount,
                   currency, status, escrow_address, on_chain_tx_hash, funded_at)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
                """,
                cash_escrow_id, instruction.id, LegType.CASH,
                instruction.buyer_entity_id, instruction.settlement_amount,
                instruction.currency, LegStatus.IN_ESCROW,
                cash_escrow_address, cash_tx_hash, funded_at,
            )
 
            await self._db.execute(
                "UPDATE dvp_instructions SET status = $1, updated_at = $2 WHERE id = $3",
                SettlementStatus.ESCROW_FUNDED, funded_at, instruction.id,
            )
 
            await self._db.execute(
                """
                UPDATE settlement_legs
                SET status = $1, updated_at = $2
                WHERE instruction_id = $3
                """,
                LegStatus.IN_ESCROW, funded_at, instruction.id,
            )
 
            await self._write_outbox_event(
                instruction.id, "dvp.escrow_funded",
                {
                    "instruction_id": instruction.id,
                    "security_escrow_id": sec_escrow_id,
                    "cash_escrow_id": cash_escrow_id,
                    "security_tx_hash": sec_tx_hash,
                    "cash_tx_hash": cash_tx_hash,
                    "funded_at": funded_at,
                }
            )
 
        sec_escrow = EscrowAccount(
            id=sec_escrow_id, instruction_id=instruction.id,
            leg_type=LegType.SECURITY, holder_entity_id=instruction.seller_entity_id,
            amount=instruction.quantity, currency=instruction.isin,
            status=LegStatus.IN_ESCROW, funded_at=funded_at,
        )
        cash_escrow = EscrowAccount(
            id=cash_escrow_id, instruction_id=instruction.id,
            leg_type=LegType.CASH, holder_entity_id=instruction.buyer_entity_id,
            amount=instruction.settlement_amount, currency=instruction.currency,
            status=LegStatus.IN_ESCROW, funded_at=funded_at,
        )
 
        self._log.info("Escrow funded for %s — sec_tx=%s cash_tx=%s",
                       instruction.id, sec_tx_hash, cash_tx_hash)
        return sec_escrow, cash_escrow
 
    async def release_to_originator(self, instruction_id: str, reason: str):
        """
        Unwind path: Release both escrow accounts back to originators.
        Called on failure or expiry.  Requires multi-sig approval
        (handled by MultiSigApprovalService before this is called).
        """
        now = _now()
        async with self._db.transaction():
            await self._db.execute(
                """
                UPDATE escrow_accounts
                SET status = $1, released_at = $2
                WHERE instruction_id = $3
                """,
                LegStatus.RELEASED, now, instruction_id,
            )
            await self._db.execute(
                "UPDATE dvp_instructions SET status = $1, failure_reason = $2, updated_at = $3 WHERE id = $4",
                SettlementStatus.REVERSED, reason, now, instruction_id,
            )
            await self._write_outbox_event(
                instruction_id, "dvp.escrow_released",
                {"instruction_id": instruction_id, "reason": reason, "released_at": now}
            )
        self._log.warning("Escrow released for %s — reason: %s", instruction_id, reason)
 
    async def _write_outbox_event(self, instruction_id: str, event_type: str, payload: dict):
        await self._db.execute(
            "INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at) VALUES ($1,$2,$3,$4,$5)",
            _new_id(), instruction_id, event_type, json.dumps(payload), _now(),
        )
 
 
# ─────────────────────────────────────────────────────────────────────────────
# 4. MultiSigApprovalService
# ─────────────────────────────────────────────────────────────────────────────
 
class MultiSigApprovalService:
    """
    Manages multi-sig approval quorum for DVP atomic swap finality.
 
    Required signers:
    - Seller's custodian (CSD / prime broker)
    - Buyer's custodian (CSD / prime broker)
    - Central counterparty (CCP) — optional for bilateral DVP
 
    In production this maps to:
    - Hardware Security Module (HSM) signatures via Thales / AWS CloudHSM
    - Fireblocks MPC threshold signatures
    - Smart contract multi-sig (Safe / Gnosis) on permissioned chain
 
    Default quorum: 2-of-3 (both custodians required; CCP optional).
    All votes are recorded on-chain and in Postgres for audit purposes.
 
    Mirrors DTCC's two-sided affirmation model and CLS's bilateral
    payment netting confirmation.
    """
 
    REQUIRED_QUORUM: int = 2    # Minimum approvals to proceed
 
    def __init__(
        self,
        db: AbstractDB,
        hsm: AbstractHSMSigningService,
        required_custodians: list[str],
    ):
        self._db = db
        self._hsm = hsm
        self._required_custodians = required_custodians
        self._log = logging.getLogger("dvp.multisig")
 
    async def cast_vote(
        self,
        instruction_id: str,
        custodian_id: str,
        signer_id: str,
        vote: MultiSigVote,
        justification: Optional[str] = None,
    ) -> MultiSigApproval:
        """
        Records an approval/rejection vote from a custodian signer.
        Signature is generated by the HSM service outside the DB transaction.
        """
        if custodian_id not in self._required_custodians:
            raise DVPSettlementError(
                f"Custodian {custodian_id} is not a required signer for this instruction."
            )
 
        # ── Generate HSM signature OUTSIDE DB transaction ──
        sig_payload = {
            "instruction_id": instruction_id,
            "custodian_id": custodian_id,
            "signer_id": signer_id,
            "vote": vote,
            "timestamp": _now(),
        }
        signature = await self._hsm.sign(sig_payload, signer_id)
 
        approval_id = _new_id()
        now         = _now()
 
        async with self._db.transaction():
            # Check if this custodian already voted (prevent double-voting)
            existing = await self._db.fetchrow(
                "SELECT id FROM multisig_approvals WHERE instruction_id = $1 AND custodian_id = $2",
                instruction_id, custodian_id,
            )
            if existing:
                raise DVPSettlementError(
                    f"Custodian {custodian_id} has already voted on instruction {instruction_id}."
                )
 
            await self._db.execute(
                """
                INSERT INTO multisig_approvals
                  (id, instruction_id, custodian_id, signer_id, vote,
                   signature, voted_at, justification)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
                """,
                approval_id, instruction_id, custodian_id, signer_id,
                vote, signature, now, justification,
            )
 
            await self._write_outbox_event(
                instruction_id, "dvp.multisig_vote",
                {
                    "instruction_id": instruction_id,
                    "approval_id": approval_id,
                    "custodian_id": custodian_id,
                    "vote": vote,
                    "voted_at": now,
                }
            )
 
        approval = MultiSigApproval(
            id=approval_id, instruction_id=instruction_id,
            custodian_id=custodian_id, signer_id=signer_id,
            vote=vote, signature=signature, voted_at=now, justification=justification,
        )
        self._log.info(
            "Vote cast: instruction=%s custodian=%s vote=%s",
            instruction_id, custodian_id, vote
        )
        return approval
 
    async def check_quorum(self, instruction_id: str) -> bool:
        """
        Returns True if minimum quorum of APPROVE votes has been reached
        and no REJECT votes have been cast.
        """
        votes = await self._db.fetch(
            "SELECT vote FROM multisig_approvals WHERE instruction_id = $1",
            instruction_id,
        )
        approve_count = sum(1 for v in votes if v["vote"] == MultiSigVote.APPROVE)
        reject_count  = sum(1 for v in votes if v["vote"] == MultiSigVote.REJECT)
 
        if reject_count > 0:
            return False
        return approve_count >= self.REQUIRED_QUORUM
 
    async def finalize_quorum(self, instruction_id: str):
        """
        Marks the instruction as MULTISIG_APPROVED in a single atomic write.
        Called by DVPSettlementService once check_quorum() returns True.
        """
        now = _now()
        async with self._db.transaction():
            await self._db.execute(
                "UPDATE dvp_instructions SET status = $1, updated_at = $2 WHERE id = $3",
                SettlementStatus.MULTISIG_APPROVED, now, instruction_id,
            )
            await self._write_outbox_event(
                instruction_id, "dvp.multisig_approved",
                {"instruction_id": instruction_id, "approved_at": now}
            )
        self._log.info("Multi-sig quorum reached for instruction %s", instruction_id)
 
    async def _write_outbox_event(self, instruction_id: str, event_type: str, payload: dict):
        await self._db.execute(
            "INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at) VALUES ($1,$2,$3,$4,$5)",
            _new_id(), instruction_id, event_type, json.dumps(payload), _now(),
        )
 
 
# ─────────────────────────────────────────────────────────────────────────────
# 5. AtomicSwapExecutor
# ─────────────────────────────────────────────────────────────────────────────
 
class AtomicSwapExecutor:
    """
    Executes the simultaneous, irrevocable atomic swap of both escrow legs.
 
    This is the core DVP mechanism:
    - Security escrow → released to buyer's wallet
    - Cash escrow     → released to seller's wallet
    Both transfers execute in a single on-chain transaction (or via
    hash-time-lock contracts on permissioned chains).
 
    If the on-chain atomic swap fails (chain reorg, gas exhaustion,
    smart contract revert), the system immediately transitions to FAILED
    and triggers the reversal path — the escrow smart contract guarantees
    neither party can be left holding only one leg.
 
    Mirrors DTCC Project Ion's DLT atomic delivery mechanism and
    JPMorgan Onyx's intraday repo atomic swap architecture.
    """
 
    def __init__(self, db: AbstractDB, chain: AbstractChainAdapter, signing_queue: AbstractSigningQueue):
        self._db    = db
        self._chain = chain
        self._queue = signing_queue
        self._log   = logging.getLogger("dvp.atomic_swap")
 
    async def execute(
        self,
        instruction: SettlementInstruction,
        security_escrow_address: str,
        cash_escrow_address: str,
    ) -> str:
        """
        Returns the atomic swap transaction hash on success.
        Raises AtomicSwapError on failure.
        """
        self._log.info(
            "Initiating atomic swap for instruction %s — IRREVOCABLE",
            instruction.id
        )
        now = _now()
 
        # ── Mark as in-flight BEFORE chain call (enables crash recovery) ──
        async with self._db.transaction():
            await self._db.execute(
                "UPDATE dvp_instructions SET status = $1, updated_at = $2 WHERE id = $3",
                SettlementStatus.ATOMIC_SWAP, now, instruction.id,
            )
            await self._write_outbox_event(
                instruction.id, "dvp.atomic_swap_initiated",
                {
                    "instruction_id": instruction.id,
                    "security_escrow": security_escrow_address,
                    "cash_escrow": cash_escrow_address,
                    "initiated_at": now,
                }
            )
 
        # ── Execute on-chain atomic swap (outside DB transaction) ──
        try:
            swap_tx_hash = await self._chain.atomic_swap(
                security_escrow=security_escrow_address,
                security_beneficiary=instruction.buyer_wallet,
                cash_escrow=cash_escrow_address,
                cash_beneficiary=instruction.seller_wallet,
                instruction_id=instruction.id,
            )
        except Exception as exc:
            await self._handle_swap_failure(instruction.id, str(exc))
            raise AtomicSwapError(
                f"Atomic swap failed for instruction {instruction.id}: {exc}"
            ) from exc
 
        # ── Settlement finality — update all records atomically ──
        settled_at = _now()
        async with self._db.transaction():
            await self._db.execute(
                """
                UPDATE dvp_instructions
                SET status = $1, swap_tx_hash = $2, settled_at = $3, updated_at = $3
                WHERE id = $4
                """,
                SettlementStatus.SETTLED, swap_tx_hash, settled_at, instruction.id,
            )
 
            # Release locks — deduct from originator balances
            await self._db.execute(
                """
                UPDATE custody_positions
                SET locked_quantity = locked_quantity - $1,
                    updated_at      = $2
                WHERE entity_id = $3 AND isin = $4
                """,
                instruction.quantity, settled_at,
                instruction.seller_entity_id, instruction.isin,
            )
            await self._db.execute(
                """
                UPDATE cash_accounts
                SET balance         = balance         - $1,
                    locked_balance  = locked_balance  - $1,
                    updated_at      = $2
                WHERE entity_id = $3 AND currency = $4
                """,
                instruction.settlement_amount, settled_at,
                instruction.buyer_entity_id, instruction.currency,
            )
 
            # Credit beneficiary accounts
            await self._db.execute(
                """
                INSERT INTO custody_positions (id, entity_id, isin, available_quantity, locked_quantity, updated_at)
                VALUES ($1, $2, $3, $4, 0, $5)
                ON CONFLICT (entity_id, isin)
                DO UPDATE SET available_quantity = custody_positions.available_quantity + $4,
                              updated_at = $5
                """,
                _new_id(), instruction.buyer_entity_id, instruction.isin,
                instruction.quantity, settled_at,
            )
            await self._db.execute(
                """
                INSERT INTO cash_accounts (id, entity_id, currency, balance, available_balance, locked_balance, updated_at)
                VALUES ($1, $2, $3, $4, $4, 0, $5)
                ON CONFLICT (entity_id, currency)
                DO UPDATE SET balance           = cash_accounts.balance           + $4,
                              available_balance = cash_accounts.available_balance + $4,
                              updated_at        = $5
                """,
                _new_id(), instruction.seller_entity_id, instruction.currency,
                instruction.settlement_amount, settled_at,
            )
 
            # Mark escrow accounts as delivered
            await self._db.execute(
                "UPDATE escrow_accounts SET status = $1, released_at = $2 WHERE instruction_id = $3",
                LegStatus.DELIVERED, settled_at, instruction.id,
            )
 
            # Mark settlement legs as delivered
            await self._db.execute(
                "UPDATE settlement_legs SET status = $1, delivered_at = $2 WHERE instruction_id = $3",
                LegStatus.DELIVERED, settled_at, instruction.id,
            )
 
            await self._write_outbox_event(
                instruction.id, "dvp.settled",
                {
                    "instruction_id": instruction.id,
                    "swap_tx_hash": swap_tx_hash,
                    "seller_entity_id": instruction.seller_entity_id,
                    "buyer_entity_id": instruction.buyer_entity_id,
                    "isin": instruction.isin,
                    "quantity": str(instruction.quantity),
                    "settlement_amount": str(instruction.settlement_amount),
                    "currency": instruction.currency,
                    "settled_at": settled_at,
                }
            )
 
        self._log.info(
            "DVP SETTLED — instruction=%s tx=%s at=%s",
            instruction.id, swap_tx_hash, settled_at
        )
        return swap_tx_hash
 
    async def _handle_swap_failure(self, instruction_id: str, reason: str):
        now = _now()
        async with self._db.transaction():
            await self._db.execute(
                "UPDATE dvp_instructions SET status = $1, failure_reason = $2, updated_at = $3 WHERE id = $4",
                SettlementStatus.FAILED, reason, now, instruction_id,
            )
            await self._write_outbox_event(
                instruction_id, "dvp.swap_failed",
                {"instruction_id": instruction_id, "reason": reason, "failed_at": now}
            )
        self._log.error("Atomic swap FAILED for instruction %s: %s", instruction_id, reason)
 
    async def _write_outbox_event(self, instruction_id: str, event_type: str, payload: dict):
        await self._db.execute(
            "INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at) VALUES ($1,$2,$3,$4,$5)",
            _new_id(), instruction_id, event_type, json.dumps(payload), _now(),
        )
 
 
# ─────────────────────────────────────────────────────────────────────────────
# 6. HybridSettlementGateway (SWIFT / FedWire / CLS)
# ─────────────────────────────────────────────────────────────────────────────
 
class HybridSettlementGateway:
    """
    Bridges on-chain DVP settlement with traditional payment rails.
 
    The hybrid model is mandatory for institutional DVP because:
    1. Cash legs often involve regulated bank money, not tokenized cash.
    2. Cross-border FX settlement requires CLS participation.
    3. Legacy custodian systems require SWIFT MT messaging for affirmations.
 
    SWIFT integration:
    - MT540 / MT541: Free of Payment instruction (securities leg only)
    - MT542 / MT543: Delivery vs Payment instruction
    - MT103:         Single customer credit transfer (cash leg)
    - MT202 COV:     Financial institution transfer (bank-to-bank cash)
    - ISO 20022 pacs.008 / sese.023 (next-gen equivalent)
 
    FedWire integration:
    - Tag 3600 (Business Function Code): CTR (Customer Transfer) / BTC
    - Fedwire Funds Service for USD same-day gross settlement
 
    CLS integration:
    - For FX-linked DVPs (e.g., USD/EUR bond settlement)
    - CLS submits both pay and receive legs to avoid Herstatt risk
 
    All messages are persisted in hybrid_rail_messages for audit.
    Rail confirmation is reconciled against on-chain settlement.
    """
 
    def __init__(
        self,
        db: AbstractDB,
        swift: AbstractSWIFTGateway,
        fedwire: AbstractFedWireGateway,
        cls: AbstractCLSGateway,
    ):
        self._db      = db
        self._swift   = swift
        self._fedwire = fedwire
        self._cls     = cls
        self._log     = logging.getLogger("dvp.hybrid_rail")
 
    async def submit_settlement_messages(
        self, instruction: SettlementInstruction
    ) -> list[HybridRailMessage]:
        """
        Submits the appropriate payment messages based on the instruction's
        settlement rail.  Returns all submitted messages.
        """
        messages = []
 
        if instruction.settlement_rail == SettlementRail.SWIFT:
            messages += await self._submit_swift(instruction)
        elif instruction.settlement_rail == SettlementRail.FEDWIRE:
            messages += await self._submit_fedwire(instruction)
        elif instruction.settlement_rail == SettlementRail.CLS:
            messages += await self._submit_cls(instruction)
        elif instruction.settlement_rail == SettlementRail.ONCHAIN:
            self._log.info("Instruction %s is fully on-chain — no hybrid rail needed", instruction.id)
        elif instruction.settlement_rail == SettlementRail.INTERNAL:
            self._log.info("Instruction %s settled via internal netting", instruction.id)
 
        return messages
 
    # ── SWIFT ────────────────────────────────────────────────────────────────
 
    async def _submit_swift(self, instruction: SettlementInstruction) -> list[HybridRailMessage]:
        messages = []
 
        # MT543: Deliver Against Payment — seller side
        mt543_payload = {
            "message_type": "MT543",
            "uetr": str(uuid.uuid4()),
            "sender_bic": instruction.seller_custodian,
            "receiver_bic": instruction.buyer_custodian,
            "isin": instruction.isin,
            "quantity": str(instruction.quantity),
            "settlement_amount": str(instruction.settlement_amount),
            "currency": instruction.currency,
            "settlement_date": instruction.intended_settlement_date,
            "trade_reference": instruction.trade_reference,
            "seller_account": instruction.seller_wallet,
            "buyer_account": instruction.buyer_wallet,
        }
        uetr = await self._swift.send_mt("MT543", mt543_payload)
        msg = await self._persist_rail_message(
            instruction.id, SettlementRail.SWIFT, "MT543", mt543_payload, uetr
        )
        messages.append(msg)
 
        # MT103: Cash leg credit transfer (buyer → seller)
        mt103_payload = {
            "message_type": "MT103",
            "uetr": str(uuid.uuid4()),
            "sender_bic": instruction.buyer_custodian,
            "receiver_bic": instruction.seller_custodian,
            "amount": str(instruction.settlement_amount),
            "currency": instruction.currency,
            "value_date": instruction.intended_settlement_date,
            "remittance_info": f"DVP/{instruction.trade_reference}/{instruction.isin}",
        }
        uetr_cash = await self._swift.send_mt("MT103", mt103_payload)
        msg_cash = await self._persist_rail_message(
            instruction.id, SettlementRail.SWIFT, "MT103", mt103_payload, uetr_cash
        )
        messages.append(msg_cash)
 
        self._log.info(
            "SWIFT messages submitted for %s: MT543 uetr=%s MT103 uetr=%s",
            instruction.id, uetr, uetr_cash
        )
        return messages
 
    # ── FedWire ──────────────────────────────────────────────────────────────
 
    async def _submit_fedwire(self, instruction: SettlementInstruction) -> list[HybridRailMessage]:
        fedwire_payload = {
            "business_function_code": "CTR",
            "amount": str(instruction.settlement_amount),
            "sender_aba": instruction.buyer_custodian,
            "receiver_aba": instruction.seller_custodian,
            "omad": str(uuid.uuid4()).replace("-", "")[:16].upper(),
            "originator_to_beneficiary_info": f"DVP SETTLEMENT {instruction.trade_reference}",
            "value_date": instruction.intended_settlement_date,
        }
        imad = await self._fedwire.submit_fedwire(fedwire_payload)
        msg = await self._persist_rail_message(
            instruction.id, SettlementRail.FEDWIRE, "FEDWIRE_CTR", fedwire_payload, imad
        )
        self._log.info("FedWire submitted for %s — IMAD=%s", instruction.id, imad)
        return [msg]
 
    # ── CLS ──────────────────────────────────────────────────────────────────
 
    async def _submit_cls(self, instruction: SettlementInstruction) -> list[HybridRailMessage]:
        """
        CLS (Continuous Linked Settlement) eliminates FX settlement risk
        by settling both legs of an FX transaction simultaneously.
        Used for cross-currency DVP (e.g., USD bond vs. EUR cash).
        """
        cls_payload = {
            "cls_instruction_type": "DVP_MATCHED",
            "settlement_date": instruction.intended_settlement_date,
            "buy_currency": instruction.currency,
            "buy_amount": str(instruction.settlement_amount),
            "sell_currency": "USD",   # Simplified — production uses actual FX pair
            "member_bic_buyer": instruction.buyer_custodian,
            "member_bic_seller": instruction.seller_custodian,
            "trade_reference": instruction.trade_reference,
        }
        cls_ref = await self._cls.submit_cls_instruction(cls_payload)
        msg = await self._persist_rail_message(
            instruction.id, SettlementRail.CLS, "CLS_DVP_MATCHED", cls_payload, cls_ref
        )
        self._log.info("CLS instruction submitted for %s — ref=%s", instruction.id, cls_ref)
        return [msg]
 
    async def _persist_rail_message(
        self,
        instruction_id: str,
        rail: SettlementRail,
        message_type: str,
        payload: dict,
        rail_reference: str,
    ) -> HybridRailMessage:
        msg_id    = _new_id()
        submitted = _now()
        await self._db.execute(
            """
            INSERT INTO hybrid_rail_messages
              (id, instruction_id, rail, message_type, payload,
               status, submitted_at, rail_reference)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
            """,
            msg_id, instruction_id, rail, message_type,
            json.dumps(payload), HybridRailStatus.SUBMITTED,
            submitted, rail_reference,
        )
        return HybridRailMessage(
            id=msg_id, instruction_id=instruction_id, rail=rail,
            message_type=message_type, payload=payload,
            status=HybridRailStatus.SUBMITTED, submitted_at=submitted,
            rail_reference=rail_reference,
        )
 
    async def confirm_rail_message(self, rail_reference: str, confirmed_at: Optional[str] = None):
        """Called by external webhook / polling when the payment rail confirms delivery."""
        now = confirmed_at or _now()
        await self._db.execute(
            """
            UPDATE hybrid_rail_messages
            SET status = $1, confirmed_at = $2
            WHERE rail_reference = $3
            """,
            HybridRailStatus.CONFIRMED, now, rail_reference,
        )
        self._log.info("Rail message confirmed — ref=%s at=%s", rail_reference, now)
 
 
# ─────────────────────────────────────────────────────────────────────────────
# 7. DVPReconciliationEngine
# ─────────────────────────────────────────────────────────────────────────────
 
class DVPReconciliationEngine:
    """
    Post-settlement reconciliation against all four sources of truth:
 
    1. Internal Postgres ledger (custody positions, cash accounts)
    2. On-chain token balances (via chain adapter)
    3. Payment rail confirmations (SWIFT ACK / FedWire IMAD / CLS confirm)
    4. Custodian statements (simulated — production: FTP file or API)
 
    Any mismatch is treated as a CRITICAL discrepancy.
    All future settlements for affected instructions are halted immediately.
 
    Runs:
    - Per instruction: immediately post-settlement
    - Batch daily: full portfolio reconciliation at CSD/CCP level
    - On-demand: triggered by compliance / ops request
 
    Mirrors DTCC's end-of-day settlement reconciliation and
    JPMorgan Onyx's real-time position verification.
    """
 
    def __init__(self, db: AbstractDB, chain: AbstractChainAdapter):
        self._db    = db
        self._chain = chain
        self._log   = logging.getLogger("dvp.reconciliation")
 
    async def reconcile_instruction(
        self,
        instruction: SettlementInstruction,
        security_token_address: str,
        cash_token_address: str,
    ) -> ReconciliationReport:
        """
        Full 4-source reconciliation for a single settled instruction.
        """
        mismatches = []
        report_id  = _new_id()
 
        # ── 1. On-chain balance check ──
        buyer_sec_bal = await self._chain.get_balance(
            instruction.buyer_wallet, security_token_address
        )
        seller_cash_bal = await self._chain.get_balance(
            instruction.seller_wallet, cash_token_address
        )
 
        buyer_ledger = await self._db.fetchrow(
            "SELECT available_quantity FROM custody_positions WHERE entity_id = $1 AND isin = $2",
            instruction.buyer_entity_id, instruction.isin,
        )
        seller_ledger = await self._db.fetchrow(
            "SELECT available_balance FROM cash_accounts WHERE entity_id = $1 AND currency = $2",
            instruction.seller_entity_id, instruction.currency,
        )
 
        sec_matched  = True
        cash_matched = True
 
        if buyer_ledger and abs(buyer_sec_bal - Decimal(buyer_ledger["available_quantity"])) > Decimal("0.000001"):
            mismatches.append({
                "type": "SECURITY_BALANCE_MISMATCH",
                "entity": instruction.buyer_entity_id,
                "onchain": str(buyer_sec_bal),
                "ledger": str(buyer_ledger["available_quantity"]),
            })
            sec_matched = False
 
        if seller_ledger and abs(seller_cash_bal - Decimal(seller_ledger["available_balance"])) > Decimal("0.01"):
            mismatches.append({
                "type": "CASH_BALANCE_MISMATCH",
                "entity": instruction.seller_entity_id,
                "onchain": str(seller_cash_bal),
                "ledger": str(seller_ledger["available_balance"]),
            })
            cash_matched = False
 
        # ── 2. Rail confirmation check ──
        unconfirmed_rails = await self._db.fetch(
            """
            SELECT id, rail, message_type FROM hybrid_rail_messages
            WHERE instruction_id = $1 AND status != $2
            """,
            instruction.id, HybridRailStatus.CONFIRMED,
        )
        rail_matched = len(unconfirmed_rails) == 0
        if not rail_matched:
            for msg in unconfirmed_rails:
                mismatches.append({
                    "type": "RAIL_UNCONFIRMED",
                    "message_id": msg["id"],
                    "rail": msg["rail"],
                    "message_type": msg["message_type"],
                })
 
        # ── 3. Escrow account closure check ──
        open_escrows = await self._db.fetch(
            "SELECT id, leg_type FROM escrow_accounts WHERE instruction_id = $1 AND status NOT IN ($2,$3)",
            instruction.id, LegStatus.DELIVERED, LegStatus.RELEASED,
        )
        onchain_matched = len(open_escrows) == 0
        if not onchain_matched:
            for esc in open_escrows:
                mismatches.append({
                    "type": "ESCROW_NOT_CLOSED",
                    "escrow_id": esc["id"],
                    "leg_type": esc["leg_type"],
                })
 
        # ── Determine result ──
        if mismatches:
            result = ReconciliationResult.MISMATCH
        else:
            result = ReconciliationResult.MATCHED
 
        # ── Persist report ──
        report = ReconciliationReport(
            id=report_id,
            instruction_id=instruction.id,
            result=result,
            security_leg_verified=sec_matched,
            cash_leg_verified=cash_matched,
            onchain_supply_matched=onchain_matched,
            rail_confirmation_matched=rail_matched,
            mismatches=mismatches,
        )
 
        async with self._db.transaction():
            await self._db.execute(
                """
                INSERT INTO reconciliation_reports
                  (id, instruction_id, result, security_leg_verified, cash_leg_verified,
                   onchain_supply_matched, rail_confirmation_matched,
                   mismatches, reconciled_at)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
                """,
                report.id, instruction.id, result,
                sec_matched, cash_matched, onchain_matched, rail_matched,
                json.dumps(mismatches), report.reconciled_at,
            )
 
            if result == ReconciliationResult.MISMATCH:
                await self._db.execute(
                    "UPDATE dvp_instructions SET reconciliation_status = $1 WHERE id = $2",
                    "SUSPENDED", instruction.id,
                )
                await self._db.execute(
                    """
                    INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at)
                    VALUES ($1,$2,$3,$4,$5)
                    """,
                    _new_id(), instruction.id, "dvp.reconciliation_mismatch",
                    json.dumps({
                        "instruction_id": instruction.id,
                        "report_id": report.id,
                        "mismatches": mismatches,
                        "alert": "CRITICAL — SETTLEMENT SUSPENDED",
                    }),
                    _now(),
                )
                self._log.critical(
                    "RECONCILIATION MISMATCH — instruction=%s mismatches=%d SETTLEMENT SUSPENDED",
                    instruction.id, len(mismatches)
                )
                raise ReconciliationHalt(
                    f"Reconciliation failed for {instruction.id} — "
                    f"{len(mismatches)} mismatch(es). Settlement suspended."
                )
 
        self._log.info(
            "Reconciliation PASSED for instruction %s", instruction.id
        )
        return report
 
 
# ─────────────────────────────────────────────────────────────────────────────
# 8. DVPSettlementService — Master Orchestrator
# ─────────────────────────────────────────────────────────────────────────────
 
class DVPSettlementService:
    """
    Master orchestrator for the full DVP settlement lifecycle.
 
    Coordinates all sub-services in the correct sequence and
    ensures state machine integrity.
 
    Settlement Flow:
    ────────────────
    1.  Idempotency check (prevent duplicate instructions)
    2.  Persist instruction (INITIATED)
    3.  Compliance screening (OFAC/AML) — outside DB tx
    4.  Lock both settlement legs (LEGS_LOCKED)
    5.  Fund escrow accounts on-chain (ESCROW_FUNDED)
    6.  Submit hybrid rail messages (SWIFT/FedWire/CLS)
    7.  Await multi-sig quorum (MULTISIG_PENDING → MULTISIG_APPROVED)
    8.  Execute atomic swap (ATOMIC_SWAP → SETTLED)
    9.  Post-settlement reconciliation
 
    Unwind Flow (failure / rejection):
    ───────────────────────────────────
    A.  Compliance rejection → release locks → REVERSED
    B.  Multi-sig rejection  → release escrow → REVERSED
    C.  Atomic swap failure  → escrow smart contract auto-releases → FAILED
    D.  Reconciliation halt  → SUSPENDED (manual ops intervention required)
 
    Each step is idempotent and resumable — a crash at any point
    leaves the system in a consistent state recoverable by replaying
    the outbox.
    """
 
    def __init__(
        self,
        db: AbstractDB,
        compliance_service: ComplianceScreeningService,
        leg_service: SettlementLegService,
        escrow_service: EscrowService,
        multisig_service: MultiSigApprovalService,
        atomic_swap: AtomicSwapExecutor,
        hybrid_gateway: HybridSettlementGateway,
        reconciliation_engine: DVPReconciliationEngine,
        # Addresses of escrow smart contracts on the DLT
        security_escrow_address: str,
        cash_escrow_address: str,
        security_token_address: str,
        cash_token_address: str,
    ):
        self._db               = db
        self._compliance       = compliance_service
        self._legs             = leg_service
        self._escrow           = escrow_service
        self._multisig         = multisig_service
        self._swap             = atomic_swap
        self._hybrid           = hybrid_gateway
        self._reconciliation   = reconciliation_engine
        self._sec_escrow_addr  = security_escrow_address
        self._cash_escrow_addr = cash_escrow_address
        self._sec_token_addr   = security_token_address
        self._cash_token_addr  = cash_token_address
        self._log              = logging.getLogger("dvp.orchestrator")
 
    async def initiate_settlement(
        self,
        trade_reference: str,
        isin: str,
        security_type: SecurityType,
        quantity: Decimal,
        price_per_unit: Decimal,
        currency: str,
        seller_entity_id: str,
        buyer_entity_id: str,
        seller_wallet: str,
        buyer_wallet: str,
        seller_custodian: str,
        buyer_custodian: str,
        settlement_rail: SettlementRail,
        intended_settlement_date: str,
        seller_jurisdiction: str,
        buyer_jurisdiction: str,
        idempotency_key: str,
    ) -> SettlementInstruction:
        """
        Entry point for a new DVP settlement instruction.
        Returns immediately with instruction in INITIATED status.
        Subsequent steps run asynchronously.
        """
        # ── Step 1: Idempotency guard ──
        existing = await self._db.fetchrow(
            "SELECT id, status FROM dvp_instructions WHERE idempotency_key = $1",
            idempotency_key,
        )
        if existing:
            self._log.info(
                "Duplicate instruction detected — key=%s, existing_id=%s status=%s",
                idempotency_key, existing["id"], existing["status"]
            )
            raise DuplicateInstructionError(
                f"Instruction with idempotency_key={idempotency_key} already exists "
                f"(id={existing['id']}, status={existing['status']})"
            )
 
        settlement_amount = quantity * price_per_unit
        instruction_id    = _new_id()
        now               = _now()
 
        instruction = SettlementInstruction(
            id=instruction_id,
            trade_reference=trade_reference,
            isin=isin,
            security_type=security_type,
            quantity=quantity,
            price_per_unit=price_per_unit,
            settlement_amount=settlement_amount,
            currency=currency,
            seller_entity_id=seller_entity_id,
            buyer_entity_id=buyer_entity_id,
            seller_wallet=seller_wallet,
            buyer_wallet=buyer_wallet,
            seller_custodian=seller_custodian,
            buyer_custodian=buyer_custodian,
            settlement_rail=settlement_rail,
            intended_settlement_date=intended_settlement_date,
            idempotency_key=idempotency_key,
        )
 
        # ── Step 2: Persist instruction + initial outbox event ──
        async with self._db.transaction():
            await self._db.execute(
                """
                INSERT INTO dvp_instructions
                  (id, trade_reference, isin, security_type, quantity, price_per_unit,
                   settlement_amount, currency, seller_entity_id, buyer_entity_id,
                   seller_wallet, buyer_wallet, seller_custodian, buyer_custodian,
                   settlement_rail, intended_settlement_date, status,
                   idempotency_key, created_at)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19)
                """,
                instruction_id, trade_reference, isin, security_type,
                quantity, price_per_unit, settlement_amount, currency,
                seller_entity_id, buyer_entity_id,
                seller_wallet, buyer_wallet,
                seller_custodian, buyer_custodian,
                settlement_rail, intended_settlement_date,
                SettlementStatus.INITIATED, idempotency_key, now,
            )
            await self._db.execute(
                "INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at) VALUES ($1,$2,$3,$4,$5)",
                _new_id(), instruction_id, "dvp.initiated",
                json.dumps({
                    "instruction_id": instruction_id,
                    "trade_reference": trade_reference,
                    "isin": isin,
                    "quantity": str(quantity),
                    "settlement_amount": str(settlement_amount),
                    "currency": currency,
                    "seller": seller_entity_id,
                    "buyer": buyer_entity_id,
                    "rail": settlement_rail,
                    "initiated_at": now,
                }),
                now,
            )
 
        self._log.info(
            "DVP instruction INITIATED — id=%s ref=%s isin=%s qty=%s",
            instruction_id, trade_reference, isin, quantity
        )
 
        # ── Step 3: Compliance screening (outside DB tx) ──
        await self._db.execute(
            "UPDATE dvp_instructions SET status = $1, updated_at = $2 WHERE id = $3",
            SettlementStatus.COMPLIANCE_CHECK, _now(), instruction_id,
        )
        compliance = await self._compliance.screen_instruction(
            instruction, seller_jurisdiction, buyer_jurisdiction
        )
        if not compliance.is_cleared:
            await self._reject_instruction(instruction_id, compliance.reason)
            raise ComplianceRejectionError(compliance.reason)
 
        # ── Step 4: Lock both legs ──
        await self._legs.create_and_lock_legs(instruction)
 
        # ── Step 5: Fund escrow accounts ──
        await self._escrow.fund_escrow_accounts(
            instruction,
            self._sec_escrow_addr, self._cash_escrow_addr,
            self._sec_token_addr, self._cash_token_addr,
        )
 
        # ── Step 6: Submit hybrid rail messages ──
        await self._hybrid.submit_settlement_messages(instruction)
 
        # ── Multi-sig pending ──
        await self._db.execute(
            "UPDATE dvp_instructions SET status = $1, updated_at = $2 WHERE id = $3",
            SettlementStatus.MULTISIG_PENDING, _now(), instruction_id,
        )
 
        self._log.info(
            "Instruction %s ready for multi-sig approval (both legs locked, escrow funded)",
            instruction_id
        )
        return instruction
 
    async def finalize_settlement(self, instruction_id: str) -> str:
        """
        Called after multi-sig quorum is confirmed.
        Executes atomic swap and runs post-settlement reconciliation.
        Returns swap transaction hash.
        """
        # Reload instruction
        row = await self._db.fetchrow(
            "SELECT * FROM dvp_instructions WHERE id = $1", instruction_id
        )
        if not row:
            raise DVPSettlementError(f"Instruction {instruction_id} not found")
        if row["status"] != SettlementStatus.MULTISIG_APPROVED:
            raise DVPSettlementError(
                f"Cannot finalize — instruction {instruction_id} is in status {row['status']}"
            )
 
        instruction = self._row_to_instruction(row)
 
        # ── Atomic swap ──
        swap_tx_hash = await self._swap.execute(
            instruction, self._sec_escrow_addr, self._cash_escrow_addr
        )
 
        # ── Post-settlement reconciliation ──
        await self._reconciliation.reconcile_instruction(
            instruction, self._sec_token_addr, self._cash_token_addr
        )
 
        return swap_tx_hash
 
    async def _reject_instruction(self, instruction_id: str, reason: str):
        now = _now()
        async with self._db.transaction():
            await self._db.execute(
                "UPDATE dvp_instructions SET status = $1, failure_reason = $2, updated_at = $3 WHERE id = $4",
                SettlementStatus.REVERSED, reason, now, instruction_id,
            )
            await self._db.execute(
                "INSERT INTO outbox_events (id, aggregate_id, event_type, payload, created_at) VALUES ($1,$2,$3,$4,$5)",
                _new_id(), instruction_id, "dvp.rejected",
                json.dumps({"instruction_id": instruction_id, "reason": reason, "rejected_at": now}),
                now,
            )
 
    def _row_to_instruction(self, row: dict) -> SettlementInstruction:
        return SettlementInstruction(
            id=row["id"],
            trade_reference=row["trade_reference"],
            isin=row["isin"],
            security_type=SecurityType(row["security_type"]),
            quantity=Decimal(str(row["quantity"])),
            price_per_unit=Decimal(str(row["price_per_unit"])),
            settlement_amount=Decimal(str(row["settlement_amount"])),
            currency=row["currency"],
            seller_entity_id=row["seller_entity_id"],
            buyer_entity_id=row["buyer_entity_id"],
            seller_wallet=row["seller_wallet"],
            buyer_wallet=row["buyer_wallet"],
            seller_custodian=row["seller_custodian"],
            buyer_custodian=row["buyer_custodian"],
            settlement_rail=SettlementRail(row["settlement_rail"]),
            intended_settlement_date=str(row["intended_settlement_date"]),
            status=SettlementStatus(row["status"]),
            idempotency_key=row["idempotency_key"],
        )
 
 
# ─────────────────────────────────────────────────────────────────────────────
# 9. DVPOutboxPublisher — Reliable Kafka Delivery
# ─────────────────────────────────────────────────────────────────────────────
 
class DVPOutboxPublisher:
    """
    Async background poller — delivers outbox_events to Kafka reliably.
 
    Design:
    - Uses FOR UPDATE SKIP LOCKED → safe for multiple publisher replicas
    - Marks published_at ONLY after successful Kafka delivery
    - Handles transient Kafka failures with exponential backoff
    - Dead-letter queue (DLQ) after MAX_RETRIES exhausted
 
    Kafka topics:
    - dvp.initiated              → Risk systems, compliance dashboards
    - dvp.legs_locked            → CSD position update consumers
    - dvp.escrow_funded          → Custodian notification services
    - dvp.multisig_vote          → Approval workflow systems
    - dvp.multisig_approved      → Swap execution trigger
    - dvp.atomic_swap_initiated  → Monitoring / circuit breakers
    - dvp.settled                → Trade reporting (MiFID II / EMIR), DTCC
    - dvp.rejected / dvp.failed  → Ops alerts, SLA breach trackers
    - dvp.reconciliation_mismatch→ CRITICAL — ops paging system
 
    Production deployment:
    - Run as a separate Kubernetes pod / ECS task
    - Min replicas: 2 (active-active with SKIP LOCKED)
    - Kafka: TLS, SASL auth, replication factor 3, min.insync.replicas 2
    """
 
    MAX_RETRIES = 3
    BATCH_SIZE  = 50
 
    def __init__(self, db: AbstractDB, kafka_producer):
        self._db       = db
        self._kafka    = kafka_producer
        self._log      = logging.getLogger("dvp.outbox_publisher")
 
    async def run_forever(self, poll_interval: float = 1.0):
        self._log.info("DVP OutboxPublisher started — polling every %.1fs", poll_interval)
        while True:
            try:
                await self._poll_and_publish()
            except Exception as exc:
                self._log.error("Publisher poll error: %s", exc)
            await asyncio.sleep(poll_interval)
 
    async def _poll_and_publish(self):
        events = await self._db.fetch(
            """
            SELECT id, aggregate_id, event_type, payload, retry_count
            FROM outbox_events
            WHERE published_at IS NULL
              AND (next_retry_at IS NULL OR next_retry_at <= NOW())
            ORDER BY created_at
            LIMIT $1
            FOR UPDATE SKIP LOCKED
            """,
            self.BATCH_SIZE,
        )
        if not events:
            return
 
        for event in events:
            await self._deliver(event)
 
    async def _deliver(self, event: dict):
        event_id   = event["id"]
        event_type = event["event_type"]
        payload    = event["payload"] if isinstance(event["payload"], dict) else json.loads(event["payload"])
        retries    = event.get("retry_count", 0)
 
        kafka_message = json.dumps({
            "event_id": event_id,
            "event_type": event_type,
            "aggregate_id": event["aggregate_id"],
            "payload": payload,
            "published_at": _now(),
        }).encode()
 
        try:
            await self._kafka.send_and_wait(
                topic=f"dvp.{event_type.split('.', 1)[-1]}",
                value=kafka_message,
                key=event["aggregate_id"].encode(),
            )
            await self._db.execute(
                "UPDATE outbox_events SET published_at = $1 WHERE id = $2",
                _now(), event_id,
            )
            self._log.debug("Published event %s type=%s", event_id, event_type)
 
        except Exception as exc:
            self._log.warning(
                "Failed to publish event %s (attempt %d): %s",
                event_id, retries + 1, exc
            )
            if retries + 1 >= self.MAX_RETRIES:
                await self._send_to_dlq(event_id, event_type, payload, str(exc))
            else:
                # Exponential backoff: 5s, 25s, 125s
                next_retry_seconds = 5 ** (retries + 1)
                await self._db.execute(
                    """
                    UPDATE outbox_events
                    SET retry_count = retry_count + 1,
                        next_retry_at = NOW() + ($1 * INTERVAL '1 second'),
                        last_error = $2
                    WHERE id = $3
                    """,
                    next_retry_seconds, str(exc), event_id,
                )
 
    async def _send_to_dlq(self, event_id: str, event_type: str, payload: dict, error: str):
        dlq_message = json.dumps({
            "event_id": event_id,
            "event_type": event_type,
            "payload": payload,
            "error": error,
            "dlq_at": _now(),
        }).encode()
        try:
            await self._kafka.send_and_wait(topic="dvp.dead_letter_queue", value=dlq_message)
        except Exception:
            pass
        await self._db.execute(
            "UPDATE outbox_events SET published_at = $1, dlq_at = $1 WHERE id = $2",
            _now(), event_id,
        )
        self._log.error(
            "Event %s (type=%s) sent to DLQ after %d attempts — error: %s",
            event_id, event_type, self.MAX_RETRIES, error
        )
 
 
# ─────────────────────────────────────────────────────────────────────────────
# AsyncpgDB — Real Database Adapter
# ─────────────────────────────────────────────────────────────────────────────


async def _init_connection(conn):
    """Configure asyncpg codecs so strings pass through for UUID/timestamp."""
    for typename in ('uuid', 'timestamptz', 'timestamp', 'date'):
        await conn.set_type_codec(
            typename, encoder=str, decoder=str,
            schema='pg_catalog', format='text',
        )
    await conn.set_type_codec(
        'jsonb',
        encoder=lambda v: v if isinstance(v, str) else json.dumps(v),
        decoder=json.loads,
        schema='pg_catalog', format='text',
    )


class AsyncpgDB(AbstractDB):
    """
    Wraps asyncpg pool, implementing AbstractDB.
    Routes queries through a transaction connection when active.
    """

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


# ─────────────────────────────────────────────────────────────────────────────
# Sandbox Stubs (for local development / testing only)
# ─────────────────────────────────────────────────────────────────────────────
 
class SandboxComplianceProvider(AbstractComplianceProvider):
    """Stub: always clears. Replace with Fircosoft / ComplyAdvantage in prod."""
    async def screen_entity(self, entity_id, jurisdiction, lei=None) -> ComplianceDecision:
        return ComplianceDecision(
            is_cleared=True,
            reason="SANDBOX — screening bypassed",
            screening_reference=f"SANDBOX-{uuid.uuid4().hex[:8].upper()}",
        )
 
 
class SandboxHSMSigningService(AbstractHSMSigningService):
    """Stub: simulated ECDSA signature. Replace with CloudHSM / Fireblocks."""
    async def sign(self, payload: dict, signer_id: str) -> str:
        import hashlib
        return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
 
 
class SandboxChainAdapter(AbstractChainAdapter):
    """Stub: simulated DLT. Replace with web3.py / ethers.js sidecar."""
    async def get_balance(self, wallet, token_address) -> Decimal:
        return Decimal("9999999")   # Sandbox always has enough
 
    async def transfer_to_escrow(self, from_wallet, escrow_address, amount, token_address, instruction_id) -> str:
        return f"0x{uuid.uuid4().hex}"
 
    async def atomic_swap(self, security_escrow, security_beneficiary, cash_escrow, cash_beneficiary, instruction_id) -> str:
        return f"0xSWAP{uuid.uuid4().hex}"
 
 
class SandboxSWIFTGateway(AbstractSWIFTGateway):
    """Stub: simulated SWIFT. Replace with SWIFT Alliance Gateway / MX API."""
    async def send_mt(self, message_type, payload) -> str:
        uetr = str(uuid.uuid4())
        logger.info("[SWIFT STUB] Sent %s — UETR=%s", message_type, uetr)
        return uetr
 
 
class SandboxFedWireGateway(AbstractFedWireGateway):
    """Stub: simulated FedWire. Replace with Fed FedLine / ISO 20022 adapter."""
    async def submit_fedwire(self, payload) -> str:
        imad = uuid.uuid4().hex[:16].upper()
        logger.info("[FEDWIRE STUB] Submitted — IMAD=%s", imad)
        return imad
 
 
class SandboxCLSGateway(AbstractCLSGateway):
    """Stub: simulated CLS. Replace with CLS CLSNet / CLSSettlement API."""
    async def submit_cls_instruction(self, payload) -> str:
        ref = f"CLS{uuid.uuid4().hex[:10].upper()}"
        logger.info("[CLS STUB] Submitted — ref=%s", ref)
        return ref
 
 
class SandboxSigningQueue(AbstractSigningQueue):
    async def enqueue(self, instruction_id: str, payload: dict) -> str:
        msg_id = str(uuid.uuid4())
        logger.info("[QUEUE STUB] Enqueued instruction=%s msg=%s", instruction_id, msg_id)
        return msg_id
 
 
# ─────────────────────────────────────────────────────────────────────────────
# Sandbox Entrypoint — Illustrative Usage
# ─────────────────────────────────────────────────────────────────────────────
 
async def sandbox_demo():
    """
    Runs the full DVP settlement flow against a real PostgreSQL database.
    External services (SWIFT, FedWire, CLS, HSM, chain) use sandbox stubs.
    Outbox events are written to outbox_events for Kafka delivery
    by the separate outbox-publisher.py process.

    Scenario: BlackRock sells 100,000 AAPL shares to State Street
    at $195/share = $19,500,000 USD via SWIFT + on-chain atomic swap.
    """
    logger.info("=" * 70)
    logger.info("DVP Settlement & Clearing System — Live Sandbox Demo")
    logger.info(
        "Scenario: BlackRock 100K AAPL → State Street | $19.5M USD"
    )
    logger.info("=" * 70)

    # ── Connect to PostgreSQL ─────────────────────────────────────────────────────
    database_url = os.getenv(
        "DATABASE_URL", "postgresql://postgres@localhost/dvp_sandbox"
    )
    pool = await asyncpg.create_pool(
        database_url, min_size=2, max_size=5, init=_init_connection,
    )
    db = AsyncpgDB(pool)
    logger.info(
        "Connected to PostgreSQL — %s", database_url.split("@")[-1]
    )

    # ── Wire services (real DB + sandbox external stubs) ──────────────────
    compliance_svc = ComplianceScreeningService(
        db, SandboxComplianceProvider()
    )
    chain = SandboxChainAdapter()
    leg_svc = SettlementLegService(db, chain)
    escrow_svc = EscrowService(db, chain)
    hsm = SandboxHSMSigningService()
    signing_queue = SandboxSigningQueue()

    required_custodians = ["IRVTUS3N", "SBOSUS33", "DTCCUS3N"]
    multisig_svc = MultiSigApprovalService(db, hsm, required_custodians)
    swap_executor = AtomicSwapExecutor(db, chain, signing_queue)
    hybrid_gw = HybridSettlementGateway(
        db, SandboxSWIFTGateway(), SandboxFedWireGateway(),
        SandboxCLSGateway(),
    )
    recon_engine = DVPReconciliationEngine(db, chain)

    dvp_svc = DVPSettlementService(
        db=db,
        compliance_service=compliance_svc,
        leg_service=leg_svc,
        escrow_service=escrow_svc,
        multisig_service=multisig_svc,
        atomic_swap=swap_executor,
        hybrid_gateway=hybrid_gw,
        reconciliation_engine=recon_engine,
        security_escrow_address="0xSECURITY_ESCROW_CONTRACT",
        cash_escrow_address="0xCASH_ESCROW_CONTRACT",
        security_token_address="0xAAPL_TOKEN_CONTRACT",
        cash_token_address="0xUSD_TOKEN_CONTRACT",
    )
    logger.info("All services wired (real DB + sandbox external stubs)")

    # ── Execute full settlement flow ──────────────────────────────────────────
    try:
        # Steps 1-6: initiate → compliance → lock legs → escrow → SWIFT
        instruction = await dvp_svc.initiate_settlement(
            trade_reference="BLK-SST-AAPL-LIVE-001",
            isin="US0378331005",
            security_type=SecurityType.EQUITY,
            quantity=Decimal("100000"),
            price_per_unit=Decimal("195.00"),
            currency="USD",
            seller_entity_id="549300BNMGNFKN6LAD61",
            buyer_entity_id="571474TGEMMWANRLN572",
            seller_wallet="0xBLACKROCK_WALLET_ADDRESS",
            buyer_wallet="0xSTATESTREET_WALLET_ADDRESS",
            seller_custodian="IRVTUS3N",
            buyer_custodian="SBOSUS33",
            settlement_rail=SettlementRail.SWIFT,
            intended_settlement_date="2026-03-23",
            seller_jurisdiction="US",
            buyer_jurisdiction="US",
            idempotency_key=str(uuid.uuid4()),
        )
        logger.info(
            "Instruction %s at MULTISIG_PENDING", instruction.id
        )

        # Step 7: Cast multi-sig votes (2-of-3 quorum)
        await multisig_svc.cast_vote(
            instruction.id, "IRVTUS3N",
            "HSM-BNYM-KEY-001", MultiSigVote.APPROVE,
        )
        await multisig_svc.cast_vote(
            instruction.id, "SBOSUS33",
            "HSM-SST-KEY-001", MultiSigVote.APPROVE,
        )

        if await multisig_svc.check_quorum(instruction.id):
            await multisig_svc.finalize_quorum(instruction.id)
            logger.info("Multi-sig quorum reached")

        # Steps 8-9: Atomic swap + reconciliation
        try:
            swap_tx = await dvp_svc.finalize_settlement(
                instruction.id
            )
            logger.info("Settlement COMPLETE — tx=%s", swap_tx)
        except ReconciliationHalt:
            logger.warning(
                "Reconciliation mismatch (expected in sandbox — "
                "on-chain balances are stubbed). "
                "Mismatch event written to outbox."
            )

    except DVPSettlementError as exc:
        logger.error("Settlement failed: %s", exc)

    # ── Show outbox events ────────────────────────────────────────────────────
    events = await db.fetch(
        "SELECT event_type, created_at, published_at "
        "FROM outbox_events ORDER BY created_at"
    )
    logger.info("")
    logger.info("Outbox events in database (%d total):", len(events))
    for ev in events:
        status = "PENDING" if ev["published_at"] is None else "PUBLISHED"
        logger.info("  %-40s %s", ev["event_type"], status)
    logger.info("")
    logger.info(
        "Run: python3 outbox-publisher.py  "
        "to deliver these events to Kafka"
    )
    logger.info("=" * 70)

    await pool.close()


if __name__ == "__main__":
    asyncio.run(sandbox_demo())
