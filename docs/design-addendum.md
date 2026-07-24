# Design Addendum — Dashboard UX, CPU Tuning, Log Pipeline

## Purpose

This document is an implementation guide for AI agents. It extends [design.md](design.md) with two improvement phases decided after the initial implementation was validated end-to-end. Work on each phase independently.

**Constraints**:

- Do not touch existing SRL/EOS config (already commented out).
- Do not modify `compose.yaml` networks or service definitions unless explicitly instructed.
- XPaths marked **[VERIFY]** must be tested with `gnmic get` or by checking Prometheus for existing metrics before building a panel. If a path returns no data on XRd 25.3.1, skip it and add a note to `BLOCKERS.md`.
- If you encounter a constraint not covered here, document it in `BLOCKERS.md` at the repo root and stop.

---

## Changes Already Made (do not repeat)

These were applied during the grill session and are already in the repo:

| File                        | Change                                                      |
| --------------------------- | ----------------------------------------------------------- |
| `gnmic/gnmic-emitter.yaml`  | `nats-srl` and `nats-eos` inputs + processors commented out |
| `gnmic/gnmic-ingestor.yaml` | `xrd-if-stats` sample-interval `10s` → `30s`                |
| `gnmic/gnmic-ingestor.yaml` | `nats-srl-out` and `nats-eos-out` outputs commented out     |
| `alloy/config.alloy`        | Added `severity` label relabeling alongside `hostname`      |
| `DESIGN.md`                 | Updated §2.1 to reflect Loki only in VM compose, not base   |

---

## Phase 5: Dashboard UX Improvements

**Goal**: Make `xrd-sr-overview` human-readable for a Cisco Live demo audience and generally useful for network operators. Replace confusing panels, add missing context, fix the broken log panel.

**Done when**:

- Grafana at `:3000` shows the `xrd-sr-overview` dashboard with all changes below applied.
- The "Alert Scenario" row clearly visualises an interface-down event and the resulting ISIS adjacency cascade when triggered manually.
- The logs panel shows XRd syslog entries (severity notice and above) when events occur.
- No panel shows "No data" for reasons other than a healthy, quiet network.

### 5.0 Prerequisites

`alloy/config.alloy` already exports `hostname` and `severity` as Loki labels (done). If running in split mode, run `make vm-deploy` before testing the log panel so Alloy picks up the config change.

---

### 5.1 Dashboard metadata changes

File: `grafana/dashboards/xrd/xrd-sr-overview.json`

- Add `"Alert Scenario"` to the `tags` array → `["xrd", "segment-routing", "cisco-live", "alert-scenario"]`
- Keep `refresh: 10s`, `time: last 30 minutes`, `timezone: browser`.

---

### 5.2 Row 1 — Network Health (add "Devices Monitored")

Add one new stat panel **before** the existing Interfaces UP/DOWN panels:

| Field       | Value                                                                                             |
| ----------- | ------------------------------------------------------------------------------------------------- |
| Title       | `Devices Monitored`                                                                               |
| Type        | `stat`                                                                                            |
| Datasource  | Prometheus                                                                                        |
| Query       | `count(count by (source) (openconfig_interfaces_interface_state_oper_status{source=~"$device"}))` |
| Unit        | `short` (no unit suffix)                                                                          |
| Color mode  | `fixed` — green (`#73BF69`)                                                                       |
| Description | Total number of XRd devices actively reporting telemetry                                          |

No other changes to Row 1.

---

### 5.3 Row 2 — Alert Scenario (NEW ROW, insert after Row 1)

This row is the demo centrepiece. It shows an interface going down and the ISIS adjacency cascade that follows. Insert it as the second row, before the existing Interfaces row.

**Row panel**: `title: "Alert Scenario"`, `collapsed: false`

#### Panel A — Interface State (Alert Scenario)

Replaces the existing `Interface State per Device` panel (which moves to this row in improved form). The original panel in the Interfaces row should be **removed** (see §5.5).

| Field          | Value                                                                                                 |
| -------------- | ----------------------------------------------------------------------------------------------------- |
| Title          | `Interface State`                                                                                     |
| Type           | `state-timeline`                                                                                      |
| Datasource     | Prometheus                                                                                            |
| Query          | `openconfig_interfaces_interface_state_oper_status{source=~"$device", name!~"Loopback.*\|MgmtEth.*"}` |
| Legend         | `{{source}} {{name}}`                                                                                 |
| Value mappings | `1` → `UP` (green `#73BF69`); `0` → `DOWN` (red `#F2495C`)                                            |
| Height         | 8 grid units                                                                                          |

