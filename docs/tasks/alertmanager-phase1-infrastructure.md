# Phase 1: Alertmanager Infrastructure

## Goal

Add Alertmanager and Prometheus alerting rules to the stack **without touching the
existing Grafana alerting**. Both systems run in parallel after this phase. Grafana
alerting remains the active pipeline until Phase 2 cuts over.

This means the stack is safe to restart at any point — if something goes wrong,
Grafana's existing alerts continue working as a fallback.

## Done when

1. `docker compose ps` shows `alertmanager` running and healthy.
2. `curl -s http://localhost:9093/-/healthy` returns `OK`.
3. `curl -s http://localhost:9090/api/v1/rules | python3 -m json.tool | grep '"name"'`
   shows all six alert rule names from `prometheus/rules/xrd-alerts.yaml`.
4. `curl -s http://localhost:9090/api/v1/alerts | python3 -m json.tool` shows
   `XRdInterfaceDown` firing when at least one XRd interface is down, OR returns an
   empty list when all interfaces are up (both are correct — the rule loaded).
5. Grafana Alerting UI (`:3000/alerting`) still shows existing alerts from the Grafana
   provisioning files — the old pipeline is untouched.

## Constraints

- **Do not modify** `grafana/provisioning/alerting/` in this phase. That directory is
  removed in Phase 2.
- **Do not remove** `WEBHOOK_RECEIVER_URL` from Grafana's environment in `compose.yaml`
  in this phase. That happens in Phase 2.
- All Prometheus metric names must be verified before creating alert rules. Run:

  ```bash
  curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
    | python3 -m json.tool | grep -i '<keyword>'
  ```

  If a metric name does not exist, add `# [UNVERIFIED]` to the rule comment and note
  it in `BLOCKERS.md`. Do not block this phase on unverified metrics — leave the rule
  present but commented out.

- Validate all YAML files with `docker compose config` after editing `compose.yaml`.
- Validate Prometheus config with `promtool check config prometheus/prometheus.yaml`
  (or `docker exec gnp-stack-prometheus-1 promtool check config /etc/prometheus/prometheus.yaml`).
- Validate Prometheus rules with `promtool check rules prometheus/rules/xrd-alerts.yaml`.

---

## File 1: Create `alertmanager/alertmanager.yaml`

```yaml
# alertmanager/alertmanager.yaml
# Handles routing, grouping, deduplication, and inhibition for all XRd alerts.
# See docs/tasks/alert-use-cases.md §Architecture Decision for rationale.
global:
  resolve_timeout: 5m

route:
  receiver: sp_oncall_webhook
  # Group alerts by the device (source label) and event type.
  # Alerts sharing both labels within group_wait are bundled into one POST.
  group_by: [source, event_type]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    # SC-09 (topology_degraded) is topology-scoped, not per-device.
    # Group only by event_type so all devices contribute to one notification.
    - matchers:
        - event_type = "topology_degraded"
      group_by: [event_type]
      receiver: sp_oncall_webhook

receivers:
  - name: sp_oncall_webhook
    webhook_configs:
      - url: "${WEBHOOK_RECEIVER_URL}"
        send_resolved: true

  - name: null_receiver
    # Intentionally empty — used to silently discard suppressed alerts.

inhibit_rules:
  # SC-01 (interface_state) suppresses SC-01-cascade (isis_adjacency_count) for the
  # same device. ISIS adjacency loss is a known cascade of interface down; the agent
  # should investigate the interface root cause, not open a second thread for ISIS.
  - source_matchers:
      - event_type = "interface_state"
    target_matchers:
      - event_type = "isis_adjacency_count"
    equal: [source]

  # SC-01 (interface_state) suppresses SC-03 (interface_flapping) for the same
  # device+interface. A clean shutdown is not instability.
  - source_matchers:
      - event_type = "interface_state"
    target_matchers:
      - event_type = "interface_flapping"
    equal: [source, name]
```

---

## File 2: Create `prometheus/rules/xrd-alerts.yaml`

Before writing this file, verify each metric name with:

```bash
# Interface oper-status
curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | python3 -m json.tool | grep -i 'oper_status'

# BGP connection-state
curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | python3 -m json.tool | grep -i 'connection_state'

# ISIS neighbor state
curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | python3 -m json.tool | grep -i 'neighbor_state'

# Interface error counters
curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | python3 -m json.tool | grep -i 'in_errors'
```

