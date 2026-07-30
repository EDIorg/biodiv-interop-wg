---
name: ecocomdp-script-render
description: Render an approved mapping.yaml into a create_ecocomDP.R conversion script following the corpus template, and run static consistency checks. Use only after the curator has reviewed and approved the mapping spec.
---

# Script Rendering

Turn an approved `mapping.yaml` into `create_ecocomDP.R`.

This step is **mechanical**. Every decision was made during spec design; if you find
yourself reasoning about what a column means, the spec is incomplete — go back and fix
the spec, not the script. A script that diverges from its spec breaks the review model,
because the curator approved the spec.

## Preconditions

Refuse to render if:

- `mapping.yaml` has any `open_questions` entry with `blocking: true` unanswered
- `derived_id` is still `null` (the curator assigns it — `config/curator.yml`
  `policy.derived_id_assignment: manual`)
- the curator has not approved the spec
- `validate_spec.py` exits non-zero (the spec has ERROR findings — see below).
  Fix `mapping.yaml`, never work around a spec error in the script.

Say which precondition failed and stop.

## Procedure

Fill `kb/script-template.R`. Slots:

| Slot | Source |
|---|---|
| `{{source_id}}`, `{{derived_id}}` | spec top level |
| `{{source_scope}}`/`{{source_identifier}}` | split the package id: `knb-lter-jrn.210007001.38` → scope `knb-lter-jrn`, identifier `210007001` |
| `{{read_entity_assignments}}` | one `readr::read_*()` over `EDIutils::read_data_entity()` per source table, selected by `entityName` |
| `{{units_block}}` | `add_unit_columns(flat, eml, "<entityName>")` — rebuilds `unit_<column>` |
| `{{flatten_block}}` | the pattern idiom from `kb/patterns.md`, with spec columns |
| `{{location_id_block}}`, `{{event_id_block}}` | `group_by(...) %>% group_indices()`, with the spec's `rationale` as a preceding comment |
| `{{location_block}}` | coordinate columns, or the `xml2` geographicCoverage extraction |
| `{{taxon_block}}` | resolver call from the taxon spec |
| `{{ancillary_blocks}}` | only the ancillary tables the spec declares |
| `{{annotation_assignments}}` | `variable_mapping$mapped_*` blocks |
| `{{contact_*}}`, `{{user_id}}`, `{{user_domain}}`, `{{basis_of_record}}` | `config/curator.yml` |

Carry each `rationale` from the spec into the script as a comment above the grouping it
justifies. The script should be readable standalone by someone who never saw the spec.

### Create the output destination

Create the directory `conversions/<source_id>/<derived_id>/`, named for the curator-assigned
`derived_id`. This is the **output path** for the converted result: when the curator runs
the script, `write_tables()` and `create_eml()` write the ecocomDP tables and derived EML
here. It exists only after `derived_id` is assigned, which is why it is created now and not
at fetch. The agent does not run the script, so the agent leaves it empty — say so.

Record the intended invocation in `NOTES.md` so the curator knows the path convention:

```r
create_ecocomDP(
  path       = "conversions/<source_id>/<derived_id>/",
  source_id  = "<source_id>",
  derived_id = "<derived_id>")
```

## Checks — two executable validators

v1 cannot execute R, so consistency and conformance are enforced statically by two
scripts in `ecocomdp-agent/tools/`, not by reading a checklist by hand (the reason
`ntl.356` shipped — DESIGN.md §7). Run both. A non-zero exit means ERROR findings; fix
the spec or the renderer and re-run. Never hand off a script with unresolved errors.

### Before rendering — `validate_spec.py` (also a precondition, above)

```sh
python3 ecocomdp-agent/tools/validate_spec.py \
  conversions/<source_id>/mapping.yaml \
  conversions/<source_id>/profile.json
```

Decidable from spec + profile alone: **column existence**, **unit-columns-exist**,
**core/ancillary disjointness**, **rationale present** on `event_id`/`location_id`, and
that every `id: null` annotation has an open question. A failure means the *spec* is
wrong — go fix `mapping.yaml`. (Ideally this also runs at the end of
`ecocomdp-flatten-design`, before the curator gate; re-running here is cheap insurance.)

### After rendering — `validate_script.py`

```sh
python3 ecocomdp-agent/tools/validate_script.py \
  conversions/<source_id>/create_ecocomDP.R \
  conversions/<source_id>/mapping.yaml
```

Conformance: the rendered R implements the approved spec and nothing else — event /
location / taxon **groupings**, **datetime** rename, **location_name**, the **ancillary
table set** (the `ntl.356` guard: identical across the `create_*_ancillary` assignments,
`create_variable_mapping()`, and `write_tables()`), each ancillary **variable_name /
unit** vector, and every **annotation URI**. This is the only check that guards the
review contract — the curator approved the *spec*, so the script must match it. A URI
that drifts three characters (`ECSO_00001688` vs `..685`) passes R and
`validate_data()` but fails here.

### Not checked — the curator's `Rscript` run does these better

Assign-before-use, required-argument presence, and syntactic balance are the R
interpreter's job, and the curator runs the script next; a static re-implementation would
be a strictly weaker duplicate. The template fills the required `create_*` arguments
structurally, so a missing one is a template defect, not a spec one.

Paste both validators' output into `NOTES.md` as a checklist. **Do not claim the script
runs** — neither validator executes R. Say "passes static + conformance checks; not
executed."

## Conventions

Match the corpus, so generated scripts are indistinguishable from hand-written ones:

- `ecocomDP::`-qualify every package call
- the standard header block with both landing-page URLs
- the full `library()` list, including the `remotes::install_github()` comments
- section banners as `# Section name ---------` padded to ~79 columns
- two-space indent, `<-` for assignment
- `flat` for the flattened frame, `wide` for the pre-pivot frame

## Output

- `create_ecocomDP.R`
- `conversions/<source_id>/<derived_id>/` — the (empty) output destination for the result
- validator results appended to `NOTES.md`

Hand back to the curator to run. The script's own `ecocomDP::validate_data()` call is the
first real verification anything gets.
