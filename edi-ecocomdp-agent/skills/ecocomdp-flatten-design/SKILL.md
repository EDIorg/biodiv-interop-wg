---
name: ecocomdp-flatten-design
description: Design the mapping spec (mapping.yaml) that describes how an EDI source dataset flattens into the ecocomDP model — selecting a flattening pattern, join strategy, and the event_id/location_id groupings. Use after a suitability verdict and before rendering the R script.
---

# Mapping Spec Design

Produce `mapping.yaml` — the declarative contract the renderer turns into R. This is the
reasoning core of the workflow; the renderer downstream is mechanical, so any judgement
must be made and justified *here*.

## Read first

- `profile.json` — what the source contains
- `suitability.md` — the caveats you must carry forward
- `kb/patterns.md` — the flattening pattern library
- `kb/mapping-schema.md` — the exact schema you are writing

## Procedure

### 1. Select a flattening pattern

Match the source grain to a pattern in `kb/patterns.md`:

| Grain | Pattern |
|---|---|
| One column per taxon | **P1** species-as-columns |
| One row per taxon-event, several measures | **P2** multi-measure wide |
| Tidy long + taxon lookup table | **P3** already-long |
| One row per individual organism | **P4** individual records |

If the source matches none, say so explicitly in NOTES.md and describe the shape. Do not
force a bad fit — a new pattern documented honestly is more useful than a mangled
existing one. (P4 itself is off-corpus; the library grows.)

### 2. Plan the joins

For each join, record `left`, `right`, `by`, and **`cardinality`**. Assert
many-to-one where you expect it. A duplicated key on the "one" side silently multiplies
observation rows — a corruption that validates cleanly and is nearly invisible in review.
Check unique counts in `profile.json` to verify, and flag it if you cannot.

### 3. Decide `location_id` — and justify it

Group by the finest spatial unit observations are attributed to. If the source has a
hierarchy, list `location_name` **coarse → fine**; `create_location()` builds the
`parent_location_id` nesting:

```yaml
location:
  location_name: [zone, site, plot]
```

`rationale` is required. Write what a reviewer needs to check it, not a restatement:
"observations are per-pitfall-trap, but traps are unlabelled in the data; plot is the
finest identifiable unit" — not "grouped by plot".

### 4. Decide `event_id` — and justify it

One sampling event = one visit to one place at one time, as the **methods section**
defines it. The corpus varies genuinely:

- `ntl.356`: `group_by(YEAR)` — annual survey
- `hbr.126`: `group_by(floor_date(DATE,"month"), WATERSHED)` — monthly per watershed

Read `methods_summary` in the profile before choosing. This and `location_id` are the two
decisions most likely to be wrong and least likely to be caught by validation. If the
methods are ambiguous, put it in `open_questions` rather than guessing confidently.

### 5. Map the remaining core columns

`observation_id` is always `row_number`. `datetime`, `taxon_id`, `variable_name`,
`value`, `unit` come from the pattern. For P4, `variable_name`/`unit` are constants you
introduce (`count` / `number`).

### 6. Assign ancillary columns

Everything informative that is not a core column:

- **observation_ancillary** — conditions of the sampling event (gear, effort, trap id)
- **location_ancillary** — stable site attributes (elevation, habitat, station km)
- **taxon_ancillary** — organism attributes (verbatim codes, functional group)

A column may not be both core and ancillary. Under P4, per-individual attributes are
destroyed by aggregation — do not list them as ancillary; raise the question instead.

### 7. Delegate taxon and annotations

Invoke `ecocomdp-taxon-resolve` for the `taxon:` block and `ecocomdp-annotate` for
`annotations:`. Both write into the same `mapping.yaml`.

### 8. Record open questions

Anything you assumed, guessed, or could not determine. Mark `blocking: true` if the spec
cannot be rendered without an answer. Curator policy makes recapture/individual-
deduplication semantics **always blocking**.

## Hard rules

- `derived_id` is always `null` — the curator assigns it.
- Every column named must exist in `profile.json`, or be created earlier in the spec.
- `rationale` on `event_id` and `location_id` is mandatory.
- Prefer an open question over a confident guess. The gate exists to catch these, and an
  unflagged assumption defeats it.

## Output

`mapping.yaml` per `kb/mapping-schema.md`, plus `NOTES.md` recording pattern choice,
grouping reasoning, and anything surprising about the source.