```yaml
groups:
  - name: xrd-interface-alerts
    interval: 30s
    rules:
      # SC-01 — Physical interface operationally DOWN (non-loopback, non-management)
      # Source label: the gNMIc target name (e.g. "xrd-1")
      # Name label: the interface name (e.g. "GigabitEthernet0/0/0/0")
      - alert: XRdInterfaceDown
        expr: >
          openconfig_interfaces_interface_state_oper_status{
            name!~"Loopback.*|MgmtEth.*"
          } < 1
        for: 15s
        labels:
          severity: critical
          event_type: interface_state
          affected_object_type: interface
        annotations:
          summary: "Interface {{ $labels.name }} on {{ $labels.source }} is DOWN"
          description: >
            Interface {{ $labels.name }} on {{ $labels.source }} is operationally
            DOWN (oper_status={{ $value }}).

  - name: xrd-isis-alerts
    interval: 30s
    rules:
      # SC-01 cascade — Count of ISIS adjacencies NOT in UP state.
      # Alertmanager inhibit_rules suppress this when XRdInterfaceDown fires for
      # the same source device (see alertmanager.yaml inhibit_rules).
      # Uses "isis_adjacency_count" event_type so inhibition can target it precisely.
      - alert: XRdISISAdjacencyDown
        expr: >
          count(
            Cisco_IOS_XR_clns_isis_oper_isis_instances_instance_neighbors_neighbor_neighbor_state{
              neighbor_state!="isis-adj-1-state"
            }
          ) or vector(0)
        for: 15s
        labels:
          severity: warning
          event_type: isis_adjacency_count
          affected_object_type: isis_adjacency
          protocol: isis
        annotations:
          summary: "{{ $value }} ISIS adjacencies not UP"
          description: >
            {{ $value }} ISIS adjacency entries are not in UP state across all devices.

      # SC-09 — Multiple adjacencies lost simultaneously (topology-level event).
      # This does NOT get inhibited by XRdInterfaceDown — it indicates a wider failure
      # (device down, not just one link). The threshold of 3 means at least one full
      # device is isolated from its neighbors.
      - alert: XRdTopologyDegraded
        expr: >
          (
            count(
              Cisco_IOS_XR_clns_isis_oper_isis_instances_instance_neighbors_neighbor_neighbor_state{
                neighbor_state!="isis-adj-1-state"
              }
            ) or vector(0)
          ) >= 3
        for: 15s
        labels:
          severity: critical
          event_type: topology_degraded
          affected_object_type: topology
          protocol: isis
        annotations:
          summary: "Topology degraded: {{ $value }} ISIS adjacencies down"
          description: >
            {{ $value }} ISIS adjacencies are not UP simultaneously — possible device
            failure or network partitioning event.

  - name: xrd-bgp-alerts
    interval: 30s
    rules:
      # SC-02 — BGP session not ESTABLISHED.
      # connection_state == 1 means bgp-st-estab; all other values mean not established.
      # [UNVERIFIED] — confirm metric name with:
      #   curl -s 'http://localhost:9090/api/v1/label/__name__/values' | python3 -m json.tool | grep -i connection_state
      - alert: XRdBGPSessionDown
        expr: >
          Cisco_IOS_XR_ipv4_bgp_oper_bgp_instances_instance_instance_active_default_vrf_neighbors_neighbor_connection_state
          != 1
        for: 30s
        labels:
          severity: critical
          event_type: bgp_session_state
          affected_object_type: bgp_neighbor
          protocol: bgp
          network_instance: default
        annotations:
          summary: "BGP session down: {{ $labels.source }} → {{ $labels.neighbor_address }}"
          description: >
            BGP neighbor {{ $labels.neighbor_address }} on {{ $labels.source }} is not
            ESTABLISHED (connection_state={{ $value }}).

  - name: xrd-interface-stability
    interval: 30s
    rules:
      # SC-03 — Interface flapping: more than 3 state changes in 5 minutes.
      # Alertmanager inhibit_rules suppress this when XRdInterfaceDown fires for the
      # same source+name (clean shutdown is not a flap event).
      - alert: XRdInterfaceFlapping
        expr: >
          changes(
            openconfig_interfaces_interface_state_oper_status{
              name!~"Loopback.*|MgmtEth.*"
            }[5m]
          ) > 3
        for: 0s
        labels:
          severity: warning
          event_type: interface_flapping
          affected_object_type: interface
        annotations:
          summary: "Interface flapping: {{ $labels.source }} - {{ $labels.name }}"
          description: >
            Interface {{ $labels.name }} on {{ $labels.source }} changed state more
            than 3 times in the last 5 minutes.

      # SC-04 — High interface error rate (physical-layer issue while interface UP).
      # [UNVERIFIED] — confirm metric name:
      #   curl -s 'http://localhost:9090/api/v1/label/__name__/values' | python3 -m json.tool | grep -i in_errors
      # Fallback: openconfig_interfaces_interface_state_counters_in_discards
      - alert: XRdInterfaceHighErrorRate
        expr: >
          rate(
            openconfig_interfaces_interface_state_counters_in_errors{
              name!~"Loopback.*|MgmtEth.*"
            }[5m]
          ) > 10
        for: 60s
        labels:
          severity: warning
          event_type: interface_errors
          affected_object_type: interface
        annotations:
          summary: "High error rate: {{ $labels.source }} - {{ $labels.name }}"
          description: >
            Interface {{ $labels.name }} on {{ $labels.source }} is receiving
            {{ $value | printf "%.2f" }} errors/sec.
```

