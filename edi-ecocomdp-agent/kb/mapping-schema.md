# `mapping.yaml` — Schema Reference

The mapping spec is the contract between the reasoning skills and the renderer. It is
the primary curator review surface: everything the generated R script does should be
traceable to a line here.

**Rules**
- Every column named in the spec must exist in `profile.json` (or be created by an
  earlier step in the same spec).
- `derived_id` is **always null** from the agent — the curator assigns it (policy).
- Never invent an annotation URI. Absent from the lexicon ⇒ leave `id: null` and note it.
- Anything guessed, assumed, or ambiguous goes in `open_questions`, not into a silent
  default.

---

## Top level

| Key | Type | Required | Notes |
|---|---|---|---|
| `source_id` | string | yes | EDI package id, e.g. `knb-lter-jrn.210007001.38` |
| `derived_id` | null | yes | Always `null`; curator fills |
| `source_tables` | map | yes | See below |
| `flatten` | map | yes | See below |
| `observation` | map | yes | Core table mapping |
| `location` | map | yes | |
| `taxon` | map | yes | |
| `ancillary` | map | no | Empty lists are fine |
| `annotations` | map | no | |
| `open_questions` | list | yes | May be empty, but must be present |

---

## `source_tables`

```yaml
source_tables:
  <alias>:
    file: JRN007001_lizard_pitfall_data_89-06.csv
    entity_name: Lizard pitfall data file    # from EML <entityName>
    grain: individual_capture                # one row = ?
```

`grain` is free text but should say what one row *is*. It drives pattern selection —
`individual_capture` implies P4, `taxon_event` implies P2/P3.

---

## `flatten`

```yaml
flatten:
  pattern: aggregate_individuals_to_counts   # P1..P4 from kb/patterns.md
  joins:
    - left: lizards
      right: codes
      by: {spp: code}          # left_col: right_col
      cardinality: many_to_one  # assert; fan-out is a silent corruption
  aggregate:                    # P4 only
    group_by: [date, zone, site, plot, spp]
    value: n()
    variable_name: count
    unit: number
  pivot:                        # P1/P2 only
    cols: [N_SNAILS, N_SLUGS]
    names_to: [".value", "taxon_name_verbatim"]
    names_sep: "\\."
```

Use `aggregate` **or** `pivot`, not both. `joins` may be empty (single-table sources).

---

## `observation`

```yaml
observation:
  observation_id: row_number         # always; seq(nrow(flat))
  event_id:    {group_by: [date, site], rationale: "..."}
  location_id: {group_by: [zone, site, plot], rationale: "..."}
  datetime: date                     # source column, renamed to `datetime`
  taxon_id: {group_by: [taxon_name]}
  variable_name: variable_name
  value: value
  unit: unit
```

`rationale` is **required** on `event_id` and `location_id`. These are the two highest-risk
decisions in the whole conversion (see `kb/patterns.md` § Cross-cutting) and an
unjustified grouping should fail review.

---

## `location`

```yaml
location:
  location_name: [zone, site, plot]     # coarse → fine; builds parent_location_id
  latitude:  {source: eml_geographic_coverage}   # or a column name
  longitude: {source: eml_geographic_coverage}
```

When coordinates come from EML `<geographicCoverage>` rather than a data column, the
renderer emits the `xml2` extraction block (the corpus does this in 10/15 scripts —
bounding boxes averaged to a point).

---

## `taxon`

```yaml
taxon:
  names_from: {table: codes, column: scientific_name}
  resolver: resolve_sci_taxa      # or resolve_comm_taxa
  data_sources: [3]               # 3 = ITIS
  suspicious_names:               # flagged, not resolved — v1 cannot run R
    - {name: "UNKN", reason: "unknown-taxon placeholder"}
    - {name: "Aspidoscelis sp.", reason: "genus-level qualifier"}
```

---

## `ancillary`

```yaml
ancillary:
  observation: [sex, rcap, SV_length]
  location: [zone]
  taxon: [spp]
  units:                          # optional unit_ columns, per corpus convention
    observation: [unit_SV_length]
```

A column may not appear both here and as a core column in `observation`.

---

## `annotations`

```yaml
annotations:
  variable_mapping:
    count:
      system: Darwin Core
      id: http://rs.tdwg.org/dwc/terms/individualCount
      label: individualCount
      source: lexicon             # lexicon | curator | null
    sex:
      system: null
      id: null                    # not in lexicon — curator must fill
      label: null
      source: null
  is_about:
    species abundance: http://purl.dataone.org/odo/ECSO_00001688
```

`source: lexicon` means the URI was looked up in `kb/lexicon-*.csv`. Any entry with
`id: null` must have a matching line in `open_questions`.

---

## `open_questions`

```yaml
open_questions:
  - id: recaptures
    question: "Filter rcap == 'Y' before aggregating to counts?"
    why_escalated: "Changes every count in the output; scientific judgement about
      what the abundance measure represents. Curator policy: always escalate."
    blocking: true
```

`blocking: true` means the spec should not be rendered to R until answered.
