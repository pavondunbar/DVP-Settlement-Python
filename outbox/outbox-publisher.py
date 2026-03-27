"""
Containerized Outbox Publisher.

Polls outbox_events and delivers to Kafka with at-least-once semantics.
Uses readonly_user for least-privilege database access.
"""

import asyncio
import json
import logging
import os
import signal
import uuid
from datetime import datetime, timezone

import asyncpg
from aiokafka import AIOKafkaProducer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger("dvp.outbox_publisher")


# -------------------------------------------------------------------------
# Configuration from environment
# -------------------------------------------------------------------------

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "dvp_settlement")
DB_USER = os.getenv("DB_USER", "readonly_user")
DB_PASSWORD = os.getenv("DB_PASSWORD", "readonly_pass")
KAFKA_BROKER = os.getenv("KAFKA_BROKER", "localhost:9092")
POLL_INTERVAL = float(os.getenv("POLL_INTERVAL", "1.0"))
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "50"))
MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))


def _dsn() -> str:
    return (
        f"postgresql://{DB_USER}:{DB_PASSWORD}"
        f"@{DB_HOST}:{DB_PORT}/{DB_NAME}"
    )


TOPIC_MAP = {
    "initiated": "dvp.initiated",
    "legs_locked": "dvp.legs_locked",
    "escrow_funded": "dvp.escrow_funded",
    "multisig_vote": "dvp.multisig_vote",
    "multisig_approved": "dvp.multisig_approved",
    "atomic_swap_initiated": "dvp.atomic_swap_initiated",
    "settled": "dvp.settled",
    "rejected": "dvp.rejected",
    "swap_failed": "dvp.swap_failed",
    "escrow_released": "dvp.escrow_released",
    "reconciliation_matched": "dvp.reconciliation_matched",
    "reconciliation_mismatch": "dvp.reconciliation_mismatch",
}
DEFAULT_TOPIC = "dvp.events"


async def _init_connection(conn):
    for typename in ('uuid', 'timestamptz', 'timestamp', 'date'):
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


