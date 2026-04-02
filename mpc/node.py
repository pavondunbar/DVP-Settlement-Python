"""
MPC Threshold Signing Node.

Produces deterministic stub partial signatures (sha256 of
node_id + payload). Each node holds a share of the signing key.

Production: Replace with actual MPC protocol implementation
(e.g., GG20, CGGMP) or HSM-backed key share.
"""

import hashlib
import json
import logging
import os

from aiohttp import web


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
logger = logging.getLogger("dvp.mpc_node")
logger.setLevel(logging.INFO)
logger.addHandler(handler)
logger.propagate = False

NODE_ID = os.getenv("NODE_ID", "node-unknown")
PORT = int(os.getenv("PORT", "8001"))


async def handle_partial_sign(
    request: web.Request,
) -> web.Response:
    """
    POST /partial-sign
    Body: {"instruction_id": "...", "payload": {...}}

    Returns a deterministic partial signature based on
    NODE_ID and the canonical payload.
    """
    request_id = request.headers.get("X-Request-ID", "")
    trace_id = request.headers.get("X-Trace-ID", "")
    extra = {"request_id": request_id, "trace_id": trace_id}

    body = await request.json()
    instruction_id = body.get("instruction_id", "unknown")
    payload = body.get("payload", {})

    canonical = json.dumps(payload, sort_keys=True)
    sig_input = f"{NODE_ID}:{canonical}"
    partial_sig = hashlib.sha256(
        sig_input.encode(),
    ).hexdigest()

    logger.info(
        "Partial sign — node=%s instruction=%s sig=%s",
        NODE_ID, instruction_id, partial_sig[:16],
        extra=extra,
    )

    return web.json_response({
        "node_id": NODE_ID,
        "instruction_id": instruction_id,
        "partial_signature": partial_sig,
        "request_id": request_id,
        "trace_id": trace_id,
    })


async def handle_health(request: web.Request) -> web.Response:
    return web.json_response({
        "status": "healthy",
        "service": "mpc-node",
        "node_id": NODE_ID,
    })


def main():
    app = web.Application()
    app.router.add_post(
        "/partial-sign", handle_partial_sign,
    )
    app.router.add_get("/health", handle_health)

    logger.info(
        "MPC node %s starting on port %d",
        NODE_ID, PORT,
    )
    web.run_app(app, host="0.0.0.0", port=PORT)


if __name__ == "__main__":
    main()