#### Panel B — [OPTION A] ISIS Adjacency State (timeline)

Collapsed state-timeline showing one row per unique source→neighbour pair. Dropping the local interface dimension reduces rows from ~30 to ~16, making the cascade readable at a glance.

| Field          | Value                                                                                                                                                     |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Title          | `[OPTION A] ISIS Adjacency State — per neighbour pair`                                                                                                    |
| Type           | `state-timeline`                                                                                                                                          |
| Datasource     | Prometheus                                                                                                                                                |
| Query          | `max by (source, neighbor_neighbor_system_id) (Cisco_IOS_XR_clns_isis_oper_isis_instances_instance_neighbors_neighbor_neighbor_state{source=~"$device"})` |
| Legend         | `{{source}} → {{neighbor_neighbor_system_id}}`                                                                                                            |
| Value mappings | `1` → `UP` (green); `0` → `DOWN` (red)                                                                                                                    |

#### Panel C — [OPTION B] ISIS Adjacency Count (timeseries)

Alternative to Option A. Shows a single line dropping from N to N-x — simpler but loses per-neighbour detail.

| Field        | Value                                                                                                                  |
| ------------ | ---------------------------------------------------------------------------------------------------------------------- |
| Title        | `[OPTION B] ISIS Adjacencies UP — count over time`                                                                     |
| Type         | `timeseries`                                                                                                           |
| Datasource   | Prometheus                                                                                                             |
| Query        | `count(Cisco_IOS_XR_clns_isis_oper_isis_instances_instance_neighbors_neighbor_neighbor_state{source=~"$device"} == 1)` |
| Legend       | `Adjacencies UP`                                                                                                       |
| Fill opacity | `20`                                                                                                                   |
| Line color   | green (`#73BF69`)                                                                                                      |
| Thresholds   | none (count is the story)                                                                                              |

> **Note for demo operator**: keep both Option A and Option B panels on the dashboard. During the demo, scroll to whichever is clearer for the live audience. Remove the less useful one after Cisco Live.

---

### 5.4 Row 3 — Interfaces (improvements to existing row)

#### TX Rate and RX Rate — fix legend to show interface name

Current legend for both panels is auto-generated from the metric labels, which repeats the device name without showing the interface. Update both panels:

| Panel           | Change                                     |
| --------------- | ------------------------------------------ |
| `TX Rate (bps)` | Set legend format to `{{source}} {{name}}` |
| `RX Rate (bps)` | Set legend format to `{{source}} {{name}}` |

#### Remove Interface State per Device

Remove the `Interface State per Device` panel from this row — it has been replaced by the improved version in §5.3 Panel A.

#### Add Interface Errors panel (NEW)

Uses `in_errors` and `out_errors` already collected by `xrd-if-stats` via the OC `/interfaces/interface[name=*]/state/counters` subscription — no new subscription needed.

| Field          | Value                                                                                                                   |
| -------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Title          | `Interface Errors`                                                                                                      |
| Type           | `timeseries`                                                                                                            |
| Datasource     | Prometheus                                                                                                              |
| Query A        | `rate(openconfig_interfaces_interface_state_counters_in_errors{source=~"$device", name!~"Loopback.*\|MgmtEth.*"}[5m])`  |
| Query A legend | `{{source}} {{name}} RX errors`                                                                                         |
| Query B        | `rate(openconfig_interfaces_interface_state_counters_out_errors{source=~"$device", name!~"Loopback.*\|MgmtEth.*"}[5m])` |
| Query B legend | `{{source}} {{name}} TX errors`                                                                                         |
| Unit           | `pps`                                                                                                                   |

> If `openconfig_interfaces_interface_state_counters_in_errors` does not exist in Prometheus (check with label browser), try `openconfig_interfaces_interface_state_counters_in_discards` as a fallback. Note the substitution in `BLOCKERS.md`.

#### Add Interface Flaps panel (NEW)

Derives state-change count from existing data using the Prometheus `changes()` function. No new subscription needed.

| Field       | Value                                                                                                                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------------ |
| Title       | `Interface State Changes (flaps)`                                                                                        |
| Type        | `timeseries`                                                                                                             |
| Datasource  | Prometheus                                                                                                               |
| Query       | `changes(openconfig_interfaces_interface_state_oper_status{source=~"$device", name!~"Loopback.*\|MgmtEth.*"}[$__range])` |
| Legend      | `{{source}} {{name}}`                                                                                                    |
| Unit        | `short`                                                                                                                  |
| Description | Number of up/down transitions in the selected time window. Useful for detecting unstable interfaces.                     |

---

### 5.5 Row 4 — ISIS (keep, remove FRR panel)

