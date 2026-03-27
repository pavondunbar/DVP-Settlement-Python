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

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger("dvp.mpc_node")

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
    body = await request.json()
    instruction_id = body.get("instruction_id", "unknown")
    payload = body.get("payload", {})

    canonical = json.dumps(payload, sort_keys=True)
    sig_input = f"{NODE_ID}:{canonical}"
    partial_sig = hashlib.sha256(sig_input.encode()).hexdigest()

    logger.info(
        "Partial sign — node=%s instruction=%s sig=%s",
        NODE_ID, instruction_id, partial_sig[:16],
    )

    return web.json_response({
        "node_id": NODE_ID,
        "instruction_id": instruction_id,
        "partial_signature": partial_sig,
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
