"""
HSM/MPC Signing Gateway.

Fans out signing requests to MPC threshold nodes and combines
partial signatures. Requires threshold (default 2-of-3) partial
signatures for a valid combined signature.

Production: Replace with Fireblocks MPC, AWS CloudHSM, or
Thales Luna HSM integration.
"""

import asyncio
import hashlib
import json
import logging
import os
import uuid

from aiohttp import ClientSession, web


class StructuredFormatter(logging.Formatter):
    """JSON log formatter with optional request_id/trace_id."""

    def format(self, record):
        entry = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if hasattr(record, "request_id"):
            entry["request_id"] = record.request_id
        if hasattr(record, "trace_id"):
            entry["trace_id"] = record.trace_id
        return json.dumps(entry)


handler = logging.StreamHandler()
handler.setFormatter(StructuredFormatter())
logger = logging.getLogger("dvp.signing_gateway")
logger.setLevel(logging.INFO)
logger.addHandler(handler)
logger.propagate = False

PORT = int(os.getenv("PORT", "8000"))
MPC_NODES = os.getenv("MPC_NODES", "").split(",")
THRESHOLD = int(os.getenv("THRESHOLD", "2"))


async def handle_sign(request: web.Request) -> web.Response:
    """
    POST /sign
    Body: {"instruction_id": "...", "payload": {...}}

    Fans out to all MPC nodes, collects partial signatures,
    combines if threshold is met.
    """
    request_id = request.headers.get(
        "X-Request-ID", str(uuid.uuid4()),
    )
    trace_id = request.headers.get(
        "X-Trace-ID", str(uuid.uuid4()),
    )
    extra = {"request_id": request_id, "trace_id": trace_id}

    body = await request.json()
    instruction_id = body.get("instruction_id", "unknown")
    payload = body.get("payload", {})

    logger.info(
        "Signing request for instruction %s — "
        "threshold=%d nodes=%d",
        instruction_id, THRESHOLD, len(MPC_NODES),
        extra=extra,
    )

    partial_sigs = []
    async with ClientSession() as session:
        tasks = []
        for node_url in MPC_NODES:
            node_url = node_url.strip()
            if not node_url:
                continue
            url = f"http://{node_url}/partial-sign"
            tasks.append(
                _request_partial(
                    session, url, instruction_id, payload,
                    request_id, trace_id,
                )
            )

        results = await asyncio.gather(
            *tasks, return_exceptions=True,
        )
        for result in results:
            if isinstance(result, str):
                partial_sigs.append(result)
            else:
                logger.warning(
                    "MPC node error: %s", result,
                    extra=extra,
                )

    if len(partial_sigs) < THRESHOLD:
        logger.error(
            "Threshold not met — got %d/%d partials",
            len(partial_sigs), THRESHOLD,
            extra=extra,
        )
        return web.json_response(
            {
                "error": "threshold_not_met",
                "received": len(partial_sigs),
                "required": THRESHOLD,
                "request_id": request_id,
                "trace_id": trace_id,
            },
            status=503,
        )

    combined = _combine_signatures(
        partial_sigs[:THRESHOLD],
    )
    logger.info(
        "Signing complete for %s — combined=%s",
        instruction_id, combined[:32],
        extra=extra,
    )

    return web.json_response({
        "instruction_id": instruction_id,
        "signature": combined,
        "threshold": THRESHOLD,
        "partials_received": len(partial_sigs),
        "request_id": request_id,
        "trace_id": trace_id,
    })


async def _request_partial(
    session: ClientSession,
    url: str,
    instruction_id: str,
    payload: dict,
    request_id: str,
    trace_id: str,
) -> str:
    async with session.post(
        url,
        json={
            "instruction_id": instruction_id,
            "payload": payload,
        },
        headers={
            "X-Request-ID": request_id,
            "X-Trace-ID": trace_id,
        },
        timeout=5,
    ) as resp:
        data = await resp.json()
        return data["partial_signature"]


def _combine_signatures(partials: list[str]) -> str:
    """
    Stub combiner: hashes concatenated partials.
    Production: actual MPC threshold combination
    (e.g., Shamir secret sharing recombination).
    """
    combined_input = "|".join(sorted(partials))
    return hashlib.sha256(combined_input.encode()).hexdigest()


async def handle_health(request: web.Request) -> web.Response:
    return web.json_response({
        "status": "healthy",
        "service": "signing-gateway",
        "threshold": THRESHOLD,
        "mpc_nodes": len(MPC_NODES),
    })


def main():
    app = web.Application()
    app.router.add_post("/sign", handle_sign)
    app.router.add_get("/health", handle_health)

    logger.info(
        "Signing gateway starting on port %d — "
        "threshold=%d nodes=%s",
        PORT, THRESHOLD, MPC_NODES,
    )
    web.run_app(app, host="0.0.0.0", port=PORT)


if __name__ == "__main__":
    main()