**Remove** the `ISIS FRR Protected Routes` panel. There is no FRR configuration in this topology; the panel always shows "No data."

Keep the existing `ISIS Adjacency State` panel (full per-interface detail version) — it provides deeper investigation context beyond what Row 2 shows.

No other changes to this row.

---

### 5.6 Row 5 — BGP (replace established-time, add messages and prefixes)

#### Replace BGP Session Established Time

Remove the `BGP Session Established Time` panel. It shows a monotonically increasing counter that conveys nothing when sessions are stable and is confusing to a demo audience.

#### Add BGP Messages Received panel (NEW, uses existing subscription)

The `xrd-bgp-stats` subscription already collects `message-statistics`. Before building this panel, query Prometheus to find the exact metric name:

```bash
curl -s 'http://localhost:9090/api/v1/label/__name__/values' | python3 -m json.tool | grep -i 'bgp.*message\|bgp.*update'
```

Build the panel using the metric name for update messages received. Expected metric pattern:
`Cisco_IOS_XR_ipv4_bgp_oper_bgp_instances_instance_instance_active_default_vrf_neighbors_neighbor_message_statistics_update_messages_received`

| Field      | Value                                                             |
| ---------- | ----------------------------------------------------------------- |
| Title      | `BGP Update Messages Received`                                    |
| Type       | `timeseries`                                                      |
| Datasource | Prometheus                                                        |
| Query      | `rate(<metric_name_for_updates_received>{source=~"$device"}[5m])` |
| Legend     | `{{source}} → {{neighbor_neighbor_address}}`                      |
| Unit       | `short`                                                           |

If the metric name differs from the expected pattern, use whatever name Prometheus reports. If no BGP message metrics exist at all, skip this panel and note it in `BLOCKERS.md`.

#### Add BGP Prefixes Received panel (NEW, requires new subscription) **[VERIFY]**

This requires adding a new gNMI subscription path. Follow these steps in order:

**Step 1 — Verify the path works on XRd 25.3.1:**

```bash
docker exec gnmic-ingestor gnmic -a 10.10.20.101:57400 -u cisco -p C1sco12345 --insecure get \
  --path "Cisco-IOS-XR-ipv4-bgp-oper:bgp/instances/instance[instance-name=default]/instance-active/default-vrf/neighbors/neighbor[neighbor-address=100.100.100.107]/af-data"
```

If the path returns data (JSON with prefix counts), proceed. If it returns an error, try:
`Cisco-IOS-XR-ipv4-bgp-oper:bgp/instances/instance[instance-name=default]/instance-active/default-vrf/neighbors/neighbor`
and look for `af-data` within the response to find the correct sub-path. If no prefix data is available, skip this panel and note it in `BLOCKERS.md`.

**Step 2 — Add subscription to `gnmic/gnmic-ingestor.yaml`** (only if Step 1 succeeded):

```yaml
# BGP prefix counts per neighbour — XR native YANG
xrd-bgp-prefixes:
  mode: stream
  stream-mode: sample
  sample-interval: 30s
  paths:
    - Cisco-IOS-XR-ipv4-bgp-oper:bgp/instances/instance[instance-name=default]/instance-active/default-vrf/neighbors/neighbor[neighbor-address=*]/af-data
  outputs:
    - nats-xrd-out
```

Add `- xrd-bgp-prefixes` to the `subscriptions` list of all 8 targets in the targets block.

**Step 3 — Build the panel** (only after data appears in Prometheus):

| Field      | Value                                                                                              |
| ---------- | -------------------------------------------------------------------------------------------------- |
| Title      | `BGP Prefixes Received per Neighbour`                                                              |
| Type       | `timeseries`                                                                                       |
| Datasource | Prometheus                                                                                         |
| Query      | `<metric_for_accepted_prefixes>{source=~"$device"}` (find exact name via Prometheus label browser) |
| Legend     | `{{source}} → {{neighbor_neighbor_address}}`                                                       |
| Unit       | `short`                                                                                            |

#### BGP Session State — improve legend

In the existing `BGP Session State` state-timeline panel, update the legend format to `{{source}} → {{neighbor_neighbor_address}}` for clarity.

---

### 5.7 Row 8 — Logs (fix broken panel query)

The existing panel query uses `|= \`$device_filter\`` which performs a literal substring match. When the `$device`variable is set to "All",`$device*filter`resolves to the regex`.*`, and `|= ".\_"`searches for the literal string`.\*` in log lines — no match, empty panel.

**Fix the panel query** to use the `hostname` Loki label (now available after the Alloy config change in §Prerequisite):

