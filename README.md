# 🏦 Institutional DVP Settlement & Clearing System (Python)

> ⚠️ **SANDBOX / EDUCATIONAL USE ONLY — NOT FOR PRODUCTION**
> This codebase is a reference implementation designed for learning, prototyping, and architectural exploration. It is **not audited, not legally reviewed, and must not be used to settle real securities, manage investor funds, or interface with real payment rails (SWIFT, FedWire, CLS).** See the [Production Warning](#-production-warning) section for full details.

---

## Table of Contents

- [Overview](#-overview)
- [What is DVP Settlement?](#-what-is-dvp-settlement)
- [Architecture](#-architecture)
- [Core Services](#-core-services)
- [Key Features & Design Patterns](#-key-features--design-patterns)
- [Database Schema](#-database-schema)
- [State Machines](#-state-machines)
- [Real-World Example: BlackRock → State Street](#-real-world-example-blackrock--state-street)
- [Running in a Sandbox Environment](#-running-in-a-sandbox-environment)
- [Project Structure](#-project-structure)
- [Production Warning](#-production-warning)
- [License](#-license)

---

## 📖 Overview

The **Institutional DVP Settlement & Clearing System** is a Python-based reference implementation that models the full lifecycle of a **Delivery vs. Payment (DVP)** settlement instruction — from initial instruction creation through compliance screening, leg locking, escrow funding, multi-sig authorization, atomic swap execution, hybrid payment rail messaging (SWIFT / FedWire / CLS), and post-settlement reconciliation. Every operation is protected by **role-based access control (RBAC)** and recorded in an **append-only audit trail** with full request/trace lineage.

The system is modeled closely on how institutional settlement infrastructure operates at **JPMorgan Onyx**, **DTCC Project Ion**, **CLS (Continuous Linked Settlement)**, and **Euroclear**. It demonstrates how traditional financial infrastructure (SWIFT, FedWire, custodian systems) integrates with distributed ledger technology (tokenized securities, tokenized cash, atomic swaps) to achieve T+0 finality while eliminating counterparty risk.

| Component | File | Responsibility |
|-----------|------|----------------|
| Core Services | `dvp-settlement.py` | All service classes — instruction through reconciliation |
| Database Schema & Demo | `dvp-settlement.sql` | PostgreSQL schema, indexes, and a full BlackRock → State Street walkthrough |
| Outbox Publisher | `outbox-publisher.py` | Async background poller — DB outbox → Kafka |
| Docker Compose | `docker-compose.yaml` | 9-service orchestration with trust domain network isolation |
| DB Schema Init | `db/init/001-schema.sql` | Append-only immutable schema + RBAC tables + audit log (auto-loaded on first run) |
| Readonly User | `db/init/002-readonly-user.sql` | Restricted DB user for outbox publisher service |

---

## 🌍 What is DVP Settlement?

**Delivery vs. Payment (DVP)** is the gold standard settlement mechanism for securities transactions. It ensures that the delivery of securities from seller to buyer occurs **simultaneously and atomically** with the payment of cash from buyer to seller. Neither party receives their asset until both sides of the trade are ready — eliminating counterparty risk entirely.

DVP is the backbone of:
- **T+0 / T+1 settlement** that regulators (SEC, ESMA) are mandating
- **Repo and reverse-repo markets** (overnight / intraday liquidity)
- **Tokenized securities platforms** (JPMorgan Onyx, DTCC Project Ion)
- **Cross-border FX settlement** (CLS eliminates Herstatt risk)
- **Central bank digital currency (CBDC) settlement pilots**

This system implements DVP at the institutional level — handling the full complexity of multi-custodian coordination, payment rail messaging, HSM-based multi-sig authorization, RBAC-enforced access control with separation of duties, end-to-end audit trails, and 4-source post-settlement reconciliation.

---

## 🏗 Architecture

```
                    ┌──────────────────────────────────────────────────────────┐
                    │              DVP SETTLEMENT LIFECYCLE                    │
                    └──────────────────────────────────────────────────────────┘

  Off-Chain / Application Layer                         On-Chain / DLT Layer
  ────────────────────────────────────────────────────────────────────────────

  1. DVPSettlementService        Initiate instruction
     (initiate_settlement) ─────────────────────────► PostgreSQL
                                                       + Outbox Event

  2. ComplianceScreeningService  OFAC / AML / Sanctions
     (screen_instruction) ──── ComplyAdvantage ──────► compliance_screenings
                                OFAC SDN API            (both parties parallel)

  3. SettlementLegService        Lock both legs
     (create_and_lock_legs) ───────────────────────── custody_positions
                                 SELECT FOR UPDATE      (seller: locked_qty++)
                                                        cash_accounts
                                                        (buyer: locked_bal++)
                                                        + Outbox Event

  4. EscrowService               Fund on-chain escrow
     (fund_escrow_accounts) ──────────────────────────► ERC-1400 / CBDC
                                                        transfer_to_escrow()
                                                        ↓
                                                        escrow_accounts
                                                        + Outbox Event

  5. HybridSettlementGateway     Off-chain payment rails
     (submit_settlement_messages)
        SWIFT ─────────────────────────────────────────► MT543 (securities)
        FedWire ───────────────────────────────────────► MT103 (cash)
        CLS ───────────────────────────────────────────► CTR FedWire tag

  6. MultiSigApprovalService     Custodian authorization
     (cast_vote × N) ─────── HSM / MPC ──────────────► multisig_approvals
                                                        + Outbox Event

  7. AtomicSwapExecutor          Simultaneous swap (irrevocable)
     (execute) ────────────────────────────────────────► atomic_swap()
                                                         Securities → Buyer
                                                         Cash → Seller
                                                         (single tx)
                                                        ↓
                                                        Ledger settled atomically
                                                        + Outbox Event

  8. DVPReconciliationEngine     4-source verification
     (reconcile_instruction) ── Chain node ───────────► Balance check
                             └── Rail ACKs              Escrow closure check
                             └── Custodian API          Rail confirmation check
                                                        ↓
                                                        MATCHED or SUSPENDED
```

---

## ⚙️ Core Services

### `DVPSettlementService`

The master orchestrator. Coordinates all sub-services in strict sequence, enforces state machine integrity, and provides the single entry point for initiating and finalizing DVP settlement instructions. Every call requires an `AuditContext` (request_id, trace_id, actor, actor_role) and passes through RBAC permission checks before execution. Handles the full unwind path on failures at any stage.

### `ComplianceScreeningService`

Screens both counterparties (seller + buyer) concurrently against OFAC SDN, EU/UN consolidated sanctions lists, and PEP lists. Both screens run in parallel via `asyncio.gather()` and are called **outside** the database transaction to avoid holding row locks during slow external API calls. A single hit on either entity blocks the entire instruction.

### `SettlementLegService`

Creates and locks both legs of the DVP instruction atomically. Uses `SELECT … FOR UPDATE` pessimistic locking on `custody_positions` and `cash_accounts` to prevent double-delivery and double-payment race conditions. Both legs are created and both balances reserved in a single database transaction.

### `EscrowService`

Manages the dual on-chain escrow accounts that are the physical manifestation of the DVP guarantee. Neither leg can be released independently — the security escrow releases only if the cash escrow also releases (and vice versa), enforced at the smart contract level. Handles both the settlement path (atomic swap) and the unwind path (multi-sig reversal on failure).

### `MultiSigApprovalService`

Manages custodian approval votes for atomic swap authorization. Default quorum: 2-of-3 (both custodians required; CCP optional). HSM signatures are generated **outside** the DB transaction. Prevents double-voting via a unique constraint on `(instruction_id, custodian_id)`. Enforces **separation of duties** — the actor who initiated the instruction cannot also vote on it. The atomic swap cannot execute until `check_quorum()` returns `True`.

### `AtomicSwapExecutor`

The core DVP mechanism. Executes the simultaneous, irrevocable on-chain release of both escrow accounts in a single atomic transaction. Marks the instruction as `ATOMIC_SWAP` **before** the chain call (enabling crash recovery via replay). If the swap fails, the escrow smart contract guarantees neither party is left holding only one leg. On success, settles all ledger entries atomically.

### `HybridSettlementGateway`

Bridges on-chain DVP with traditional payment rails. Submits SWIFT MT543/MT103 messages, FedWire Funds Service instructions, and CLS payment pairs as appropriate for the instruction's `settlement_rail`. All messages are persisted in `hybrid_rail_messages` and reconciled post-settlement.

### `DVPReconciliationEngine`

Post-settlement 4-source reconciliation engine. Checks: (1) internal ledger vs on-chain token balances, (2) escrow account closure, (3) settlement leg delivery status, and (4) payment rail confirmation. Any mismatch is a **CRITICAL** event — all further settlements for the instruction are immediately suspended, a `dvp.reconciliation_mismatch` event is published to Kafka (triggering ops paging), and a `ReconciliationHalt` exception is raised.

### `DVPOutboxPublisher`

Standalone async background process. Polls `outbox_events` with `FOR UPDATE SKIP LOCKED` for safe multi-replica deployment. Delivers events to Kafka with exponential backoff retry (5s → 25s → 125s). After `MAX_RETRIES`, events are forwarded to `dvp.dead_letter_queue` and flagged for manual intervention.

### `AuditContext`

Immutable dataclass threaded through every service call. Carries `request_id`, `trace_id`, `actor`, and `actor_role`. Every database write includes these four fields, creating an unbroken audit chain from API entry point to ledger mutation. Factory methods `AuditContext.system()` and `AuditContext.for_actor()` create contexts for system operations and human/custodian actors respectively.

### `RBACChecker`

Loads and caches per-actor permissions from the `rbac_actor_roles` / `rbac_role_permissions` join. The `@require_permission` decorator enforces RBAC before any service method executes — if the actor's role lacks the required permission, an `AuthorizationError` is raised before any side effect occurs. Permissions are cached per-actor for the lifetime of the request.

---

## ✨ Key Features & Design Patterns

### ✅ Atomic DVP — Zero Counterparty Risk

The atomic swap guarantees that securities and cash change hands simultaneously in a single on-chain transaction. If the chain transaction reverts for any reason, neither party loses their asset. This is the fundamental DVP guarantee, implemented at both the smart contract layer and the application orchestration layer.

### ✅ Dual Escrow Model

Security escrow and cash escrow are independent smart contracts that only release in tandem. This mirrors JPMorgan Onyx's repo escrow model and DTCC Project Ion's DLT atomic delivery. Neither custodian can unilaterally release their escrow — multi-sig quorum is required for any release (settlement or reversal).

### ✅ Pessimistic Locking — No Double-Delivery

`SELECT … FOR UPDATE` on `custody_positions` and `cash_accounts` prevents two concurrent DVP instructions from both reserving the same securities or cash. The second instruction blocks until the first transaction commits, then sees the updated (reduced) available balance.

### ✅ Transactional Outbox Pattern (All Services)

Every service writes its outbox event in the **same database transaction** as the business record. This eliminates the dual-write problem across all eight services. The `DVPOutboxPublisher` delivers events to Kafka only after they are safely committed to PostgreSQL — downstream systems (risk, compliance, DTCC reporting) never miss an event even across crashes.

### ✅ HSM-Based Multi-Sig Authorization

Swap execution requires cryptographic approval from both custodians via HSM-generated signatures. This mirrors Fireblocks MPC threshold signing and AWS CloudHSM workflows. The `AbstractHSMSigningService` interface allows plugging in any HSM vendor without changing business logic.

### ✅ Hybrid Settlement Rail Integration

The system handles the reality that institutional DVP is never purely on-chain. Cash legs often require SWIFT MT103 (cross-bank credit transfer), FedWire (USD same-day gross settlement), or CLS (FX settlement, eliminating Herstatt risk). All rail messages are persisted and reconciled post-settlement.

### ✅ Idempotency at Every Layer

Each service method checks for an existing `idempotency_key` before any side effect. Re-submitted instructions return the original result with no duplicate operations. This covers: instruction initiation, compliance screenings, leg creation, escrow funding, multi-sig votes, and swap execution.

### ✅ 4-Source Reconciliation as a Hard Stop

The `DVPReconciliationEngine` treats any discrepancy as an emergency, not a warning. The ledger is immediately suspended — no future operations on the affected instruction are permitted until the mismatch is manually resolved by the operations team.

### ✅ Decimal Precision for Financial Arithmetic

All security quantities and monetary values use Python's `Decimal` type rather than floats, preventing IEEE 754 rounding errors from corrupting financial calculations — mandatory in any system handling securities or currency at institutional scale.

### ✅ Automatic Database Creation & Schema Loading

The `ensure_database()` function detects whether the target database exists on startup. If missing, it creates the database and loads every SQL file from `db/init/` in sorted order — applying the full append-only schema and readonly user configuration. No manual `CREATE DATABASE` or `psql -f` step required.

### ✅ Idempotent Demo Data Seeding

The `seed_sandbox_data()` function runs on every startup and idempotently inserts the BlackRock / State Street / BNY Mellon / DTCC entities, custody positions, and initial balances. Every INSERT is guarded by an existence check, so re-runs are safe against the append-only schema.

### ✅ Automatic Kafka Event Publishing

After settlement completes, the sandbox demo automatically connects to Kafka and publishes all pending outbox events. If Kafka is unavailable, events remain in the outbox for later delivery by the standalone `outbox-publisher.py` process. No separate publisher step is required for the demo flow.

### ✅ Role-Based Access Control (RBAC)

Every service method is gated by a `@require_permission` decorator that checks the caller's permissions before any side effect. Six pre-seeded roles — `ADMIN`, `ORIGINATOR`, `CUSTODIAN`, `COMPLIANCE_OFFICER`, `SYSTEM`, and `SIGNING_AGENT` — map to granular permissions (`settlement.initiate`, `multisig.vote`, `compliance.screen`, `escrow.fund`, etc.). Roles, permissions, and actor assignments are stored in append-only RBAC tables with mutation triggers that prevent UPDATE/DELETE.

### ✅ End-to-End Audit Trail

Every database write across all services includes `request_id`, `trace_id`, `actor`, and `actor_role` columns. A dedicated `audit_log` table records every operation with the affected resource and detail payload. The `trace_id` links all operations within a single settlement flow, while `request_id` identifies individual service calls — enabling full reconstruction of who did what, when, and why.

### ✅ Separation of Duties

The `MultiSigApprovalService` enforces that the actor who initiated a settlement instruction cannot also cast a vote on it. This prevents a single compromised or malicious actor from both originating and approving a trade — a fundamental institutional control required by custodian compliance frameworks.

### ✅ Colorized Demo Output

The sandbox demo uses a `DemoFormatter` that renders human-readable, colorized terminal output with section banners, service-tagged log lines, key=value highlighting, and formatted event tables. Toggle between demo and structured JSON output via the `DVP_LOG_FORMAT` environment variable (`demo` for colorized, `json` for structured). Noisy Kafka topic auto-creation warnings are suppressed in demo mode.

---

## 🗄 Database Schema

### `registered_entities`

LEI-identified institutional participants.

| Column | Type | Description |
|--------|------|-------------|
| `lei` | VARCHAR(20) UNIQUE | ISO 17442 Legal Entity Identifier |
| `entity_type` | VARCHAR(50) | `ASSET_MANAGER`, `CUSTODIAN`, `PRIME_BROKER`, `CCP`, `CSD` |
| `bic` | VARCHAR(11) | SWIFT BIC for payment message routing |

### `custody_positions`

Two-field security ledger per `(entity, ISIN)`.

| Column | Type | Description |
|--------|------|-------------|
| `available_quantity` | DECIMAL(38,10) | Free to deliver |
| `locked_quantity` | DECIMAL(38,10) | Reserved for pending DVP security legs |
| `token_address` | VARCHAR(256) | ERC-1400 / ERC-3643 contract address |

> **Available** = `available_quantity` only. Locked quantity cannot be delivered until the DVP settles or is reversed.

### `cash_accounts`

Three-field cash ledger per `(entity, currency)`.

| Column | Type | Description |
|--------|------|-------------|
| `balance` | DECIMAL(38,2) | Total balance |
| `available_balance` | DECIMAL(38,2) | Free to pay |
| `locked_balance` | DECIMAL(38,2) | Reserved for pending DVP cash legs |

### `dvp_instructions`

Root record for each DVP settlement instruction.

| Column | Type | Description |
|--------|------|-------------|
| `isin` | VARCHAR(12) | ISO 6166 security identifier |
| `quantity` | DECIMAL(38,10) | Number of securities / units |
| `settlement_amount` | DECIMAL(38,2) | `quantity × price_per_unit` (cash leg) |
| `settlement_rail` | VARCHAR(20) | `SWIFT`, `FEDWIRE`, `CLS`, `ONCHAIN`, `INTERNAL` |
| `swap_tx_hash` | VARCHAR(256) | On-chain atomic swap tx (irrevocable once set) |
| `idempotency_key` | VARCHAR(256) UNIQUE | Deduplication key |

### `escrow_accounts`

On-chain escrow state per DVP instruction.

| Column | Type | Description |
|--------|------|-------------|
| `leg_type` | VARCHAR(20) | `SECURITY` or `CASH` |
| `escrow_address` | VARCHAR(256) | Smart contract address |
| `on_chain_tx_hash` | VARCHAR(256) | Transfer-to-escrow transaction |

### `multisig_approvals`

Custodian approval votes — one per `(instruction, custodian)`.

| Column | Type | Description |
|--------|------|-------------|
| `custodian_id` | VARCHAR(100) | SWIFT BIC of custodian |
| `vote` | VARCHAR(10) | `APPROVE`, `REJECT`, `ABSTAIN` |
| `signature` | VARCHAR(256) | HSM/MPC signature (ECDSA / BIP-340) |

### `hybrid_rail_messages`

Off-chain payment messages for SWIFT / FedWire / CLS.

| Column | Type | Description |
|--------|------|-------------|
| `rail` | VARCHAR(20) | `SWIFT`, `FEDWIRE`, `CLS` |
| `message_type` | VARCHAR(30) | `MT103`, `MT543`, `FEDWIRE_CTR`, `CLS_DVP_MATCHED` |
| `rail_reference` | VARCHAR(256) | SWIFT UETR / FedWire IMAD / CLS reference |

### `outbox_events`

Reliable Kafka delivery buffer.

| Column | Type | Description |
|--------|------|-------------|
| `event_type` | VARCHAR(100) | e.g. `dvp.settled`, `dvp.reconciliation_mismatch` |
| `aggregate_id` | VARCHAR(256) | DVP instruction ID |
| `published_at` | TIMESTAMP | NULL = pending Kafka delivery |
| `retry_count` | INT | Delivery attempt count |
| `dlq_at` | TIMESTAMP | NULL = not dead-lettered |

### `audit_log`

Append-only audit trail for all operations.

| Column | Type | Description |
|--------|------|-------------|
| `request_id` | UUID | Unique ID per service call |
| `trace_id` | UUID | Shared across all calls in one settlement flow |
| `actor` | VARCHAR(256) | Who performed the operation (LEI, BIC, or SYSTEM/*) |
| `actor_role` | VARCHAR(50) | `SYSTEM`, `CUSTODIAN`, `ORIGINATOR`, etc. |
| `operation` | VARCHAR(100) | e.g. `settlement.initiate`, `multisig.vote` |
| `resource` | VARCHAR(256) | Affected resource ID (instruction, leg, escrow) |
| `detail` | JSONB | Operation-specific payload |

### `rbac_roles`

Named roles for access control.

| Column | Type | Description |
|--------|------|-------------|
| `role_name` | VARCHAR(50) UNIQUE | `ADMIN`, `ORIGINATOR`, `CUSTODIAN`, `COMPLIANCE_OFFICER`, `SYSTEM`, `SIGNING_AGENT` |
| `description` | TEXT | Human-readable role description |

### `rbac_role_permissions`

Granular permissions assigned to each role.

| Column | Type | Description |
|--------|------|-------------|
| `role_id` | UUID FK | References `rbac_roles(id)` |
| `permission` | VARCHAR(100) | e.g. `settlement.initiate`, `multisig.vote`, `*` (wildcard) |

### `rbac_actor_roles`

Maps actors (entities, system accounts) to roles.

| Column | Type | Description |
|--------|------|-------------|
| `actor` | VARCHAR(256) | Actor identifier (LEI, BIC, or SYSTEM/*) |
| `role_id` | UUID FK | References `rbac_roles(id)` |
| `granted_by` | VARCHAR(256) | Who granted this role assignment |

---

## 🔁 State Machines

### DVP Instruction Status

```
                      ┌──────────────────┐
  initiate_settlement►│    INITIATED     │
                      └────────┬─────────┘
                               │  compliance screening
                               ▼
                      ┌──────────────────┐
                      │COMPLIANCE_CHECK  │
                      └────────┬─────────┘
                               │  both parties cleared
                               ▼
                      ┌──────────────────┐
                      │  LEGS_LOCKED     │────────────────────┐
                      └────────┬─────────┘                   │
                               │  on-chain escrow funded      │ compliance
                               ▼                              │ rejection
                      ┌──────────────────┐                   │
                      │  ESCROW_FUNDED   │                   ▼
                      └────────┬─────────┘          ┌──────────────────┐
                               │  rail msgs sent      │    REVERSED      │
                               ▼                      └──────────────────┘
                      ┌──────────────────┐
                      │ MULTISIG_PENDING │
                      └────────┬─────────┘
                               │  quorum reached
                               ▼
                      ┌──────────────────┐
                      │MULTISIG_APPROVED │
                      └────────┬─────────┘
                               │  atomic swap initiated
                               ▼
                      ┌──────────────────┐
                      │  ATOMIC_SWAP     │────────────────────┐
                      └────────┬─────────┘                   │ swap failure
                               │  on-chain confirmed          ▼
                               ▼                     ┌──────────────────┐
                      ┌──────────────────┐           │     FAILED       │
                      │    SETTLED       │           └──────────────────┘
                      └────────┬─────────┘
                               │  reconciliation
                               ▼
                      ┌──────────────────┐
                      │    MATCHED       │  (reconciliation_status)
                      └──────────────────┘
```

### Settlement Leg Status

```
  create_and_lock_legs() ──► PENDING ──► LOCKED ──► IN_ESCROW ──► DELIVERED
                                                        │
                                                        └──► RELEASED  (unwind)
```

---

## 🏢 Real-World Example: BlackRock → State Street

The SQL demo models a real institutional DVP trade:

| Attribute | Value |
|-----------|-------|
| Seller | BlackRock, Inc. (LEI: 549300BNMGNFKN6LAD61) |
| Buyer | State Street Bank and Trust (LEI: 571474TGEMMWANRLN572) |
| Security | Apple Inc. Common Stock (AAPL) |
| ISIN | US0378331005 |
| Quantity | 500,000 shares |
| Price | $195.00 per share |
| Settlement Amount | **$97,500,000 USD** |
| Settlement Rail | SWIFT (MT543 + MT103) + on-chain atomic swap |
| Settlement Date | T+0 (same-day) |
| Seller Custodian | BNY Mellon (IRVTUS3N) |
| Buyer Custodian | State Street (SBOSUS33) |

**Post-settlement positions:**

| Entity | AAPL Position | USD Balance |
|--------|---------------|-------------|
| BlackRock | 1,500,000 shares (down from 2M) | $107,500,000 |
| State Street | 500,000 shares (up from 0) | $402,500,000 |

---

## 🧪 Running in a Sandbox Environment

### Option A: Docker Compose (Recommended)

The fastest way to run the entire system. Docker Compose orchestrates all 9 services with trust domain network isolation.

**Prerequisites:** Docker and Docker Compose.

```bash
docker compose up --build
```

This starts:

| Service | Description | Network(s) |
|---------|-------------|------------|
| `postgres` | PostgreSQL 16 — schema auto-initialized, no host ports | internal |
| `dvp-service` | Runs full settlement lifecycle (register, fund, settle) | backend, internal |
| `outbox-publisher` | Polls outbox, delivers to Kafka (readonly_user) | backend, internal |
| `zookeeper` | Kafka coordination | backend |
| `kafka` | Event streaming (host port 9092) | backend |
| `signing-gateway` | HSM/MPC signing gateway (host port 8000) | backend, signing |
| `mpc-node-1/2/3` | MPC threshold signing nodes | signing |

**Trust domain networks:**

| Network | Type | Purpose |
|---------|------|---------|
| `backend` | bridge | Inter-service communication |
| `internal` | internal | Database access — not reachable from host |
| `signing` | internal | MPC operations — isolated from DB and host |

PostgreSQL has no host ports exposed — only dvp-service and outbox-publisher can reach it. MPC nodes are unreachable from anything except the signing gateway.

**View logs:**

```bash
docker compose logs -f dvp-service       # Settlement lifecycle
docker compose logs -f outbox-publisher   # Kafka delivery
docker compose logs -f signing-gateway    # Signing requests
```

**Tear down:**

```bash
docker compose down -v    # Remove containers and volumes
```

### Option B: Local Development (Manual Setup)

For running directly on your machine without Docker.

#### Prerequisites

- Python 3.13+
- PostgreSQL 16+ (running locally — the script auto-creates the `dvp` database)
- Kafka (local or Docker — optional, the script falls back gracefully)

#### 1. Install Dependencies

```bash
python3 -m venv venv
source venv/bin/activate
pip install asyncpg aiokafka aiohttp
```

#### 2. Start Kafka

```bash
docker run -d --name kafka \
  -p 9092:9092 \
  -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://localhost:9092 \
  apache/kafka:latest
```

#### 3. Run the DVP Settlement Service

```bash
python dvp-settlement.py
```

The script automatically:
- Creates the `dvp` database if it does not exist
- Loads the append-only schema from `db/init/` (includes RBAC tables and audit log)
- Seeds demo entities, positions, balances, and RBAC role assignments (idempotent)
- Runs the full BlackRock → State Street settlement lifecycle with RBAC enforcement and audit trails
- Publishes all outbox events to Kafka (falls back gracefully if Kafka is unavailable)

**Output format:** By default, the demo uses colorized terminal output. Set `DVP_LOG_FORMAT=json` for structured JSON logging:

```bash
DVP_LOG_FORMAT=json python dvp-settlement.py
```

#### 4. Run the Outbox Publisher (optional)

If Kafka was not available during step 3, start it and run the standalone publisher to deliver pending events:

```bash
python outbox-publisher.py
```

#### 5. Verify Final State

```sql
-- Settlement summary (uses derived view)
SELECT trade_reference, status, reconciliation_status,
       quantity AS shares_settled,
       settlement_amount AS usd_notional,
       swap_tx_hash, settled_at
FROM dvp_instructions_current;

-- Position verification (derived from ledger)
SELECT entity_id, isin, available_quantity, locked_quantity
FROM custody_balances;

-- Cash verification (derived from ledger)
SELECT entity_id, currency, available_balance, locked_balance
FROM cash_balances;

-- Kafka event trail
SELECT event_type, created_at, delivery_status
FROM outbox_events_current ORDER BY created_at;
```

---

## 📁 Project Structure

```
DVP-PYTHON/
│
├── dvp-settlement.py              # All service classes — full settlement engine
│                                  #   DVPSettlementService (orchestrator)
│                                  #   ComplianceScreeningService
│                                  #   SettlementLegService / EscrowService
│                                  #   MultiSigApprovalService / AtomicSwapExecutor
│                                  #   HybridSettlementGateway (SWIFT/FedWire/CLS)
│                                  #   DVPReconciliationEngine / DVPOutboxPublisher
│                                  #   AuditContext / RBACChecker / DemoFormatter
│                                  #   Abstract interfaces + sandbox stubs
│
├── dvp-settlement.sql             # PostgreSQL schema + BlackRock→State Street demo
│
├── outbox-publisher.py            # Standalone outbox → Kafka publisher
│
├── docker-compose.yaml            # 9-service orchestration with trust domain networks
│
├── pyproject.toml                 # Python dependency manifest
│
├── dvp-service/                   # Containerized DVP settlement service
│   ├── Dockerfile
│   └── dvp-service.py             # Entry point: register → fund → settle
│
├── outbox/                        # Containerized outbox publisher
│   ├── Dockerfile
│   └── outbox-publisher.py        # Env-configured, readonly_user DB access
│
├── signing-gateway/               # HSM/MPC signing gateway
│   ├── Dockerfile
│   └── gateway.py                 # aiohttp — fans out to MPC nodes, 2-of-3
│
├── mpc/                           # MPC threshold signing node
│   ├── Dockerfile
│   └── node.py                    # aiohttp — deterministic partial signatures
│
├── db/
│   └── init/
│       ├── 001-schema.sql         # Full append-only schema + RBAC + audit log
│       └── 002-readonly-user.sql  # Restricted user for outbox publisher
│
├── README.md
└── LICENSE
```

---

## 🚨 Production Warning

**This project is explicitly NOT suitable for production use.** DVP settlement is among the most regulated, operationally complex, and legally sensitive activities in institutional financial services. The following critical components are absent or stubbed:

| Missing Component | Risk if Absent |
|-------------------|----------------|
| Real custodian API integration | Cannot verify actual security positions |
| Licensed settlement network membership | Cannot submit to DTCC / Euroclear / Clearstream |
| Real SWIFT Alliance Gateway / FIN | Cannot send actual MT103/MT543 messages |
| Real FedWire FedLine connection | Cannot initiate actual USD transfers |
| Real CLS membership / CLSNet | Cannot eliminate FX Herstatt risk |
| HSM / MPC key management (Thales / Fireblocks) | Private keys exposed in software |
| Smart contract audit (ERC-1400 / escrow) | Exploitable vulnerabilities in escrow contracts |
| AML / KYC provider integration (ComplyAdvantage) | No actual sanctions screening |
| Securities regulations compliance (SEC Rule 15c6) | Potential regulatory violations |
| Central bank / CCP connectivity | Cannot connect to Fed / ECB settlement systems |
| Production authentication (OAuth / mTLS / API keys) | RBAC is enforced but actors are not authenticated against an identity provider |
| Rate limiting & position limits | No controls on settlement size |
| Comprehensive test suite | Untested edge cases in fund handling |
| Dead-letter queue manual replay tooling | Failed events require developer intervention |
| Disaster recovery procedures | No tested failover for settlement outages |
| Regulatory reporting (MiFID II / EMIR / TRACE) | Post-trade reporting violations |

> DVP settlement at institutional scale requires: licensed broker-dealer or custodian status, CCP membership (DTCC, LCH, Eurex), CSD membership (DTC, Euroclear, Clearstream), SWIFT connectivity, FedWire account, and legal agreements with all counterparties. **Do not use this code to settle, manage, or transfer any real securities or funds.**

---

## 📄 License

This project is provided as-is for educational and reference purposes under the MIT License.

---

*Built with ♥️ by Pavon Dunbar & Modeled on JPMorgan Onyx, DTCC Project Ion, CLS, and Euroclear*
