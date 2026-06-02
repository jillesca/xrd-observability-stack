# Alert Use Cases — XRd Segment Routing Demo

## Purpose

This document is an implementation guide for AI agents. It defines a catalog of alert
scenarios and the full alert pipeline architecture for the gnp-stack demo. It specifies
exactly what each alert needs in terms of:

- Prometheus alerting rule (in `prometheus/rules/xrd-alerts.yaml`)
- Dashboard annotation query (Loki LogQL in `xrd-sr-overview.json`)
- `NetworkAlert` labels so sp_oncall receives actionable context
- Which gNMIBuddy MCP tools the agents should invoke

**Constraints**:

- Alert rules live in **Prometheus** (`prometheus/rules/xrd-alerts.yaml`), not in Grafana
  provisioning. The Grafana alerting provisioning directory is emptied as part of this
  work. See §Architecture Decision below.
- All Prometheus metric names **must be verified** against the live stack before
  building an alert. Run `curl -s 'http://localhost:9090/api/v1/label/__name__/values'
| python3 -m json.tool | grep -i '<keyword>'` and record actual names.
- All LogQL annotation patterns **must be tested** against live Loki data. Use Grafana
  Explore → Loki → paste the query.
- If a metric or log pattern does not exist on this XRd version, mark it
  `[UNVERIFIED]` in the rule comment and add a note in `BLOCKERS.md`.
- Do not add new gNMI subscriptions. All collected paths are in §Appendix A of `DESIGN.md`.
- Scenarios marked **[OUT OF SCOPE]** are catalogued for reference but must not be
  implemented — they cannot be triggered in the sandbox environment.
- Scenarios marked **[ANNOTATION ONLY]** produce no alert rule. They add dashboard
  annotations only and do not trigger sp_oncall investigations.
- Always verify the webhook container produces the correct `NetworkAlert` payload. The
  LangGraph API server will not be available for end-to-end testing, but confirm the
  payload by sending a test POST to `http://localhost:8080/alert`.

---

## Architecture Decision: External Alertmanager

### Decision

Add a standalone **Alertmanager** container to the stack. Move all metric-based alert
rules from Grafana's provisioning into Prometheus rule files. Alertmanager becomes the
single authority for alert routing, deduplication, grouping, and inhibition.

### Why not Grafana's built-in alerting for this?

Grafana ships with an embedded Alertmanager and currently handles alert routing via
`xrd-notification-policy.yaml`. The built-in approach works, but has one critical gap
for this demo: it cannot cleanly suppress _symptom_ alerts when a _root cause_ alert
is already firing.

Example of the problem without inhibition: shutting down one interface on xrd-1 fires
SC-01 (interface down), the existing ISIS adjacency-down rule, and SC-09 (topology
degraded) within 30 seconds. Without inhibition, the webhook receiver creates three
independent sp_oncall investigation threads for the same event.

Alertmanager's `inhibit_rules` solve this cleanly and are the industry-standard
pattern. Grafana's built-in Alertmanager does not expose `inhibit_rules` through its
provisioning YAML, requiring API calls to set them — that is fragile for a
reproducible demo stack.

### Why not replace the webhook receiver container?

Alertmanager sends alerts to receivers as webhooks using a format nearly identical to
Grafana's webhook format (both use an `alerts[]` array with `labels`, `annotations`,
`status`, `startsAt`). The existing `GrafanaWebhook` Pydantic model uses
`extra="allow"`, so it accepts Alertmanager's additional fields (`groupKey`,
`groupLabels`, `commonLabels`, `externalURL`) without changes. The webhook receiver
container **stays** — it is the adapter between the alert pipeline and sp_oncall.

The only behavioral difference: Alertmanager does not include `values` (metric values
at alert time) in its payload. The `metric_value` field in `NetworkAlert` will be
`None` for all Alertmanager-sourced alerts. This is acceptable — sp_oncall agents
retrieve current metric values via gNMIBuddy MCP tools.

### Architecture after this change

```
Prometheus
  └─ evaluates alerting rules (prometheus/rules/xrd-alerts.yaml)
  └─ sends ALERTS to Alertmanager :9093

Alertmanager
  └─ deduplicates + groups alerts (group_by: [source, event_type])
  └─ applies inhibit_rules (interface_state suppresses isis_adjacency_count)
  └─ routes root-cause alerts → webhook-receiver :8080/alert
  └─ routes symptom alerts   → null receiver (no notification)

webhook-receiver (FastAPI)
  └─ parses Alertmanager payload → NetworkAlert
  └─ triggers sp_oncall LangGraph thread

Grafana
  └─ displays dashboards and Prometheus metrics (unchanged)
  └─ displays Alertmanager alerts via Alertmanager datasource (read-only)
  └─ adds Loki annotations to dashboard panels (annotation queries only)
  └─ has NO alert rules of its own (Grafana alerting provisioning files removed)
```

### Log-based signals: annotations only

Log-derived alert scenarios (SC-07 ISIS Adjacency Log, SC-08 BGP Session Log) are
downgraded to **dashboard annotations only**. They do not produce Prometheus alert
rules and do not reach sp_oncall. Reasons:

1. The root-cause metric alert (SC-01, SC-02) fires within seconds of the log event.
   Sending a second webhook for the same incident doubles the investigation threads.
2. Logs lack the structured labels (device IP, interface name) needed to populate
   `NetworkAlert` unambiguously without complex parsing in the webhook receiver.
3. Logs as annotations on the dashboard are the correct use of this data — they provide
   visual context ("what was the ISIS failure reason?") without driving actions.

---

## Context: What Data Is Already Available

### Prometheus (sampled or on_change via gNMI)

