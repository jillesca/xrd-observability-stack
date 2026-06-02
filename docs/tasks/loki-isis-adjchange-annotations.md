# Task: Loki ADJCHANGE Log → Grafana Annotations

## Goal

Parse XR syslog `%ROUTING-ISIS-5-ADJCHANGE` messages already in Loki and surface them as structured Grafana annotations on the **ISIS Adjacency State** status-history panel (id:21) in `grafana/dashboards/xrd/xrd-sr-overview.json`.

## Why

The XR gNMI telemetry subscription (`xrd-isis-adjacency`, stream/on_change) does **not** emit a DOWN value when an adjacency drops — it removes the YANG list entry entirely. The status-history panel handles this via a `or vector(0)` fallback (see ADR-001, panel id:21). However, the panel has no precise event timestamp or reason for the failure.

The syslog stream (Loki job `xrd-syslog`) already captures the exact moment and cause. Example messages:

```
2026-05-22T10:17:25Z xrd-4 isis[1003]: %ROUTING-ISIS-5-ADJCHANGE : ISIS (1): Adjacency to xrd-3 (GigabitEthernet0/0/0/0) (L2) Down, Interface state down
2026-05-22T10:17:49Z xrd-3 isis[1003]: %ROUTING-ISIS-5-ADJCHANGE : ISIS (1): Adjacency to xrd-4 (GigabitEthernet0/0/0/0) (L2) Down, Holdtime expired
```

## Log format

Syslog severity 5 (notice), facility `ROUTING-ISIS`. The relevant fields in the message body:

| Field            | Example value                               |
| ---------------- | ------------------------------------------- |
| Reporting device | `xrd-3` (from `hostname` label in Loki)     |
| Neighbor name    | `xrd-4`                                     |
| Interface        | `GigabitEthernet0/0/0/0`                    |
| Level            | `L2`                                        |
| Direction        | Down (or Up)                                |
| Reason           | `Holdtime expired` / `Interface state down` |

## Proposed implementation

### 1 — Grafana annotation query on the panel

Add a Loki annotation query to the **ISIS Adjacency State** panel (or as a dashboard-level annotation) that fires on any ADJCHANGE message:

```logql
{job="xrd-syslog"} |~ `%ROUTING-ISIS-5-ADJCHANGE`
```

Use Grafana's annotation `titleFormat` / `textFormat` with label extraction to display the reason and devices involved.

### 2 — Structured label extraction (optional but recommended)

Add a LogQL pipeline to extract fields as labels so they can be used in annotation text:

```logql
{job="xrd-syslog"}
  |~ `%ROUTING-ISIS-5-ADJCHANGE`
  | regexp `Adjacency to (?P<neighbor>\S+) \((?P<interface>[^)]+)\) \((?P<level>L[12])\) (?P<direction>Down|Up), (?P<reason>.+)`
```

This gives labels: `neighbor`, `interface`, `level`, `direction`, `reason`.

Annotation title: `ISIS {{direction}}: {{hostname}} → {{neighbor}}`  
Annotation text: `Interface: {{interface}} | Reason: {{reason}}`

### 3 — Panel-scoped vs dashboard-scoped

- **Dashboard-scoped**: annotation appears on all panels. Easy to add via `grafana/dashboards/xrd/xrd-sr-overview.json` → `annotations.list`.
- **Panel-scoped**: annotation only on the ISIS Adjacency State panel. Requires Grafana 10+ panel-level annotation support.

Recommendation: start with dashboard-scoped (simpler), then scope to panel once validated.

## Files to modify

- `grafana/dashboards/xrd/xrd-sr-overview.json` — add an annotation query to the `annotations.list` array at the top of the JSON, using Loki datasource.

## Acceptance criteria

1. When xrd-X shuts an interface with ISIS configured, a vertical annotation line appears on the ISIS Adjacency State status-history panel within one Loki scrape cycle (~15s).
2. Hovering the annotation shows the reporting device, neighbor, interface, and failure reason.
3. Both sides of the link produce annotations (with different reasons: "Interface state down" vs "Holdtime expired").
4. Annotations survive a Grafana restart (query is provisioned in the dashboard JSON, not added manually via the UI).
