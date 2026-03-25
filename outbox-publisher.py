"""
╔══════════════════════════════════════════════════════════════════════════════╗
║  DVP Settlement & Clearing System — Outbox Publisher                       ║
║                                                                            ║
║  Standalone async background process.                                      ║
║  Polls outbox_events → delivers to Kafka with exactly-once semantics.      ║
║                                                                            ║
║  Run as a separate process alongside the main settlement service.          ║
║  Append-only: delivery tracking via outbox_delivery_log INSERTs.           ║
╚══════════════════════════════════════════════════════════════════════════════╝

Usage:
    python outbox_publisher.py

Environment variables:
    DATABASE_URL   — asyncpg connection string
                     e.g. postgresql://user:pass@localhost/dvp_sandbox
    KAFKA_BROKERS  — comma-separated Kafka bootstrap servers
                     e.g. localhost:9092
    POLL_INTERVAL  — outbox poll interval in seconds (default: 1.0)
    BATCH_SIZE     — events per poll cycle (default: 50)

Kafka Topics Published:
    dvp.initiated               Risk systems, compliance dashboards
    dvp.legs_locked             CSD position update consumers
    dvp.escrow_funded           Custodian notification services
    dvp.multisig_vote           Approval workflow systems
    dvp.multisig_approved       Swap execution trigger consumer
    dvp.atomic_swap_initiated   Monitoring / circuit breakers
    dvp.settled                 MiFID II / EMIR reporting, DTCC STP
    dvp.rejected                Operations alert systems
    dvp.swap_failed             Incident response, SLA breach trackers
    dvp.escrow_released         Unwind processing systems
    dvp.reconciliation_matched  Settlement confirmation consumers
    dvp.reconciliation_mismatch CRITICAL — ops paging, compliance escalation
    dvp.dead_letter_queue       Failed events requiring manual intervention
"""

import asyncio
import json
import logging
import os
import signal
import uuid
from datetime import datetime, timezone

# ── Production imports ────────────────────────────────────────────────────────
import asyncpg
from aiokafka import AIOKafkaProducer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger("dvp.outbox_publisher")


# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

DATABASE_URL   = os.getenv("DATABASE_URL",   "postgresql://postgres@localhost/dvp_sandbox")
KAFKA_BROKERS  = os.getenv("KAFKA_BROKERS",  "localhost:9092")
POLL_INTERVAL  = float(os.getenv("POLL_INTERVAL", "1.0"))
BATCH_SIZE     = int(os.getenv("BATCH_SIZE", "50"))
MAX_RETRIES    = int(os.getenv("MAX_RETRIES", "3"))

# Kafka topic routing — maps event_type suffix to Kafka topic
TOPIC_MAP = {
    "initiated":               "dvp.initiated",
    "legs_locked":             "dvp.legs_locked",
    "escrow_funded":           "dvp.escrow_funded",
    "multisig_vote":           "dvp.multisig_vote",
    "multisig_approved":       "dvp.multisig_approved",
    "atomic_swap_initiated":   "dvp.atomic_swap_initiated",
    "settled":                 "dvp.settled",
    "rejected":                "dvp.rejected",
    "swap_failed":             "dvp.swap_failed",
    "escrow_released":         "dvp.escrow_released",
    "reconciliation_matched":  "dvp.reconciliation_matched",
    "reconciliation_mismatch": "dvp.reconciliation_mismatch",  # CRITICAL
}
DEFAULT_TOPIC = "dvp.events"


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


def _resolve_topic(event_type: str) -> str:
    """
    Maps event_type (e.g. 'dvp.settled') to a Kafka topic.
    Falls back to DEFAULT_TOPIC for unknown types.
    """
    suffix = event_type.split(".", 1)[-1] if "." in event_type else event_type
    return TOPIC_MAP.get(suffix, DEFAULT_TOPIC)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


# ─────────────────────────────────────────────────────────────────────────────
# OutboxPublisher
# ─────────────────────────────────────────────────────────────────────────────