| Subscription         | Paths / Data                                             | Mode      | Interval |
| -------------------- | -------------------------------------------------------- | --------- | -------- |
| `xrd-if-states`      | Interface oper-status, admin-status (OC)                 | on_change | 60s HB   |
| `xrd-if-stats`       | Interface counters: in/out octets, errors, discards (OC) | sample    | 30s      |
| `xrd-isis-adjacency` | ISIS neighbor state per instance/neighbor (XR native)    | on_change | 10s HB   |
| `xrd-isis-stats`     | ISIS FRR summary per topology (XR native)                | sample    | 30s      |
| `xrd-bgp-sessions`   | BGP connection-state per neighbor (XR native)            | on_change | 60s HB   |
| `xrd-bgp-stats`      | BGP message statistics per neighbor (XR native)          | sample    | 30s      |
| `xrd-mpls-labels`    | MPLS label summary (XR native)                           | sample    | 30s      |
| `xrd-system-health`  | Memory summary per node (XR native)                      | sample    | 30s      |
| `xrd-pce-topology`   | PCE topology nodes (xrd-7 only, XR native)               | sample    | 30s      |

### Loki (syslog via Grafana Alloy)

- Job label: `job="xrd-syslog"`
- Stream labels extracted: `hostname` (device name), `severity` (XR severity digit 0–7)
- All XRd devices push syslog UDP → Alloy → Loki

### gNMIBuddy MCP tools (used by sp_oncall agents)

| Tool category | Relevant commands                                        |
| ------------- | -------------------------------------------------------- |
| `device`      | `info`, `profile` — device role and system state         |
| `network`     | `routing` (BGP/ISIS), `interface`, `mpls`, `vpn`         |
| `topology`    | `neighbors`, `adjacency`, `network` — full topology view |
| `ops`         | `logs` — retrieve and filter device logs by keyword      |

---

## XR Syslog Structure

XRd syslogs follow this pattern (RFC5424 with XR structured message):

```
TIMESTAMP HOSTNAME PROCESS[PID]: %FACILITY-SUBFACILITY-<SEVERITY_DIGIT>-MNEMONIC : message body
```

Example:

```
2026-05-22T10:17:25Z xrd-4 isis[1003]: %ROUTING-ISIS-5-ADJCHANGE : ISIS (1): Adjacency to xrd-3 (GigabitEthernet0/0/0/0) (L2) Down, Interface state down
```

### Generic XR mnemonic regex (use in all LogQL `regexp` stages)

```
%(?P<facility>[A-Z0-9_]+-[A-Z0-9_]+)-(?P<xr_severity>[0-7])-(?P<mnemonic>[A-Z0-9_]+)\s*:\s*(?P<body>.+)
```

This extracts four named groups from any XR syslog message:

- `facility` — e.g. `ROUTING-ISIS`, `PKT_INFRA-LINK`, `ROUTING-BGP`
- `xr_severity` — digit 0–7 matching RFC5424 (already a Loki label via Alloy)
- `mnemonic` — e.g. `ADJCHANGE`, `UPDOWN`, `NOTIFICATION`
- `body` — the human-readable message after the colon

> **Note**: Alloy already extracts `severity` (the `xr_severity` digit) as a Loki stream
> label. All additional field extraction happens in LogQL at query time — no Alloy config
> changes are required for the scenarios below.

---

## Alert Catalog

Each scenario below is structured as:

1. **Trigger** — what fires the alert (Prometheus or Loki)
2. **Grafana alert rule spec** — ready for YAML provisioning
3. **Dashboard annotation** — LogQL for the annotation query
4. **NetworkAlert labels** — what labels the webhook receiver sets on the `NetworkAlert`
5. **Investigation guidance** — what gNMIBuddy tools sp_oncall should call first

---

### SC-01: Interface Down — **[IN SCOPE — migrate to Prometheus rules]**

Currently in `grafana/provisioning/alerting/xrd-alert-rules.yaml` (uid: `xrd-interface-down`).
ISIS adjacency cascade alert also present (uid: `xrd-isis-adjacency-down`).
**Both rules must be removed from Grafana provisioning and moved to `prometheus/rules/xrd-alerts.yaml`.**
See §Prometheus Alert Rules for the consolidated rule file.

- **Trigger**: `openconfig_interfaces_interface_state_oper_status{name!~"Loopback.*|MgmtEth.*"} < 1`
- **Annotation**: `{job="xrd-syslog"} |~ "%PKT_INFRA-LINK-3-UPDOWN|%PKT_INFRA-LINEPROTO-5-UPDOWN"`
- **event_type label**: `interface_state`
- **Agent investigation**: `gnmibuddy network interface`, then `gnmibuddy topology adjacency`

---

### SC-02: BGP Session Down — **[IN SCOPE — Prometheus rule]**

BGP peer connection goes from ESTABLISHED to any non-established state. The primary
BGP sessions in this topology are from xrd-1 and xrd-2 (PE routers) to xrd-8 (vRR).

**Trigger (Prometheus)**:

```promql
# connection-state values: bgp-st-estab = ESTABLISHED; others = not established
# Alert fires when any neighbor is NOT in established state
Cisco_IOS_XR_ipv4_bgp_oper_bgp_instances_instance_instance_active_default_vrf_neighbors_neighbor_connection_state != 1
```

> Verify actual metric name: `curl -s 'http://localhost:9090/api/v1/label/__name__/values' | python3 -m json.tool | grep -i bgp.*connection`

**Grafana alert rule spec**:

