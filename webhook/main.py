"""
FastAPI webhook receiver for Grafana → sp_oncall alert forwarding.

Endpoint: POST /alert
  - Validates the Grafana webhook payload
  - Transforms it into a NetworkAlert (canonical schema)
  - Fires a background LangGraph run in sp_oncall
  - Returns {"status": "accepted"} immediately (fire-and-forget)

Endpoint: GET /health
  - Returns {"status": "ok"} for compose healthchecks and readiness probes

TODO (future): Handle "resolved" status alerts as a confirmation signal to
sp_oncall that the network has recovered, allowing agents to append a
resolution note to the active investigation thread rather than ignoring it.
"""

from __future__ import annotations

import logging
import os

from fastapi import FastAPI, Request, status
from fastapi.responses import JSONResponse

from langgraph_client import trigger_investigation
from schema import GrafanaWebhook, parse_grafana_webhook

logging.basicConfig(
    level=os.getenv(key="LOG_LEVEL", default="INFO"),
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="XRd Webhook Receiver",
    description="Translates Grafana alert webhooks into sp_oncall investigations.",
    version="0.1.0",
)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/alert", status_code=status.HTTP_202_ACCEPTED)
async def receive_alert(request: Request) -> JSONResponse:
    """Accept a Grafana webhook and trigger an sp_oncall investigation.

    Always returns 202 so Grafana does not retry on transient errors.
    Errors in LangGraph communication are logged but never surfaced to Grafana.
    """
    body_raw = await request.json()
    logger.info(
        "Received webhook: status=%s", body_raw.get("status", "unknown")
    )
    logger.debug("Webhook body: %s", body_raw)

    webhook = GrafanaWebhook.model_validate(body_raw)

    if webhook.status == "resolved":
        # TODO (future): send a recovery confirmation to the active sp_oncall
        # thread so agents can append a resolution note without re-running
        # the full investigation.
        logger.info("Alert resolved — no action taken (see TODO in main.py)")
        return JSONResponse(
            {"status": "accepted", "action": "ignored_resolved"}
        )

    alert = parse_grafana_webhook(body=webhook)
    if alert is None:
        logger.warning("Webhook dropped: not firing or no alerts present")
        return JSONResponse({"status": "accepted", "action": "ignored"})

    logger.info(
        "Parsed alert: name=%r device=%r object=%r",
        alert.alert_name,
        alert.device,
        alert.affected_object,
    )

    await trigger_investigation(alert)

    return JSONResponse({"status": "accepted"})
