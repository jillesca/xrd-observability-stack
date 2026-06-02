# Phase 2: Alert Pipeline Cutover

## Prerequisite: Phase 1 complete

Phase 1 must be validated before starting this phase:

- `curl -s http://localhost:9093/-/healthy` returns `OK`
- `curl -s http://localhost:9090/api/v1/rules` shows all 6 alert rule names
- Alertmanager UI at `:9093` is reachable

**This phase makes breaking changes.** After it completes, all alerting goes through
Prometheus → Alertmanager → webhook-receiver. Grafana no longer evaluates alert rules.
If something goes wrong here, no alerts fire until it is fixed.

## Goal

Remove Grafana's alerting provisioning files and environment variables. Verify that
inhibition works correctly (one interface shutdown produces exactly one webhook POST).

## Done when

1. `docker compose ps grafana` is healthy after restart.
2. Grafana Alerting UI (`:3000/alerting`) shows **no alert rules** (the provisioning
   files were removed).
3. Grafana Alerting UI shows Alertmanager alerts imported from the Alertmanager
   datasource (read-only display).
4. Shutting down one interface on any XRd device causes **exactly one** POST to the
   webhook receiver within 60 seconds (verified by checking webhook logs).
5. The webhook receiver log shows the correct `NetworkAlert` payload fields:
   `event_type`, `device`, `affected_object`, `severity`.

## Constraints

- Confirm Phase 1 validation passes before starting.
- After removing the Grafana alerting volume mount, run `make restart-grafana` first
  (not `make restart`) to isolate the change. Verify Grafana starts healthy before
  proceeding to the Prometheus/Alertmanager restart.
- Do not modify `prometheus/rules/xrd-alerts.yaml` in this phase.
- Do not modify `alertmanager/alertmanager.yaml` in this phase.

---

## Step 1: Delete Grafana alerting provisioning files

Delete these three files:

```
grafana/provisioning/alerting/xrd-alert-rules.yaml
grafana/provisioning/alerting/xrd-notification-policy.yaml
grafana/provisioning/alerting/xrd-contact-points.yaml
```

The `grafana/provisioning/alerting/` directory may be left empty or removed entirely.
Grafana will start cleanly with an empty alerting provisioning directory.

---

## Step 2: Edit `compose.yaml` — remove Grafana alerting wiring

In the `grafana` service, make these two changes:

**Remove** the alerting provisioning volume mount:

```yaml
# Remove this line from grafana.volumes:
- ./grafana/provisioning/alerting/:/etc/grafana/provisioning/alerting/:ro
```

**Remove** the webhook receiver URL from Grafana's environment (it is now in
Alertmanager's environment):

```yaml
# Remove this line from grafana.environment:
- WEBHOOK_RECEIVER_URL=${WEBHOOK_RECEIVER_URL:-http://webhook-receiver:8080/alert}
```

No other changes to `compose.yaml`.

---

## Step 3: Restart Grafana only, verify clean start

```bash
make restart-grafana
# or: docker compose restart grafana

# Confirm Grafana is healthy
curl -s http://localhost:3000/api/health | python3 -m json.tool
# Expected: {"commit": "...", "database": "ok", ...}

# Confirm Grafana alerting UI shows no rules
# Open http://localhost:3000/alerting/list — should be empty
```

If Grafana fails to start, check logs:

```bash
docker logs gnp-stack-grafana-1 2>&1 | tail -30
```

Common cause: a remaining reference to `WEBHOOK_RECEIVER_URL` env var in `compose.yaml`.

---

## Step 4: Validate inhibition — single interface shutdown

This is the critical validation. Trigger the primary demo scenario and confirm only
one webhook POST reaches the receiver.

```bash
# 1. Watch webhook-receiver logs in one terminal
docker logs -f gnp-stack-webhook-receiver-1

# 2. In another terminal, shut one interface on xrd-1
ssh cisco@10.10.20.101 "conf t
interface GigabitEthernet0/0/0/0
shutdown
commit
end"

# 3. Wait up to 60 seconds

# 4. Count POSTs received — should be exactly 1 for the interface down event
# (ISIS adjacency alert should be inhibited by Alertmanager)
```

Expected webhook receiver log output (one POST only):

```
INFO Received webhook: status=firing
INFO Parsed alert: name='XRdInterfaceDown' device='xrd-1' object='GigabitEthernet0/0/0/0'
```

If two POSTs arrive within 30 seconds (one for interface, one for ISIS), inhibition
is not working. Check:

```bash
# Show active inhibitions in Alertmanager
curl -s http://localhost:9093/api/v2/alerts | python3 -m json.tool | grep inhibited

# Show Alertmanager inhibition config
curl -s http://localhost:9093/api/v2/status | python3 -m json.tool | grep -A10 inhibit
```

Common cause: the `source` label name in the Prometheus rules does not match the
label name the inhibition rule references. Check the actual labels on a firing alert:

```bash
curl -s http://localhost:9090/api/v1/alerts | python3 -m json.tool | grep -A20 '"labels"'
```

If the device label is called `target` instead of `source`, update `equal: [source]`
in `alertmanager/alertmanager.yaml` to `equal: [target]` and restart Alertmanager.

---

## Step 5: Restore the interface

```bash
ssh cisco@10.10.20.101 "conf t
interface GigabitEthernet0/0/0/0
no shutdown
commit
end"
```

Confirm the webhook receiver receives a `status=resolved` POST within 60 seconds.

---

## Step 6: Validate webhook payload

Send a synthetic test POST directly to the webhook receiver to confirm the
`NetworkAlert` schema is populated correctly from an Alertmanager payload:

```bash
curl -s -X POST http://localhost:8080/alert \
  -H 'Content-Type: application/json' \
  -d '{
    "version": "4",
    "groupKey": "{}:{source=\"xrd-1\",event_type=\"interface_state\"}",
    "status": "firing",
    "receiver": "sp_oncall_webhook",
    "groupLabels": {"source": "xrd-1", "event_type": "interface_state"},
    "commonLabels": {"severity": "critical"},
    "commonAnnotations": {},
    "externalURL": "http://alertmanager:9093",
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "XRdInterfaceDown",
        "severity": "critical",
        "event_type": "interface_state",
        "affected_object_type": "interface",
        "source": "xrd-1",
        "name": "GigabitEthernet0/0/0/0"
      },
      "annotations": {
        "summary": "Interface GigabitEthernet0/0/0/0 on xrd-1 is DOWN",
        "description": "Interface GigabitEthernet0/0/0/0 on xrd-1 is operationally DOWN"
      },
      "startsAt": "2026-05-22T10:00:00Z",
      "endsAt": "0001-01-01T00:00:00Z",
      "fingerprint": "abc123"
    }]
  }'
```

Expected response: `{"status": "accepted"}` (HTTP 202)

Expected webhook receiver log:

```
INFO Received webhook: status=firing
INFO Parsed alert: name='XRdInterfaceDown' device='xrd-1' object='GigabitEthernet0/0/0/0'
```

If `device` is `unknown` in the log, the `source` label is not being read correctly.
Check `parse_grafana_webhook` in `webhook/schema.py` — the function reads
`labels.target or labels.source`. Alertmanager sends `source`; Grafana sends `target`.
If only `target` is read, add `labels.source` to the fallback chain:

```python
device = labels.target or labels.source or labels.hostname or "unknown"
```

This is a one-line change in the `parse_grafana_webhook` function.