```yaml
- uid: xrd-bgp-session-down
  title: XRd BGP Session Down
  condition: C
  data:
    - refId: A
      relativeTimeRange: { from: 300, to: 0 }
      datasourceUid: prometheus
      model:
        expr: >
          Cisco_IOS_XR_ipv4_bgp_oper_bgp_instances_instance_instance_active_default_vrf_neighbors_neighbor_connection_state{source=~".+"}
        instant: false
        refId: A
    - refId: B
      datasourceUid: __expr__
      model:
        type: reduce
        expression: A
        reducer: last
        settings: { mode: dropNN }
        refId: B
    - refId: C
      datasourceUid: __expr__
      model:
        type: threshold
        expression: B
        conditions:
          - evaluator: { params: [1], type: lt }
            operator: { type: and }
            query: { params: [C] }
            reducer: { params: [], type: last }
            type: query
        refId: C
  noDataState: OK
  execErrState: Alerting
  for: 30s
  labels:
    severity: critical
    event_type: bgp_session_state
    affected_object_type: bgp_neighbor
    protocol: bgp
  annotations:
    summary: "BGP session down: {{ $labels.source }} → {{ $labels.neighbor_address }}"
    description: "BGP neighbor {{ $labels.neighbor_address }} on {{ $labels.source }} is not ESTABLISHED"
```

**Dashboard annotation** (add to `xrd-sr-overview.json` `annotations.list`):

```json
{
  "datasource": { "type": "loki", "uid": "loki" },
  "enable": true,
  "expr": "{job=\"xrd-syslog\"} |~ `%ROUTING-BGP-[35]-ADJCHANGE|%BGP-[35]-ADJCHANGE` | regexp `%(?P<facility>[A-Z0-9_]+-[A-Z0-9_]+)-(?P<xr_severity>[0-7])-(?P<mnemonic>[A-Z0-9_]+)\\s*:\\s*(?P<body>.+)`",
  "name": "BGP Session Change",
  "titleFormat": "BGP {{ mnemonic }}: {{ hostname }}",
  "textFormat": "{{ body }}",
  "iconColor": "orange",
  "hide": false
}
```

**NetworkAlert labels**:

```
event_type: bgp_session_state
affected_object_type: bgp_neighbor
affected_object: <neighbor_address label from Prometheus>
protocol: bgp
network_instance: default
neighbor_device: null  # agents determine this via topology tools
```

**Agent investigation**:

1. `gnmibuddy network routing --device <device>` — full BGP neighbor table
2. `gnmibuddy topology adjacency --all-devices` — who lost peers
3. `gnmibuddy ops logs --device <device> --keyword BGP` — log context

---

### SC-03: Interface Flapping — **[IN SCOPE — Prometheus rule]**

An interface transitions up→down or down→up more than 3 times in a 5-minute window.
This indicates physical instability, not a clean maintenance shutdown.

**Trigger (Prometheus)**:

```promql
changes(openconfig_interfaces_interface_state_oper_status{name!~"Loopback.*|MgmtEth.*"}[5m]) > 3
```

**Grafana alert rule spec**:

```yaml
- uid: xrd-interface-flapping
  title: XRd Interface Flapping
  condition: B
  data:
    - refId: A
      relativeTimeRange: { from: 600, to: 0 }
      datasourceUid: prometheus
      model:
        expr: >
          changes(openconfig_interfaces_interface_state_oper_status{name!~"Loopback.*|MgmtEth.*"}[5m])
        instant: false
        refId: A
    - refId: B
      datasourceUid: __expr__
      model:
        type: threshold
        expression: A
        conditions:
          - evaluator: { params: [3], type: gt }
            operator: { type: and }
            query: { params: [B] }
            reducer: { params: [], type: last }
            type: query
        refId: B
  noDataState: OK
  execErrState: OK
  for: 0s
  labels:
    severity: warning
    event_type: interface_flapping
    affected_object_type: interface
  annotations:
    summary: "Interface flapping: {{ $labels.source }} - {{ $labels.name }}"
    description: "Interface {{ $labels.name }} on {{ $labels.source }} has changed state more than 3 times in the last 5 minutes"
```

**Dashboard annotation**: same as SC-01 (link up/down messages from XR syslog).

**NetworkAlert labels**:

```
event_type: interface_flapping
affected_object_type: interface
affected_object: <name label>
protocol: null
```

**Agent investigation**:

1. `gnmibuddy network interface --device <device>` — current interface state and counters
2. `gnmibuddy ops logs --device <device> --keyword UPDOWN` — recent up/down events
3. `gnmibuddy topology neighbors --device <device>` — which peer is on that interface

---

### SC-04: High Interface Error Rate — **[IN SCOPE — Prometheus rule]**

Input or output error counter rate exceeds a threshold. Indicates physical-layer issues
(bad cable, SFP, or peer NIC) even while the interface remains operationally UP.

**Trigger (Prometheus)**:

```promql
rate(openconfig_interfaces_interface_state_counters_in_errors{name!~"Loopback.*|MgmtEth.*"}[5m]) > 10
```

> Verify metric: `grep -i 'in_errors\|out_errors'` in the Prometheus label browser.
> Fallback: `openconfig_interfaces_interface_state_counters_in_discards` if errors not populated.

**Grafana alert rule spec**:

```yaml
- uid: xrd-interface-errors
  title: XRd High Interface Error Rate
  condition: B
  data:
    - refId: A
      relativeTimeRange: { from: 300, to: 0 }
      datasourceUid: prometheus
      model:
        expr: >
          rate(openconfig_interfaces_interface_state_counters_in_errors{name!~"Loopback.*|MgmtEth.*"}[5m])
        instant: false
        refId: A
    - refId: B
      datasourceUid: __expr__
      model:
        type: threshold
        expression: A
        conditions:
          - evaluator: { params: [10], type: gt }
            operator: { type: and }
            query: { params: [B] }
            reducer: { params: [], type: last }
            type: query
        refId: B
  noDataState: OK
  execErrState: OK
  for: 60s
  labels:
    severity: warning
    event_type: interface_errors
    affected_object_type: interface
  annotations:
    summary: "High error rate: {{ $labels.source }} - {{ $labels.name }}"
    description: "Interface {{ $labels.name }} on {{ $labels.source }} is receiving errors at {{ $values.B }} errors/sec"
```