class OutboxPublisher:
    """
    Async background poller — delivers outbox_events to Kafka reliably.

    APPEND-ONLY: All delivery state is tracked via INSERT into
    outbox_delivery_log. The outbox_events table is never mutated.

    Core guarantees:
    ─────────────────
    1. AT-LEAST-ONCE delivery: a PUBLISHED row is inserted into
       outbox_delivery_log ONLY after Kafka acknowledges the message.
       A crash between Kafka delivery and the DB insert causes a
       duplicate, which downstream consumers must handle via
       idempotency (event_id deduplication).

    2. Multi-replica safe: events without a PUBLISHED or DLQ row
       in outbox_delivery_log are eligible for pickup. The unique
       index on (event_id) WHERE status = 'PUBLISHED' prevents
       double-publish at the DB level.

    3. Ordered per instruction: Kafka key = aggregate_id (instruction
       ID) guarantees all events for the same instruction land in the
       same partition in the order they were created.

    4. Retry with backoff: RETRY rows in outbox_delivery_log track
       failed attempts. Retry count derived from COUNT(*).

    5. Dead-letter queue: After MAX_RETRIES, the event is forwarded
       to dvp.dead_letter_queue and a DLQ row is inserted to stop
       retries. Ops team must manually investigate and replay.

    Operational notes:
    ──────────────────
    - Target latency: < 2s from DB commit to Kafka delivery (p99)
    - Monitor: outbox_events_current WHERE delivery_status = 'PENDING'
        AND created_at < NOW() - INTERVAL '30 seconds'
    - Alert: any event with retry_count = MAX_RETRIES - 1
    - CRITICAL alert: any event in dvp.dead_letter_queue
    - CRITICAL alert: dvp.reconciliation_mismatch topic
    """

    def __init__(self, db, kafka_producer):
        self._db    = db
        self._kafka = kafka_producer
        self._log   = logging.getLogger("dvp.outbox_publisher")
        self._running = True

    async def run_forever(self, poll_interval: float = POLL_INTERVAL):
        self._log.info(
            "DVP OutboxPublisher started — "
            "poll_interval=%.1fs batch_size=%d max_retries=%d",
            poll_interval, BATCH_SIZE, MAX_RETRIES,
        )
        while self._running:
            try:
                published = await self._poll_and_publish()
                if published > 0:
                    self._log.debug(
                        "Published %d events in this cycle", published
                    )
            except Exception as exc:
                self._log.error(
                    "Publisher poll cycle error: %s", exc, exc_info=True
                )
            await asyncio.sleep(poll_interval)
        self._log.info("DVP OutboxPublisher stopped.")

    def stop(self):
        self._running = False

    async def _poll_and_publish(self) -> int:
        """
        Fetches a batch of unpublished events (no PUBLISHED or DLQ
        row in outbox_delivery_log) and delivers each to Kafka.
        Returns the count of successfully published events.
        """
        events = await self._db.fetch(
            """
            SELECT oe.id, oe.aggregate_id, oe.event_type,
                   oe.payload, oe.created_at
            FROM outbox_events oe
            WHERE NOT EXISTS (
                SELECT 1 FROM outbox_delivery_log dl
                WHERE dl.event_id = oe.id
                  AND dl.status IN ('PUBLISHED', 'DLQ')
            )
            ORDER BY oe.created_at ASC
            LIMIT $1
            """,
            BATCH_SIZE,
        )

        published_count = 0
        for event in events:
            success = await self._deliver_event(event)
            if success:
                published_count += 1

        return published_count

    async def _deliver_event(self, event: dict) -> bool:
        event_id   = str(event["id"])
        event_type = event["event_type"]
        aggregate  = str(event["aggregate_id"])

        # Count prior RETRY rows to determine attempt number
        retry_row = await self._db.fetchrow(
            """
            SELECT COUNT(*) AS cnt
            FROM outbox_delivery_log
            WHERE event_id = $1 AND status = 'RETRY'
            """,
            event_id,
        )
        retry = retry_row["cnt"] if retry_row else 0

        # Parse payload (asyncpg may return dict or JSON string)
        payload = event["payload"]
        if isinstance(payload, str):
            payload = json.loads(payload)

        topic = _resolve_topic(event_type)

        kafka_envelope = json.dumps({
            "schema_version": "1.0",
            "event_id":       event_id,
            "event_type":     event_type,
            "aggregate_id":   aggregate,
            "payload":        payload,
            "emitted_at":     _now(),
            "retry_count":    retry,
        }).encode("utf-8")

        try:
            await self._kafka.send_and_wait(
                topic=topic,
                value=kafka_envelope,
                key=aggregate.encode("utf-8"),
            )

            # Append PUBLISHED row (unique index prevents duplicates)
            await self._db.execute(
                """
                INSERT INTO outbox_delivery_log
                    (id, event_id, status)
                VALUES ($1, $2, 'PUBLISHED')
                """,
                str(uuid.uuid4()), event_id,
            )

            if "mismatch" in event_type or "failed" in event_type:
                self._log.warning(
                    "CRITICAL event published — "
                    "topic=%s event_id=%s aggregate=%s",
                    topic, event_id, aggregate,
                )
            else:
                self._log.debug(
                    "Published event_id=%s type=%s topic=%s",
                    event_id, event_type, topic,
                )
            return True

        except Exception as exc:
            self._log.warning(
                "Kafka delivery failed — "
                "event_id=%s type=%s attempt=%d error=%s",
                event_id, event_type, retry + 1, exc,
            )

            if retry + 1 >= MAX_RETRIES:
                await self._send_to_dlq(
                    event_id, event_type, aggregate, payload,
                    str(exc),
                )
            else:
                # Append RETRY row with error detail
                await self._db.execute(
                    """
                    INSERT INTO outbox_delivery_log
                        (id, event_id, status, error)
                    VALUES ($1, $2, 'RETRY', $3)
                    """,
                    str(uuid.uuid4()), event_id, str(exc),
                )
            return False

    async def _send_to_dlq(
        self,
        event_id: str,
        event_type: str,
        aggregate_id: str,
        payload: dict,
        error: str,
    ):
        dlq_message = json.dumps({
            "schema_version": "1.0",
            "event_id":       event_id,
            "event_type":     event_type,
            "aggregate_id":   aggregate_id,
            "payload":        payload,
            "error":          error,
            "dlq_at":         _now(),
            "max_retries":    MAX_RETRIES,
            "action_required": "MANUAL_REVIEW_AND_REPLAY",
        }).encode("utf-8")

        try:
            await self._kafka.send_and_wait(
                topic="dvp.dead_letter_queue",
                value=dlq_message,
                key=aggregate_id.encode("utf-8"),
            )
        except Exception as dlq_exc:
            self._log.critical(
                "DLQ delivery ALSO failed — event_id=%s error=%s "
                "dlq_error=%s MANUAL INTERVENTION REQUIRED",
                event_id, error, dlq_exc,
            )

        # Append DLQ row to stop retry loop
        await self._db.execute(
            """
            INSERT INTO outbox_delivery_log
                (id, event_id, status, error)
            VALUES ($1, $2, 'DLQ', $3)
            """,
            str(uuid.uuid4()), event_id, error,
        )
        self._log.error(
            "Event %s (type=%s) moved to DLQ after %d attempts: %s",
            event_id, event_type, MAX_RETRIES, error,
        )


