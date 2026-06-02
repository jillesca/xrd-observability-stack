# GNP-Stack Domain Glossary

This file is a glossary of canonical terms used in this project.
It does **not** contain implementation details, architecture decisions, or specs — those live in DESIGN.md and DESIGN-ADDENDUM.md.

---

## Terms

**Alert Scenario**
The demo sequence in which an XRd interface is manually brought down, producing a cascade of ISIS adjacency losses and triggering the Grafana alerting pipeline. Visualised in the "Alert Scenario" dashboard row.

**Devices Monitored**
The count of unique XRd devices that are actively reporting at least one telemetry metric to Prometheus at the time of query. Distinct from _devices configured_: a device is Monitored only while its gNMI subscription is healthy.

**Option A / Option B**
Two complementary views of the ISIS impact during an Alert Scenario. Option A is a status-history panel showing the 12 undirected adjacency pairs (e.g. `xrd-1 ↔ xrd-3`) as rows coloured green=UP / red=DOWN over time; Option B is a single timeseries counting total adjacencies UP over time. Both panels are kept on the dashboard so the operator can choose which to highlight for their audience.

**Interface Flap**
A single up→down or down→up transition on a physical interface. Measured with `changes()` over the selected time window. A stable topology has zero flaps; an unstable interface accumulates flaps rapidly.

**Subscription**
A gNMI stream configured in `gnmic-ingestor.yaml` that collects a specific YANG path from one or more XRd targets and forwards it to NATS JetStream. Each subscription has a mode (stream/sample), a sample-interval, and a list of target paths.

**Topology Matrix**
A table panel where rows represent source devices and columns represent a topology dimension (interface names, neighbor devices, or BGP peer IPs). Cell colour encodes state: green=UP/ESTABLISHED, red=DOWN, gray=not applicable. Provides at-a-glance topology health without reading individual time series.

**Static Label Mapping**
A PromQL `label_replace` pattern that derives human-readable labels (e.g., device names) from raw telemetry identifiers (e.g., ISIS system IDs). Called "static" because the mapping is hardcoded in the query and must be updated manually when the topology changes. See ADR-001.

**Grouping-to-Matrix Transformation**
A Grafana transformation (`groupingToMatrix`) that pivots flat table data (row-per-series) into a matrix layout by specifying which field becomes the row key, which becomes column headers, and which provides cell values.

**strings-as-labels**
A gnmic emitter setting (`strings-as-labels: true`) that promotes string-typed YANG leaves to Prometheus labels rather than dropping them. This is what makes labels like `local_interface`, `neighbor_neighbor_system_id`, and `neighbor_neighbor_address` available for matrix queries.