**Dashboard annotation**: no syslog mnemonic directly maps to error counters. Skip annotation.

**NetworkAlert labels**:

```
event_type: interface_errors
affected_object_type: interface
affected_object: <name label>
metric_value: <error rate from $values.B>
```

**Agent investigation**:

1. `gnmibuddy network interface --device <device>` — full counter state
2. `gnmibuddy topology neighbors --device <device>` — identify the peer on that link
3. `gnmibuddy network interface --device <neighbor>` — check peer-side counters

---

### SC-05: Memory Pressure — **[OUT OF SCOPE]**

> Cannot be triggered in the sandbox environment. XRd containers do not consume enough
> memory to breach a meaningful threshold during a demo. Documented for reference only.
> Do not implement.

Node memory free percentage drops below a threshold. Uses the already-collected
`xrd-system-health` subscription (XR native memory summary YANG).

**Trigger (Prometheus)**:

> First verify which memory metrics exist:
> `curl -s 'http://localhost:9090/api/v1/label/__name__/values' | python3 -m json.tool | grep -i memory`
>
> Expected pattern:
> `Cisco_IOS_XR_nto_misc_oper_memory_summary_nodes_node_summary_page_size`
> `Cisco_IOS_XR_nto_misc_oper_memory_summary_nodes_node_summary_ram_memory`
> `Cisco_IOS_XR_nto_misc_oper_memory_summary_nodes_node_summary_free_application_memory`

```promql
# Free memory as percentage of total RAM — alert below 15%
(
  Cisco_IOS_XR_nto_misc_oper_memory_summary_nodes_node_summary_free_application_memory
  /
  Cisco_IOS_XR_nto_misc_oper_memory_summary_nodes_node_summary_ram_memory
) * 100 < 15
```

**Grafana alert rule spec**:

```yaml
- uid: xrd-memory-pressure
  title: XRd Memory Pressure
  condition: B
  data:
    - refId: A
      relativeTimeRange: { from: 300, to: 0 }
      datasourceUid: prometheus
      model:
        expr: >
          (
            Cisco_IOS_XR_nto_misc_oper_memory_summary_nodes_node_summary_free_application_memory
            /
            Cisco_IOS_XR_nto_misc_oper_memory_summary_nodes_node_summary_ram_memory
          ) * 100
        instant: false
        refId: A
    - refId: B
      datasourceUid: __expr__
      model:
        type: threshold
        expression: A
        conditions:
          - evaluator: { params: [15], type: lt }
            operator: { type: and }
            query: { params: [B] }
            reducer: { params: [], type: last }
            type: query
        refId: B
  noDataState: OK
  execErrState: OK
  for: 120s
  labels:
    severity: warning
    event_type: memory_pressure
    affected_object_type: system
  annotations:
    summary: 'Memory low: {{ $labels.source }} ({{ $values.B | printf "%.1f" }}% free)'
    description: "Device {{ $labels.source }} has less than 15% free application memory"
```

**Dashboard annotation**: check for XR `%SYS-3-*` or `%ENVMON-*` syslogs.

```json
{
  "datasource": { "type": "loki", "uid": "loki" },
  "enable": true,
  "expr": "{job=\"xrd-syslog\", severity=~\"[0-3]\"} |~ `%SYS-|%PLATFORM-` | regexp `%(?P<facility>[A-Z0-9_]+-[A-Z0-9_]+)-(?P<xr_severity>[0-7])-(?P<mnemonic>[A-Z0-9_]+)\\s*:\\s*(?P<body>.+)`",
  "name": "System / Platform Events",
  "titleFormat": "{{ facility }}-{{ mnemonic }}: {{ hostname }}",
  "textFormat": "{{ body }}",
  "iconColor": "red",
  "hide": false
}
```

**NetworkAlert labels**:

```
event_type: memory_pressure
affected_object_type: system
affected_object: null
metric_value: <free memory percentage>
```

**Agent investigation**:

1. `gnmibuddy device info --device <device>` — system health snapshot
2. `gnmibuddy ops logs --device <device> --keyword memory` — log context

---

### SC-06: Traffic Saturation (High Interface Throughput) — **[OUT OF SCOPE]**

> No traffic generator is available in this sandbox. XRd software interfaces carry only
> control-plane traffic (BGP, ISIS) during the demo — far below any meaningful threshold.
> Documented for reference only. Do not implement.

Outbound throughput on a non-loopback interface exceeds 80% of assumed link capacity.
Useful for detecting unexpected traffic spikes or traffic engineering failures routing
traffic over a congested path.

> **Caveat**: XRd GigabitEthernet interfaces in the sandbox are software interfaces;
> actual capacity is CPU-bound, not 1 Gbps. Tune the threshold to a realistic value
> for your environment (e.g., 50 Mbps = 50,000,000 bps). Adjust after running
> baseline traffic.

**Trigger (Prometheus)**:

```promql
rate(openconfig_interfaces_interface_state_counters_out_octets{name!~"Loopback.*|MgmtEth.*"}[5m]) * 8 > 50000000
```

**Grafana alert rule spec**:

```yaml
- uid: xrd-traffic-saturation
  title: XRd Interface Traffic Saturation
  condition: B
  data:
    - refId: A
      relativeTimeRange: { from: 300, to: 0 }
      datasourceUid: prometheus
      model:
        expr: >
          rate(openconfig_interfaces_interface_state_counters_out_octets{name!~"Loopback.*|MgmtEth.*"}[5m]) * 8
        instant: false
        refId: A
    - refId: B
      datasourceUid: __expr__
      model:
        type: threshold
        expression: A
        conditions:
          - evaluator: { params: [50000000], type: gt }
            operator: { type: and }
            query: { params: [B] }
            reducer: { params: [], type: last }
            type: query
        refId: B
  noDataState: OK
  execErrState: OK
  for: 60s
  labels:
    severity: warning
    event_type: traffic_saturation
    affected_object_type: interface
  annotations:
    summary: "Traffic saturation: {{ $labels.source }} - {{ $labels.name }}"
    description: "Interface {{ $labels.name }} on {{ $labels.source }} is sending {{ $values.B }} bps"
```

**NetworkAlert labels**:

```
event_type: traffic_saturation
affected_object_type: interface
affected_object: <name label>
metric_value: <bps from $values.B>
```

**Agent investigation**:

1. `gnmibuddy network mpls --device <device>` — SR label forwarding table
2. `gnmibuddy network interface --device <device>` — traffic distribution per interface
3. `gnmibuddy topology network` — full topology to find alternate paths
4. `gnmibuddy network routing --device <device>` — routing table changes

---

### SC-07: ISIS Adjacency Lost with Log Correlation — **[ANNOTATION ONLY]**

> **Not an alert rule.** Logs add _context_ (the failure reason) but the root-cause
> alert is SC-01 (interface down), which fires from Prometheus. Creating a second
> sp_oncall investigation from a log event 2 seconds later would duplicate the thread.
> This scenario provides a **dashboard annotation** only.

The syslog stream carries the ISIS failure reason (`Holdtime expired`, `Interface state
down`, etc.) that is missing from the metric alert. This appears as an annotation line
on the ISIS Adjacency State panel — visible to the human operator, not to agents.

**Dashboard annotation** (already specified in `docs/tasks/loki-isis-adjchange-annotations.md`):

```logql
{job="xrd-syslog"}
  |~ `%ROUTING-ISIS-5-ADJCHANGE`
  | regexp `Adjacency to (?P<neighbor>\S+) \((?P<interface>[^)]+)\) \((?P<level>L[12])\) (?P<direction>Down|Up),\s*(?P<reason>.+)`
```

Annotation title: `ISIS {{direction}}: {{hostname}} → {{neighbor}}`
Annotation text: `Interface: {{interface}} | Reason: {{reason}}`

---

### SC-08: BGP Session Change in Logs — **[ANNOTATION ONLY]**

> **Not an alert rule.** The root-cause alert is SC-02 (BGP Session Down), which fires
> from Prometheus. The log annotation here provides the **NOTIFICATION error code** —
> information Prometheus cannot carry. This is dashboard context, not an investigation
> trigger.

The syslog carries the BGP NOTIFICATION error code and subcode that explains _why_ the
session terminated. This appears as an annotation on the BGP Session State panel.

**IOS-XR log pattern** (verify against live Loki data):

```
%ROUTING-BGP-5-ADJCHANGE : neighbor X.X.X.X Down BGP Notification received: code <N> subcode <N>
```

**Dashboard annotation**:

```json
{
  "datasource": { "type": "loki", "uid": "loki" },
  "enable": true,
  "expr": "{job=\"xrd-syslog\"} |~ `%ROUTING-BGP-[35]-ADJCHANGE|%BGP-[35]-ADJCHANGE` | regexp `neighbor (?P<neighbor>\\S+) (?P<direction>Down|Up)(?P<reason>.+)?`",
  "name": "BGP Adjacency Change",
  "titleFormat": "BGP {{ direction }}: {{ hostname }} → {{ neighbor }}",
  "textFormat": "{{ reason }}",
  "iconColor": "orange",
  "hide": false
}
```

---

### SC-09: Topology Degraded (Multiple Adjacencies Lost) — **[IN SCOPE — Prometheus rule]**

When 3 or more ISIS adjacencies drop simultaneously, the topology has degraded beyond
a single link failure. This is a higher-severity composite signal indicating either a
device failure or a partitioning event.

**Trigger (Prometheus)**:

```promql
# Count adjacency rows whose state is NOT the UP value
count(
  Cisco_IOS_XR_clns_isis_oper_isis_instances_instance_neighbors_neighbor_neighbor_state{neighbor_state!="isis-adj-1-state"}
) >= 3
```

**Grafana alert rule spec**:

```yaml
- uid: xrd-topology-degraded
  title: XRd Topology Degraded (Multiple Adjacencies Down)
  condition: B
  data:
    - refId: A
      relativeTimeRange: { from: 300, to: 0 }
      datasourceUid: prometheus
      model:
        expr: >
          count(
            Cisco_IOS_XR_clns_isis_oper_isis_instances_instance_neighbors_neighbor_neighbor_state{neighbor_state!="isis-adj-1-state"}
          ) or vector(0)
        instant: true
        refId: A
    - refId: B
      datasourceUid: __expr__
      model:
        type: threshold
        expression: A
        conditions:
          - evaluator: { params: [3], type: gte }
            operator: { type: and }
            query: { params: [B] }
            reducer: { params: [], type: last }
            type: query
        refId: B
  noDataState: OK
  execErrState: OK
  for: 15s
  labels:
    severity: critical
    event_type: topology_degraded
    affected_object_type: topology
    protocol: isis
  annotations:
    summary: "Topology degraded: {{ $values.B }} ISIS adjacencies down"
    description: "Multiple ISIS adjacencies lost simultaneously — possible device failure or partitioning"
```

**NetworkAlert labels**:

```
event_type: topology_degraded
affected_object_type: topology
affected_object: null
protocol: isis
metric_value: <count of adjacencies down>
```

**Agent investigation** (scope is topology-wide, not device-specific):