| Field       | Value                                                                                                                            |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Title       | `XRd Syslog — Notice and above`                                                                                                  |
| Type        | `logs`                                                                                                                           |
| Datasource  | Loki                                                                                                                             |
| Query       | `{job="xrd-syslog", hostname=~"$device", severity=~"emergency\|alert\|critical\|error\|warning\|notice"}`                        |
| Description | Shows severity 5 (notice) and above. Captures: `%LINK-3-UPDOWN`, `%LINEPROTO-5-UPDOWN`, `%ISIS-5-ADJ_CHANGE`, `%BGP-5-NBR_RESET` |

> **Note on severity values**: Alloy maps RFC5424 numeric priority to textual severity labels. Expected values: `emergency`, `alert`, `critical`, `error`, `warning`, `notice`, `informational`, `debug`. If the severity label values differ (check with Loki label browser at Grafana → Explore → label browser for `job=xrd-syslog`), adjust the regex accordingly.

Remove the `$device_filter` template variable from the dashboard if it is no longer used elsewhere after this change.

---

## Phase 6: CPU Tuning Investigation

**Context**: Before the Phase 5 fixes, `podman stats` showed `gnp-stack-nats-1` at ~69% CPU and `gnp-stack-gnmic-emitter-1` at ~88% CPU sustained on an M2 MacBook Pro with 8 XRd devices.

**Changes already applied** (do not repeat):

- SRL/EOS inputs, processors, and NATS outputs all commented out → frees 512 MB of in-memory NATS stream allocation and removes 2 idle consumer polling loops.
- `xrd-if-stats` interval 10s → 30s → 3× reduction in the highest-frequency subscription.

**Goal of this phase**: Measure whether the above changes sufficiently reduce CPU. If not, investigate `strings-as-labels` cardinality and add container CPU limits as a safety cap.

**Done when**: `podman stats` shows both `gnp-stack-nats-1` and `gnp-stack-gnmic-emitter-1` below 30% CPU sustained during normal operation (no active alerts).

### 6.1 Measure first

After `make restart`:

```bash
# Watch for 2 minutes
podman stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | grep -E 'nats|emitter'
```

If both are below 30% — this phase is complete, no further action needed.

If emitter is still above 50% — proceed to §6.2.

### 6.2 Investigate strings-as-labels cardinality

In `gnmic/gnmic-emitter.yaml`, the `prom-write` output has `strings-as-labels: true`. This converts every string field in every XR native YANG event into a Prometheus label. XR native YANG key hierarchies are long, which can produce thousands of unique label combinations and keep the emitter busy serializing them continuously.

**Step 1 — Count current Prometheus time series**:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_head_series' | python3 -m json.tool
```

If the series count is above 20,000 for 8 devices, `strings-as-labels` is likely the cause.

**Step 2 — Test with strings-as-labels disabled**:

In `gnmic/gnmic-emitter.yaml`, change `strings-as-labels: true` to `strings-as-labels: false` and restart the emitter only:

```bash
podman restart gnp-stack-gnmic-emitter-1
```

Check that the key dashboard panels still work (interface state, ISIS adjacency state, BGP session state). These depend on string→integer mapping done by the `xrd-state-to-int` processor, not on `strings-as-labels`, so they should be unaffected.

If CPU drops significantly with `strings-as-labels: false`, keep it disabled. If any panel breaks, identify which string field it needs and add a targeted `event-strings` processor to preserve only that field, then re-enable `strings-as-labels: false`.

### 6.3 Add CPU limits as a safety cap (if 6.2 is insufficient)

If CPU is still high after §6.2, add resource limits in `compose.yaml` to prevent the containers from starving the laptop during the demo:

```yaml
nats:
  deploy:
    resources:
      limits:
        cpus: "1.0"
        memory: 512M

gnmic-emitter:
  deploy:
    resources:
      limits:
        cpus: "1.0"
        memory: 256M
```

> **Warning**: CPU limits may cause backpressure. After applying, confirm that Prometheus still receives metrics and that no "slow consumer" warnings appear in emitter logs:
> `podman logs gnp-stack-gnmic-emitter-1 2>&1 | grep -i "slow\|backpressure\|drop"`

---

## Topology Reference

```
              xrd-7 (PCE)
             /           \
          xrd-3 ------- xrd-4
           / |               | \
src -- xrd-1 |               | xrd-2 -- dst
           \ |               | /
          xrd-5 ------- xrd-6
             \           /
              xrd-8 (vRR)
```

Physical interfaces per device: 3–5 GigabitEthernet + 1 MgmtEth + Loopbacks.
All dashboard interface filters exclude `Loopback.*` and `MgmtEth.*`.
