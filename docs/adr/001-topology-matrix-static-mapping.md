# ADR-001: Topology Matrix Panels Use Static Label Mapping

**Status:** Accepted  
**Date:** 2026-05-21

## Context

The XRd SR Topology Overview dashboard needs matrix panels showing ISIS neighborship as a device×device grid. The raw Prometheus metric uses ISIS system IDs (`0100.0100.010X`) rather than human-readable device names.

Two approaches were considered:

- **Dynamic**: Use a recording rule or external service to maintain a system-ID-to-device-name mapping table.
- **Static (Level A)**: Use PromQL `label_replace` with a regex that converts the predictable system ID pattern to device names at query time.

## Decision

We use **static `label_replace`** in the ISIS Neighborship Matrix panel query:

```promql
label_replace(
  <metric>,
  "neighbor_device", "xrd-$1",
  "neighbor_neighbor_system_id", "0100\\.0100\\.010(.)"
)
```

This relies on the convention that ISIS system IDs follow the pattern `0100.0100.010X` where `X` is the device number in `xrd-X`.

## Consequences

### Must update on topology changes

If the lab topology changes (devices added/removed, system IDs renumbered), the following must be updated:

1. **ISIS Matrix panel** (id:302) — the `label_replace` regex pattern
2. **ISIS Adjacency State panel** (id:21) — the hardcoded 12-pair `or vector(0)` query. Each pair is encoded as two metric selectors (one per side) plus a `label_replace(vector(0), ...)` fallback that keeps the row visible as DOWN when XR removes the neighbor from its YANG table on adjacency loss.
3. **Network Topology flow panel** (id:200) — the SVG topology diagram and panelConfig metric mappings
4. **Link status queries** in the flow panel — static `label_replace` per-link expressions

### Why this is acceptable

- This is a lab/demo environment with a fixed 8-device topology
- Changes are infrequent (topology only changes between Cisco Live events)
- The regex approach is simple and self-contained (no external dependencies)
- A single regex handles all 8 devices vs 24 nested `label_replace` calls that would be needed for interface-based mapping

### Trade-offs

| Aspect       | Static (chosen)                  | Dynamic (rejected)                    |
| ------------ | -------------------------------- | ------------------------------------- |
| Maintenance  | Manual update on topology change | Self-healing                          |
| Complexity   | Single regex in PromQL           | Recording rules + relabeling pipeline |
| Dependencies | None                             | Prometheus recording rules            |
| Latency      | Instant                          | Depends on rule evaluation interval   |
| Suitability  | Fixed lab topology               | Production with frequent changes      |