1. `gnmibuddy topology network` — full topology snapshot
2. `gnmibuddy topology adjacency --all-devices` — which links are down across all devices
3. `gnmibuddy device info --all-devices` — check all devices responding
4. `gnmibuddy ops logs --all-devices --keyword ISIS` — correlate reasons

---

### SC-10: MPLS Label Pool Exhaustion [UNVERIFIED]

MPLS label allocation failure or pool critically low. Uses the `xrd-mpls-labels`
subscription (already collected).

> **Note**: Verify that `Cisco_IOS_XR_mpls_lsd_oper_mpls_lsd_label_summary_*` metrics
> exist in Prometheus. This subscription was marked `[to validate]` in DESIGN.md.
> If not present, add `[UNVERIFIED]` to the rule and skip until confirmed working.

**Trigger (Prometheus)**:

```promql
# Free labels as percentage of total — alert below 10%
(
  Cisco_IOS_XR_mpls_lsd_oper_mpls_lsd_label_summary_free_labels_count
  /
  (Cisco_IOS_XR_mpls_lsd_oper_mpls_lsd_label_summary_free_labels_count
   + Cisco_IOS_XR_mpls_lsd_oper_mpls_lsd_label_summary_in_use_labels_count)
) * 100 < 10
```

**Dashboard annotation**:

```logql
{job="xrd-syslog"} |~ `%MPLS_LSD-3-REALLOC_FAILURE|%MPLS-3-` | regexp `%(?P<facility>[A-Z0-9_]+-[A-Z0-9_]+)-(?P<xr_severity>[0-7])-(?P<mnemonic>[A-Z0-9_]+)\s*:\s*(?P<body>.+)`
```

**NetworkAlert labels**:

```
event_type: mpls_label_exhaustion
affected_object_type: mpls_pool
metric_value: <free label percentage>
```

**Agent investigation**:

1. `gnmibuddy network mpls --device <device>` — current MPLS forwarding state
2. `gnmibuddy ops logs --device <device> --keyword MPLS` — allocation errors

---

## Dashboard Annotation Master List

All annotations below should be added to `grafana/dashboards/xrd/xrd-sr-overview.json`
in the `annotations.list` array.

> One annotation from `loki-isis-adjchange-annotations.md` already exists.
> The annotations below supplement it. Do not duplicate the ISIS ADJCHANGE annotation.

| Annotation name          | LogQL pattern                                                                      | Icon color | Scenario |
| ------------------------ | ---------------------------------------------------------------------------------- | ---------- | -------- |
| ISIS Adjacency Change    | Already in `docs/tasks/loki-isis-adjchange-annotations.md`                         | red        | SC-01/07 |
| BGP Adjacency Change     | `{job="xrd-syslog"} \|~ "%ROUTING-BGP-[35]-ADJCHANGE\|%BGP-[35]-ADJCHANGE"`        | orange     | SC-02/08 |
| Link Up/Down             | `{job="xrd-syslog"} \|~ "%PKT_INFRA-LINK-3-UPDOWN\|%PKT_INFRA-LINEPROTO-5-UPDOWN"` | red        | SC-01/03 |
| System / Platform Events | `{job="xrd-syslog", severity=~"[0-3]"} \|~ "%SYS-\|%PLATFORM-"`                    | red        | SC-05    |
| MPLS Events              | `{job="xrd-syslog"} \|~ "%MPLS_LSD-3-"`                                            | yellow     | SC-10    |

Each annotation entry in JSON:

```json
{
  "datasource": { "type": "loki", "uid": "loki" },
  "enable": true,
  "expr": "<LogQL from table above>",
  "name": "<Annotation name>",
  "titleFormat": "{{ mnemonic }}: {{ hostname }}",
  "textFormat": "{{ body }}",
  "iconColor": "<color>",
  "hide": false
}
```

The `mnemonic`, `hostname`, and `body` template variables require a `regexp` stage in the
LogQL pipeline. Use the generic regex:

```logql
| regexp `%(?P<facility>[A-Z0-9_]+-[A-Z0-9_]+)-(?P<xr_severity>[0-7])-(?P<mnemonic>[A-Z0-9_]+)\s*:\s*(?P<body>.+)`
```

> `hostname` is already a Loki stream label (extracted by Alloy). It is available
> in annotation templates directly without LogQL extraction.

---

## Alertmanager Configuration

Create directory `alertmanager/` and file `alertmanager/alertmanager.yaml`.

```yaml
# alertmanager/alertmanager.yaml
global:
  resolve_timeout: 5m

route:
  receiver: sp_oncall_webhook
  # Group alerts by the device they originated from and their event type.
  # Alerts for the same device+event_type arriving within group_wait are
  # bundled into a single webhook POST to avoid duplicate investigations.
  group_by: [source, event_type]
  group_wait: 30s # wait 30s to collect related alerts before sending
  group_interval: 5m # re-notify after 5m if still firing
  repeat_interval: 4h # resend the same firing group after 4h

  routes:
    # SC-09 (topology degraded) is topology-scoped, not device-scoped.
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
        http_config: {}

  - name: null_receiver
    # Intentionally empty — used to silently discard suppressed alerts

inhibit_rules:
  # When an interface goes DOWN on a device, suppress the ISIS adjacency-count
  # alert for that same device. ISIS adjacency loss is a known cascade of the
  # interface failure; the agent should investigate the interface, not open a
  # second thread for ISIS.
  - source_matchers:
      - event_type = "interface_state"
    target_matchers:
      - event_type = "isis_adjacency_count"
    # Both alerts must share the same `source` label (same device)
    equal: [source]

  # When an interface is cleanly DOWN, suppress the flapping alert for the
  # same device+interface. A clean shutdown does not need flap investigation.
  - source_matchers:
      - event_type = "interface_state"
    target_matchers:
      - event_type = "interface_flapping"
    equal: [source, name]
```

