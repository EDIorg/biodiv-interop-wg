---
name: ecocomdp-convert
description: Run the end-to-end ecocomDP conversion workflow for a downloaded EDI data package — inspect, assess suitability, design a mapping spec, and (after curator approval) render an R conversion script. Use when asked to convert an EDI dataset to ecocomDP, or as the entry point to the ecocomdp-agent workflow.
---

# ecocomDP Conversion Workflow

Orchestrates the conversion of an EDI data package — downloaded from a URL/packageId or
supplied on disk — into a reviewable mapping spec and R conversion script.

**This workflow is curator-driven and stops for human review.** Its only EDI contact is the
read-only `edi-fetch` download; it does not execute R, does not upload, and does not
publish. See `DESIGN.md` for scope and rationale.

## Input

Either:

- a **URL or packageId** — an EDI portal link, a PASTA URL, or `knb-lter-jrn.210007001.38`
  (revision optional). Start at `[0] edi-fetch`, which downloads the package.
- a **path to a directory** holding an already-downloaded package (EML + data files).
  Skip `[0]` and start at `[1] edi-inspect`.

## Stages

```
  URL / packageId                        (or an already-downloaded dir → skip to [1])
      │
      ▼  [0] edi-fetch                → conversions/<id>/          (read-only download)
      │
      ▼  [1] edi-inspect              → profile.json
      │
      ▼  [2] ecocomdp-suitability     → suitability.md
      │        unsuitable ──────────────────────► STOP
      │        suitable-with-caveats ───────────► STOP for confirmation
      │
      ▼  [3] ecocomdp-flatten-design  → mapping.yaml + NOTES.md
      │        ├─ ecocomdp-taxon-resolve   (taxon block)
      │        └─ ecocomdp-annotate        (annotations block)
      │
      ▼  ═══════ CURATOR REVIEW GATE ═══════
      │
      ▼  [4] ecocomdp-script-render   → create_ecocomDP.R
      │
      ▼  ═══════ CURATOR RUNS THE SCRIPT ═══════
```

### 0. Fetch (only when given a URL or packageId)
Invoke `edi-fetch`. It creates `conversions/` if absent, then a `conversions/<source_id>/`
subdirectory named for the source packageId, and downloads the EML + data files into it.
This is the one stage that contacts EDI, and it is **read-only**. If the curator supplied a
directory, skip this stage — but still ensure `conversions/<source_id>/` exists, since the
downstream artifacts land there. If the download fails authentication (private package),
stop and report — do not proceed from metadata alone.

### 1. Inspect
Invoke `edi-inspect` on the package files — `conversions/<source_id>/` where `edi-fetch`
placed them, or, for a curator-supplied package, that directory directly. Either way the
artifacts (`profile.json` onward) are written to `conversions/<source_id>/`. Mechanical
profiling — no judgement.

### 2. Assess suitability
Invoke `ecocomdp-suitability`.

- **`unsuitable`** → stop. Report which axis is missing. Do not propose workarounds that
  fabricate it.
- **`suitable-with-caveats`** → **stop and ask the curator** before continuing
  (`config/curator.yml`: `policy.on_suitable_with_caveats: stop`). Present the caveats
  plainly.
- **`suitable`** → continue.

### 3. Design the mapping spec
Invoke `ecocomdp-flatten-design`, which calls `ecocomdp-taxon-resolve` and
`ecocomdp-annotate` for their blocks. Output: `mapping.yaml`, `NOTES.md`.

### 4. Curator review gate — **stop here**

Present for review:

- the **verdict** and its caveats
- the **mapping spec**, especially `event_id` / `location_id` and their rationales
- **open questions**, blocking ones first
- any annotation with `id: null`

Then stop. Do not render the script until the curator approves the spec and supplies
`derived_id`. This gate is the point of the design — a spec is reviewable in a way a
250-line R script is not.

### 5. Render
Invoke `ecocomdp-script-render` once approved. It creates the destination subdirectory
`conversions/<source_id>/<derived_id>/` — named for the derived packageId the curator
assigned — as the output path for the ecocomDP result. Run the validators and report
results honestly: the script has **not** been executed, so that directory stays empty until
the curator runs it.

## Output layout

```
conversions/
└── <source_id>/                  # [0] created at fetch; source EML + data files land here
    ├── <source EML + data files> # [0] edi-fetch (or the curator's copy)
    ├── profile.json              # [1]
    ├── suitability.md            # [2]
    ├── mapping.yaml              # [3] — primary review surface
    ├── NOTES.md                  # assumptions, rationales, checks
    ├── create_ecocomDP.R         # [5] — after approval
    └── <derived_id>/             # [5] created at render; the script's output path.
        └── (ecocomDP tables + derived EML — written when the curator runs the script)
```

## Standing rules

| Rule | Source |
|---|---|
| `derived_id` is never proposed by the agent | curator policy |
| Recapture / individual-deduplication semantics are **always escalated** | curator policy |
| Never emit an annotation URI absent from `kb/lexicon-*.csv` | DESIGN.md §8 |
| `rationale` is mandatory on `event_id` and `location_id` | DESIGN.md §8 |
| Prefer an open question over a confident guess | — |
| Never claim the script runs — it has not been executed | v1 scope |

## Knowledge base

- `kb/patterns.md` — flattening patterns P1–P4
- `kb/mapping-schema.md` — `mapping.yaml` schema
- `kb/lexicon-variable-mapping.csv`, `kb/lexicon-is-about.csv` — annotation URIs
- `kb/script-template.R` — the canonical script
- `examples/` — 15 hand-written conversions
- `config/curator.yml` — contact block and policy

## Resuming

Stages are resumable — each reads the previous stage's artifact from
`conversions/<source_id>/`. If `profile.json` exists, skip to [2]. If the curator answers
an open question, update `mapping.yaml` and re-run only from [4].