def _resolve_topic(event_type: str) -> str:
    suffix = (
        event_type.split(".", 1)[-1]
        if "." in event_type
        else event_type
    )
    return TOPIC_MAP.get(suffix, DEFAULT_TOPIC)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class OutboxPublisher:
    def __init__(self, db, kafka_producer):
        self._db = db
        self._kafka = kafka_producer
        self._log = logging.getLogger("dvp.outbox_publisher")
        self._running = True

    async def run_forever(
        self, poll_interval: float = POLL_INTERVAL,
    ):
        self._log.info(
            "OutboxPublisher started — "
            "poll_interval=%.1fs batch_size=%d max_retries=%d",
            poll_interval, BATCH_SIZE, MAX_RETRIES,
        )
        while self._running:
            try:
                published = await self._poll_and_publish()
                if published > 0:
                    self._log.info(
                        "Published %d events", published,
                    )
            except Exception as exc:
                self._log.error(
                    "Poll cycle error: %s", exc, exc_info=True,
                )
            await asyncio.sleep(poll_interval)
        self._log.info("OutboxPublisher stopped.")

    def stop(self):
        self._running = False

    async def _poll_and_publish(self) -> int:
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
            if await self._deliver_event(event):
                published_count += 1
        return published_count

    async def _deliver_event(self, event: dict) -> bool:
        event_id = str(event["id"])
        event_type = event["event_type"]
        aggregate = str(event["aggregate_id"])

        retry_row = await self._db.fetchrow(
            "SELECT COUNT(*) AS cnt "
            "FROM outbox_delivery_log "
            "WHERE event_id = $1 AND status = 'RETRY'",
            event_id,
        )
        retry = retry_row["cnt"] if retry_row else 0

        payload = event["payload"]
        if isinstance(payload, str):
            payload = json.loads(payload)

        topic = _resolve_topic(event_type)
        envelope = json.dumps({
            "schema_version": "1.0",
            "event_id": event_id,
            "event_type": event_type,
            "aggregate_id": aggregate,
            "payload": payload,
            "emitted_at": _now(),
            "retry_count": retry,
        }).encode("utf-8")

        try:
            await self._kafka.send_and_wait(
                topic=topic,
                value=envelope,
                key=aggregate.encode("utf-8"),
            )
            await self._db.execute(
                "INSERT INTO outbox_delivery_log "
                "(id, event_id, status) "
                "VALUES ($1, $2, 'PUBLISHED')",
                str(uuid.uuid4()), event_id,
            )
            self._log.debug(
                "Published event_id=%s topic=%s",
                event_id, topic,
            )
            return True

        except Exception as exc:
            self._log.warning(
                "Kafka delivery failed — "
                "event_id=%s attempt=%d error=%s",
                event_id, retry + 1, exc,
            )
            if retry + 1 >= MAX_RETRIES:
                await self._send_to_dlq(
                    event_id, event_type, aggregate,
                    payload, str(exc),
                )
            else:
                await self._db.execute(
                    "INSERT INTO outbox_delivery_log "
                    "(id, event_id, status, error) "
                    "VALUES ($1, $2, 'RETRY', $3)",
                    str(uuid.uuid4()), event_id, str(exc),
                )
            return False

    async def _send_to_dlq(
        self, event_id, event_type, aggregate_id,
        payload, error,
    ):
        dlq_msg = json.dumps({
            "schema_version": "1.0",
            "event_id": event_id,
            "event_type": event_type,
            "aggregate_id": aggregate_id,
            "payload": payload,
            "error": error,
            "dlq_at": _now(),
            "max_retries": MAX_RETRIES,
        }).encode("utf-8")
        try:
            await self._kafka.send_and_wait(
                topic="dvp.dead_letter_queue",
                value=dlq_msg,
                key=aggregate_id.encode("utf-8"),
            )
        except Exception as dlq_exc:
            self._log.critical(
                "DLQ delivery ALSO failed — event_id=%s "
                "dlq_error=%s",
                event_id, dlq_exc,
            )
        await self._db.execute(
            "INSERT INTO outbox_delivery_log "
            "(id, event_id, status, error) "
            "VALUES ($1, $2, 'DLQ', $3)",
            str(uuid.uuid4()), event_id, error,
        )
        self._log.error(
            "Event %s moved to DLQ after %d attempts: %s",
            event_id, MAX_RETRIES, error,
        )


def _install_signal_handlers(publisher, loop):
    def _shutdown(signum, frame):
        logger.info("Shutdown signal received (%s)", signum)
        publisher.stop()
        loop.call_soon_threadsafe(loop.stop)
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)


async def main():
    logger.info("=" * 60)
    logger.info(
        "DVP Outbox Publisher — Containerized"
    )
    logger.info("=" * 60)
    logger.info(
        "DB=%s@%s:%s/%s KAFKA=%s",
        DB_USER, DB_HOST, DB_PORT, DB_NAME, KAFKA_BROKER,
    )

    pool = await asyncpg.create_pool(
        _dsn(), min_size=2, max_size=10,
        command_timeout=30, init=_init_connection,
    )
    logger.info("Connected to PostgreSQL")

    pending = await pool.fetchval(
        "SELECT COUNT(*) FROM outbox_events_current "
        "WHERE delivery_status = 'PENDING'"
    )
    logger.info("Pending outbox events: %d", pending)

    kafka_producer = AIOKafkaProducer(
        bootstrap_servers=KAFKA_BROKER,
        enable_idempotence=True,
        acks="all",
        compression_type="lz4",
        max_batch_size=16384,
        linger_ms=5,
    )
    await kafka_producer.start()
    logger.info("Connected to Kafka at %s", KAFKA_BROKER)

    publisher = OutboxPublisher(
        db=pool, kafka_producer=kafka_producer,
    )
    loop = asyncio.get_running_loop()
    _install_signal_handlers(publisher, loop)

    logger.info("OutboxPublisher running — Ctrl+C to stop")
    try:
        await publisher.run_forever(
            poll_interval=POLL_INTERVAL,
        )
    finally:
        await kafka_producer.stop()
        await pool.close()
        logger.info("Shut down — pool and producer closed.")


if __name__ == "__main__":
    asyncio.run(main())