### Add Alertmanager to `compose.yaml`

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
  networks:
    - gnp-mgmt
  restart: unless-stopped
```

### Add Alertmanager datasource to Grafana (`grafana/provisioning/datasource.yaml`)

Add alongside the existing Prometheus and Loki entries so Grafana can display
Alertmanager alerts in the Alerting UI (read-only display, no evaluation):

```yaml
- name: Alertmanager
  type: alertmanager
  uid: alertmanager
  url: http://alertmanager:9093
  access: proxy
  jsonData:
    handleGrafanaManagedAlerts: false
    implementation: prometheus
  editable: true
```

### Update `prometheus/prometheus.yaml` — add alerting section

```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

rule_files:
  - /etc/prometheus/rules/*.yaml
```

> Prometheus loads rules from the `rule_files` glob. Mount the rules directory in
> `compose.yaml` Prometheus volumes: the existing `./prometheus/:/etc/prometheus/`
> mount already covers it if rules live in `prometheus/rules/`.

---

## Prometheus Alert Rules

Create `prometheus/rules/xrd-alerts.yaml`. This file replaces all alert rules
previously in `grafana/provisioning/alerting/xrd-alert-rules.yaml`.

```yaml
groups:
  - name: xrd-interface-alerts
    interval: 30s
    rules:
      # SC-01 — Interface operationally DOWN (physical, non-loopback)
      - alert: XRdInterfaceDown
        expr: >
          openconfig_interfaces_interface_state_oper_status{name!~"Loopback.*|MgmtEth.*"} < 1
        for: 15s
        labels:
          severity: critical
          event_type: interface_state
          affected_object_type: interface
        annotations:
          summary: "Interface {{ $labels.name }} on {{ $labels.source }} is DOWN"
          description: >
            Interface {{ $labels.name }} on {{ $labels.source }} is operationally DOWN
            (oper_status={{ $value }}).

  - name: xrd-isis-alerts
    interval: 30s
    rules:
      # SC-01 cascade — ISIS adjacency count above zero indicates at least one down
      # This fires as a cascade of SC-01. Alertmanager inhibit_rules suppress it when
      # XRdInterfaceDown is already firing for the same source device.
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

      # SC-09 — Multiple adjacencies lost: topology-level failure
      # Fires independently of SC-01 because it indicates a wider event
      # (device failure, not just a single link). Alertmanager does NOT inhibit this.
      - alert: XRdTopologyDegraded
        expr: >
          count(
            Cisco_IOS_XR_clns_isis_oper_isis_instances_instance_neighbors_neighbor_neighbor_state{
              neighbor_state!="isis-adj-1-state"
            }
          ) or vector(0) >= 3
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
      # SC-02 — BGP session not ESTABLISHED
      # Verify actual metric name with: grep -i bgp.*connection in Prometheus label browser
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
      # SC-03 — Interface flapping: more than 3 state changes in 5 minutes
      # Alertmanager inhibit_rules suppress this if XRdInterfaceDown is already
      # firing for the same source+name (clean shutdown is not a flap).
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

      # SC-04 — High interface error rate
      # Fires while interface is UP — indicates physical-layer issues.
      # Verify metric name: grep -i in_errors in Prometheus label browser.
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

### Remove Grafana alerting provisioning files

After creating the Prometheus rules and Alertmanager config, **delete or empty** these
files from `grafana/provisioning/alerting/`:

- `xrd-alert-rules.yaml` — rules moved to `prometheus/rules/xrd-alerts.yaml`
- `xrd-notification-policy.yaml` — routing moved to Alertmanager
- `xrd-contact-points.yaml` — webhook contact point moved to Alertmanager

Remove the Grafana volumes mount for the alerting directory from `compose.yaml`:

```yaml
# Remove this line from grafana volumes:
# - ./grafana/provisioning/alerting/:/etc/grafana/provisioning/alerting/:ro

# Remove from grafana environment:
# - WEBHOOK_RECEIVER_URL=${WEBHOOK_RECEIVER_URL:-http://webhook-receiver:8080/alert}
```

Also remove `WEBHOOK_RECEIVER_URL` from `compose.yaml` Grafana environment \u2014 it now
lives in `alertmanager/alertmanager.yaml` and the `WEBHOOK_RECEIVER_URL` env var is
read there (via Docker Compose env substitution).

### `webhook/schema.py` compatibility note

The existing `GrafanaWebhook` and `GrafanaAlert` Pydantic models already accept
Alertmanager's webhook format because `model_config = {"extra": "allow"}` is set on
both. No code changes to the webhook receiver are required.

One difference: Alertmanager does not include `values` (metric values at alert time).
The `metric_value` field in `NetworkAlert` will be `None` for all alerts. This is
expected \u2014 agents use gNMIBuddy to retrieve current metric values.

---

## Dashboard Annotation Checklist

Annotations are added to `grafana/dashboards/xrd/xrd-sr-overview.json` in
`annotations.list`. For each annotation, verify end-to-end:

1. **Verify the log pattern in Loki**: Grafana Explore \u2192 Loki \u2192 paste the LogQL filter.
   Confirm log lines appear after triggering the scenario.
2. **Test the regexp stage**: Add `| regexp ...` and use Grafana's label browser to
   confirm named groups resolve.
3. **Add to `annotations.list`** and reload the dashboard (bump `version` by 1).
4. **Trigger the scenario** and confirm the annotation appears within \u007e15s.

---

## Implementation Work Summary

### Files to create

| File                               | Purpose                                             |
| ---------------------------------- | --------------------------------------------------- |
| `alertmanager/alertmanager.yaml`   | Alertmanager config: routing, grouping, inhibition  |
| `prometheus/rules/xrd-alerts.yaml` | Prometheus alert rules (SC-01 through SC-04, SC-09) |

### Files to modify

| File                                          | Change                                                                                                                                                |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `compose.yaml`                                | Add Alertmanager service; add `WEBHOOK_RECEIVER_URL` env var to Alertmanager (remove from Grafana); remove Grafana alerting provisioning volume mount |
| `prometheus/prometheus.yaml`                  | Add `alerting:` section pointing to Alertmanager; add `rule_files:` section                                                                           |
| `grafana/provisioning/datasource.yaml`        | Add Alertmanager datasource (read-only display in Grafana UI)                                                                                         |
| `grafana/dashboards/xrd/xrd-sr-overview.json` | Add 4 annotations to `annotations.list` (BGP Change, Link Up/Down, System Events, ISIS already done)                                                  |

### Files to delete / empty

| File                                                         | Action                                 |
| ------------------------------------------------------------ | -------------------------------------- |
| `grafana/provisioning/alerting/xrd-alert-rules.yaml`         | Delete (rules moved to Prometheus)     |
| `grafana/provisioning/alerting/xrd-notification-policy.yaml` | Delete (routing moved to Alertmanager) |
| `grafana/provisioning/alerting/xrd-contact-points.yaml`      | Delete (webhook moved to Alertmanager) |

### Sequencing

1. **Alertmanager container** \u2014 add to `compose.yaml`, create `alertmanager/alertmanager.yaml`, `make restart`
2. **Prometheus rules** \u2014 create `prometheus/rules/xrd-alerts.yaml` with SC-01 and ISIS cascade; confirm alerts appear in Alertmanager UI at `:9093`
3. **Remove Grafana alerting files** \u2014 delete the three provisioning files, remove volume mount from `compose.yaml`, `make restart-grafana`
4. **Add BGP and stability rules** \u2014 append SC-02, SC-03, SC-04 to `prometheus/rules/xrd-alerts.yaml`; verify each fires on the expected trigger
5. **Add SC-09** \u2014 append topology-degraded rule; trigger by shutting two interfaces
6. **Dashboard annotations** \u2014 add BGP, Link Up/Down, System Events annotations to `xrd-sr-overview.json`; verify each appears during scenario
7. **Validate inhibition** \u2014 shut one interface; confirm only SC-01 reaches the webhook receiver (not SC-01 + ISIS adjacency-count simultaneously)

### Validation commands

```bash
# Confirm Alertmanager is running and reachable
curl -s http://localhost:9093/-/healthy

# Confirm Prometheus loaded the rules
curl -s http://localhost:9090/api/v1/rules | python3 -m json.tool | grep '"name"'

# Confirm alert fires and reaches Alertmanager
curl -s http://localhost:9093/api/v2/alerts | python3 -m json.tool

# Confirm webhook receiver gets the payload (send a test alert)
curl -s -X POST http://localhost:8080/alert \
  -H 'Content-Type: application/json' \
  -d '{"status":"firing","receiver":"test","alerts":[{"status":"firing","labels":{"alertname":"XRdInterfaceDown","severity":"critical","event_type":"interface_state","affected_object_type":"interface","source":"xrd-1","name":"GigabitEthernet0/0/0/0"},"annotations":{"summary":"test"},"startsAt":"2026-05-22T10:00:00Z","endsAt":"0001-01-01T00:00:00Z","fingerprint":"abc"}]}'
```

---

## Demo Scenario Matrix

| Scenario trigger            | Alerts fired (reach sp_oncall)         | Inhibited (visible in AM, not forwarded) | Agents investigate                    |
| --------------------------- | -------------------------------------- | ---------------------------------------- | ------------------------------------- |
| `shutdown` one interface    | SC-01 (interface_state)                | ISIS adjacency-count, SC-03 (flapping)   | Interface \u2192 ISIS \u2192 topology |
| Cascade \u22653 adjacencies | SC-01 + SC-09 (separate groups)        | ISIS adjacency-count                     | Device + topology-wide                |
| BGP session drops           | SC-02 (bgp_session_state)              | \u2014                                   | BGP neighbors \u2192 routing          |
| Repeated `shut/no shut`     | SC-03 (interface_flapping), then SC-01 | SC-03 inhibited once SC-01 fires         | Interface stability \u2192 peers      |

---

## Appendix: XR Syslog Mnemonic Reference

| Mnemonic          | Facility pattern        | Meaning                    |
| ----------------- | ----------------------- | -------------------------- |
| `ADJCHANGE`       | `ROUTING-ISIS-5`        | ISIS adjacency up/down     |
| `ADJCHANGE`       | `ROUTING-BGP-5`         | BGP session up/down        |
| `UPDOWN`          | `PKT_INFRA-LINK-3`      | Physical link state change |
| `UPDOWN`          | `PKT_INFRA-LINEPROTO-5` | Line protocol change       |
| `NOTIFICATION`    | `ROUTING-BGP-3`         | BGP NOTIFICATION error     |
| `NSR_PEER_LOST`   | `ISIS-5`                | ISIS NSR peer lost         |
| `REALLOC_FAILURE` | `MPLS_LSD-3`            | MPLS label alloc failure   |
| `ENVMON` patterns | `PLATFORM-*`            | Temperature / power events |

> Confirm actual mnemonics by searching live Loki:
> `{job="xrd-syslog"} | regexp "%(?P<facility>[A-Z0-9_]+-[A-Z0-9_]+)-(?P<xr_severity>[0-7])-(?P<mnemonic>[A-Z0-9_]+)" | label_format event="{{.facility}}-{{.mnemonic}}" | line_format "{{.event}}"`
