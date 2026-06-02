# Phase 3: Dashboard Annotations

## Goal

Add five Loki-based annotations to `grafana/dashboards/xrd/xrd-sr-overview.json` so
that network events appear as vertical lines across the dashboard timeline.

This phase is **fully independent of Phases 1 and 2**. It can run in parallel with
Phase 2 validation by a separate agent. The only dependency is that Loki is running
and receiving XRd syslog (which is already the case in the baseline stack).

## Done when

1. The dashboard JSON parses without errors: `python3 -c "import json; json.load(open('grafana/dashboards/xrd/xrd-sr-overview.json'))"` exits 0.
2. Grafana reloads the dashboard (restart or dashboard version bump forces Grafana to re-read the provisioned file).
3. After triggering an interface shutdown on any XRd device, vertical annotation lines appear on the dashboard timeline within 15 seconds (one Loki scrape cycle).
4. Hovering an ISIS annotation shows the neighbor, interface, and failure reason.
5. `annotations.list` in the JSON has 6 entries: 1 built-in + 5 Loki.

## Constraints

- **Edit only** `grafana/dashboards/xrd/xrd-sr-overview.json`. Do not touch other files.
- The existing `"builtIn": 1` entry must remain unchanged and first in the array.
- Increment `"version"` from `3` to `4` at line 3009 so Grafana detects the change.
- All new annotation objects must be valid JSON — use the schema shown below exactly.
- Test the LogQL queries in the Loki Explore tab before finalising.

---

## Background: existing annotations structure

The file currently has:

```json
"annotations": {
  "list": [
    {
      "builtIn": 1,
      "datasource": {"type": "grafana", "uid": "-- Grafana --"},
      "enable": true,
      "hide": true,
      "iconColor": "rgba(0, 211, 255, 1)",
      "name": "Annotations & Alerts",
      "type": "dashboard"
    }
  ]
}
```

Add the five new entries **after** the built-in entry.

---

## Annotation schema (template)

Every Loki annotation follows this shape:

```json
{
  "datasource": { "type": "loki", "uid": "loki" },
  "enable": true,
  "expr": "<LogQL query here>",
  "hide": false,
  "iconColor": "<hex colour>",
  "name": "<annotation name>",
  "step": "60s",
  "titleFormat": "<title template>",
  "textFormat": "<text template>",
  "tagKeys": "hostname,xr_severity",
  "useValueForTime": false
}
```

`{{` / `}}` in `titleFormat` and `textFormat` reference labels extracted by the
LogQL pipeline.

---

## Annotation 1: ISIS Adjacency Change

```json
{
  "datasource": { "type": "loki", "uid": "loki" },
  "enable": true,
  "expr": "{job=\"xrd-syslog\"} |~ `%ROUTING-ISIS-5-ADJCHANGE` | regexp `Adjacency to (?P<neighbor>\\S+) \\((?P<iface>[^)]+)\\) \\((?P<level>L[12])\\) (?P<direction>Down|Up), (?P<reason>.+)`",
  "hide": false,
  "iconColor": "#FF780A",
  "name": "ISIS Adjacency Change",
  "step": "60s",
  "titleFormat": "ISIS {{direction}}: {{hostname}} → {{neighbor}}",
  "textFormat": "Interface: {{iface}} | {{level}} | Reason: {{reason}}",
  "tagKeys": "hostname",
  "useValueForTime": false
}
```

**Verify this LogQL in Loki Explore first:**

```logql
{job="xrd-syslog"}
  |~ `%ROUTING-ISIS-5-ADJCHANGE`
  | regexp `Adjacency to (?P<neighbor>\S+) \((?P<iface>[^)]+)\) \((?P<level>L[12])\) (?P<direction>Down|Up), (?P<reason>.+)`
```

Expected to return entries like:

```
2026-05-22T10:17:25Z  hostname=xrd-4  neighbor=xrd-3  iface=GigabitEthernet0/0/0/0  level=L2  direction=Down  reason=Interface state down
```

---

## Annotation 2: BGP Adjacency Change

```json
{
  "datasource": { "type": "loki", "uid": "loki" },
  "enable": true,
  "expr": "{job=\"xrd-syslog\"} |~ `%ROUTING-BGP-[35]-ADJCHANGE|%BGP-[35]-ADJCHANGE` | regexp `(?P<bgp_facility>%[A-Z_]+-BGP-[0-9]+-ADJCHANGE).*neighbor (?P<neighbor>\\S+).*(?P<direction>Up|Down)`",
  "hide": false,
  "iconColor": "#5794F2",
  "name": "BGP Adjacency Change",
  "step": "60s",
  "titleFormat": "BGP {{direction}}: {{hostname}} → {{neighbor}}",
  "textFormat": "{{bgp_facility}}",
  "tagKeys": "hostname",
  "useValueForTime": false
}
```

**Verify this LogQL in Loki Explore:**

```logql
{job="xrd-syslog"} |~ `%ROUTING-BGP-[35]-ADJCHANGE|%BGP-[35]-ADJCHANGE`
```

If no results appear (BGP may not emit ADJCHANGE on IOS-XR 25.3.1 by default), try the
broader filter:

```logql
{job="xrd-syslog"} |~ `BGP.*neighbor.*[Uu]p|BGP.*neighbor.*[Dd]own`
```

Adjust the `expr` and `titleFormat`/`textFormat` to match the actual log format seen.

---

## Annotation 3: Interface Link Up/Down (syslog-based)

```json
{
  "datasource": { "type": "loki", "uid": "loki" },
  "enable": true,
  "expr": "{job=\"xrd-syslog\"} |~ `%PKT_INFRA-LINK-3-UPDOWN|%PKT_INFRA-LINEPROTO-5-UPDOWN` | regexp `Interface (?P<iface>\\S+),.*(?P<direction>changed state to [a-z]+)`",
  "hide": false,
  "iconColor": "#F2495C",
  "name": "Link Up/Down",
  "step": "60s",
  "titleFormat": "Link {{direction}}: {{hostname}} - {{iface}}",
  "textFormat": "{{iface}} {{direction}} on {{hostname}}",
  "tagKeys": "hostname",
  "useValueForTime": false
}
```

**Verify in Loki Explore:**

```logql
{job="xrd-syslog"} |~ `%PKT_INFRA-LINK-3-UPDOWN|%PKT_INFRA-LINEPROTO-5-UPDOWN`
```

Expected on interface shutdown:

```
%PKT_INFRA-LINK-3-UPDOWN : Interface GigabitEthernet0/0/0/0, changed state to Down
```

---

## Annotation 4: System/Platform Events (severity ≤ 3)

```json
{
  "datasource": { "type": "loki", "uid": "loki" },
  "enable": true,
  "expr": "{job=\"xrd-syslog\", severity=~\"[0-3]\"} |~ `%SYS-|%PLATFORM-` | regexp `%(?P<facility>[A-Z0-9_]+-[A-Z0-9_]+)-(?P<xr_sev>[0-3])-(?P<mnemonic>[A-Z0-9_]+)\\s*:\\s*(?P<body>.+)`",
  "hide": false,
  "iconColor": "#E02F44",
  "name": "System/Platform Events",
  "step": "60s",
  "titleFormat": "{{hostname}}: %{{facility}}-{{xr_sev}}-{{mnemonic}}",
  "textFormat": "{{body}}",
  "tagKeys": "hostname,severity",
  "useValueForTime": false
}
```

**Verify in Loki Explore:**

```logql
{job="xrd-syslog", severity=~"[0-3]"} |~ `%SYS-|%PLATFORM-`
```

Note: severity `0-3` in XR maps to Emergency/Alert/Critical/Error. These events should
be rare; the annotation should only appear for genuine problems.

---

## Annotation 5: MPLS LSD Events

```json
{
  "datasource": { "type": "loki", "uid": "loki" },
  "enable": true,
  "expr": "{job=\"xrd-syslog\"} |~ `%MPLS_LSD-[0-5]-` | regexp `%MPLS_LSD-(?P<xr_sev>[0-5])-(?P<mnemonic>[A-Z0-9_]+)\\s*:\\s*(?P<body>.+)`",
  "hide": false,
  "iconColor": "#FADE2A",
  "name": "MPLS Events",
  "step": "60s",
  "titleFormat": "MPLS {{hostname}}: {{mnemonic}}",
  "textFormat": "{{body}}",
  "tagKeys": "hostname",
  "useValueForTime": false
}
```

**Verify in Loki Explore:**

```logql
{job="xrd-syslog"} |~ `%MPLS_LSD-[0-5]-`
```

MPLS LSD events appear on SR label allocation/reallocation, which happens during IS-IS
SR prefix-SID programming. If no results appear at rest, trigger an ISIS topology change
(e.g., interface shutdown and restore) to generate MPLS label reallocation events.

---

## Editing instructions for `xrd-sr-overview.json`

The `annotations.list` array starts at line 3 of the file. The edit is:

1. Locate the closing `]` of the `annotations.list` array (after the built-in entry).
2. Replace that `]` with the five new annotation objects followed by `]`.

The resulting `annotations.list` must contain exactly 6 items in this order:

1. Built-in (unchanged, `"builtIn": 1`)
2. ISIS Adjacency Change
3. BGP Adjacency Change
4. Link Up/Down
5. System/Platform Events
6. MPLS Events

7. Increment `"version": 3` to `"version": 4` near the end of the file (line 3009).

---

## JSON validity check

After editing, validate:

```bash
python3 -c "import json; json.load(open('grafana/dashboards/xrd/xrd-sr-overview.json')); print('JSON valid')"
```

If it fails, the most common cause is un-escaped backslashes in the `expr` fields.
JSON requires `\\` inside strings for a literal backslash. The LogQL `\S+` in a JSON
string must be written as `\\S+`.

---

## Reload in Grafana

After editing the JSON, the dashboard needs to be reloaded. Grafana re-reads
provisioned dashboards on restart:

```bash
make restart-grafana
# or: docker compose restart grafana
```

Open the dashboard at `http://localhost:3000/d/xrd-sr-overview` and confirm the
Annotations list in Dashboard settings (⚙ → Annotations) shows all 5 new entries.

Trigger an interface change to verify annotations appear on the timeline.