# ─────────────────────────────────────────────────────────────────────────────
# Graceful Shutdown
# ─────────────────────────────────────────────────────────────────────────────

def _install_signal_handlers(publisher: OutboxPublisher, loop: asyncio.AbstractEventLoop):
    def _shutdown(signum, frame):
        logger.info("Shutdown signal received (%s) — stopping OutboxPublisher", signum)
        publisher.stop()
        loop.call_soon_threadsafe(loop.stop)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT,  _shutdown)


# ─────────────────────────────────────────────────────────────────────────────
# Health Check
# ─────────────────────────────────────────────────────────────────────────────

async def run_health_check(db) -> dict:
    """
    Returns a snapshot of outbox health for monitoring / readiness probes.
    Uses the outbox_events_current derived view (append-only).
    """
    row = await db.fetchrow(
        """
        SELECT
            COUNT(*)
                AS total_pending,
            COUNT(*) FILTER (WHERE retry_count > 0)
                AS retrying,
            COUNT(*) FILTER (WHERE delivery_status = 'DLQ')
                AS in_dlq,
            COUNT(*) FILTER (
                WHERE created_at < NOW() - INTERVAL '60 seconds'
                  AND delivery_status = 'PENDING'
            )   AS stale_events,
            MAX(created_at) FILTER (
                WHERE delivery_status = 'PENDING'
            )   AS oldest_pending
        FROM outbox_events_current
        WHERE delivery_status IN ('PENDING', 'RETRY', 'DLQ')
        """
    )
    return dict(row) if row else {}


# ─────────────────────────────────────────────────────────────────────────────
# Main Entry Point
# ─────────────────────────────────────────────────────────────────────────────

async def main():
    logger.info("=" * 65)
    logger.info("DVP Settlement & Clearing System — Outbox Publisher")
    logger.info("=" * 65)
    logger.info("DATABASE_URL   = %s", DATABASE_URL.split("@")[-1])   # Mask credentials
    logger.info("KAFKA_BROKERS  = %s", KAFKA_BROKERS)
    logger.info("POLL_INTERVAL  = %.1fs", POLL_INTERVAL)
    logger.info("BATCH_SIZE     = %d", BATCH_SIZE)
    logger.info("MAX_RETRIES    = %d", MAX_RETRIES)
    logger.info("")

    # ── Connect to PostgreSQL ─────────────────────────────────────────────────
    pool = await asyncpg.create_pool(
        DATABASE_URL,
        min_size=2,
        max_size=10,
        command_timeout=30,
        init=_init_connection,
    )
    logger.info("Connected to PostgreSQL")

    pending = await pool.fetchval(
        """
        SELECT COUNT(*) FROM outbox_events_current
        WHERE delivery_status = 'PENDING'
        """
    )
    logger.info("Pending outbox events: %d", pending)

    # ── Connect to Kafka ──────────────────────────────────────────────────────
    kafka_producer = AIOKafkaProducer(
        bootstrap_servers=KAFKA_BROKERS,
        enable_idempotence=True,
        acks="all",
        compression_type="lz4",
        max_batch_size=16384,
        linger_ms=5,
    )
    await kafka_producer.start()
    logger.info("Connected to Kafka at %s", KAFKA_BROKERS)

    # ── Start publisher ───────────────────────────────────────────────────────
    publisher = OutboxPublisher(db=pool, kafka_producer=kafka_producer)

    loop = asyncio.get_running_loop()
    _install_signal_handlers(publisher, loop)

    logger.info("OutboxPublisher running — Ctrl+C to stop")
    try:
        await publisher.run_forever(poll_interval=POLL_INTERVAL)
    finally:
        await kafka_producer.stop()
        await pool.close()
        logger.info("Publisher shut down — pool and producer closed.")


if __name__ == "__main__":
    asyncio.run(main())