---

## File 3: Edit `compose.yaml` — add Alertmanager service

Add the following service block **after the `prometheus` service** and **before the
`webhook-receiver` service**:

```yaml
alertmanager:
  image: prom/alertmanager:v0.28.1
  ports:
    - 9093:9093
  volumes:
    - ./alertmanager/alertmanager.yaml:/etc/alertmanager/alertmanager.yaml:ro
  command: >
    --config.file=/etc/alertmanager/alertmanager.yaml
    --web.listen-address=:9093
    --log.level=info
  environment:
    - WEBHOOK_RECEIVER_URL=${WEBHOOK_RECEIVER_URL:-http://webhook-receiver:8080/alert}
  networks:
    - gnp-mgmt
  restart: unless-stopped
  healthcheck:
    test:
      [
        "CMD",
        "wget",
        "--quiet",
        "--tries=1",
        "--spider",
        "http://localhost:9093/-/healthy",
      ]
    interval: 10s
    timeout: 5s
    retries: 3
    start_period: 10s
```

---

## File 4: Edit `prometheus/prometheus.yaml` — add alerting and rule_files

Append to the end of the existing `prometheus/prometheus.yaml`:

```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

rule_files:
  - /etc/prometheus/rules/*.yaml
```

> The existing `./prometheus/:/etc/prometheus/` volume mount in `compose.yaml`
> already covers `prometheus/rules/` — no new volume mount needed.

---

## File 5: Edit `grafana/provisioning/datasource.yaml` — add Alertmanager datasource

Append after the existing Loki datasource entry:

```yaml
- name: Alertmanager
  type: alertmanager
  uid: alertmanager
  orgId: 1
  url: http://alertmanager:9093
  access: proxy
  jsonData:
    handleGrafanaManagedAlerts: false
    implementation: prometheus
  editable: true
```

---

## Validation sequence

Run these in order after `make restart`:

```bash
# 1. Alertmanager is healthy
curl -s http://localhost:9093/-/healthy
# Expected: OK

# 2. Prometheus loaded the rules
curl -s http://localhost:9090/api/v1/rules \
  | python3 -m json.tool | grep '"name"'
# Expected: all 6 alert names appear

# 3. Alertmanager config parsed correctly (shows the routes and inhibit_rules)
curl -s http://localhost:9093/api/v2/status \
  | python3 -m json.tool | grep -A5 '"config"'

# 4. Check Grafana still shows its own alerts (unchanged)
# Open http://localhost:3000/alerting — existing Grafana alert rules still visible

# 5. Validate YAML syntax of new rules
docker exec gnp-stack-prometheus-1 \
  promtool check rules /etc/prometheus/rules/xrd-alerts.yaml
# Expected: SUCCESS
```

If step 5 fails with metric not found errors — that is OK. `promtool check rules` only
validates YAML syntax and PromQL syntax, not whether metrics exist. Proceed to Phase 2.

If `alertmanager` container fails to start, check:

```bash
docker logs gnp-stack-alertmanager-1 2>&1 | tail -20
```

Common cause: YAML indentation error in `alertmanager.yaml` or the
`WEBHOOK_RECEIVER_URL` env var not resolving. Check `docker compose config` output.
