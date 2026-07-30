# ecocomDP Conversion Agent — Design Document

**Status:** v1 implemented. This document is the design *rationale of record* — where it and a
`SKILL.md`, a `kb/` file, or a tool disagree, those are authoritative and this should be updated.
**Scope:** v1 — curator-driven, script-generating; read-only EDI download, no R execution or publishing.

---

## 1. Purpose

Given an EDI data package — a **URL or packageId** the agent downloads, or an
already-downloaded package (EML + data files on local disk) — produce two reviewable
artifacts:

1. A **mapping spec** (`mapping.yaml`) — a declarative description of how the source
   dataset maps onto the ecocomDP model.
2. A **conversion script** (`create_ecocomDP.R`) — rendered from that spec, following
   the conventions of the existing corpus in `examples/`.

A human curator reviews both. The agent's EDI contact is **read-only download** (`edi-fetch`,
via the PASTA REST API, no R); it does not execute R, does not upload, and does not publish.

### Non-goals for v1

| Deferred | Rationale |
|---|---|
| Running R / `validate_data()` | No R in the environment; adds infra before the core value is proven |
| Automated publication to EDI | Irreversible, outward-facing; needs curator sign-off regardless |
| Update-triggered pipelines | The header comments in the corpus describe this end state, but it presumes a trusted converter |

Read-only **fetch** was originally deferred (below) but pulled forward: `edi-fetch`
downloads a package from a URL so a conversion can start from a link. It is done in Python
against the PASTA API, keeping the no-R invariant. Publication and R execution remain
deferred — see §9.

---

## 2. Design rationale

Three findings from the corpus (15 scripts) and the model docs drive the architecture.

**Finding 1 — the scripts are one template.** All 15 share the same ten sections in the
same order. `create_observation`, `create_location`, `create_taxon`,
`create_dataset_summary`, `create_variable_mapping`, `write_tables`, `validate_data`,
`create_eml`, and all four `calc_*` helpers appear in **15/15**. The only substantive
variation is how the source is flattened and which columns feed which arguments.

*Implication:* this is a constrained mapping problem, not open-ended code generation.
Freeform script writing would discard that structure and reintroduce variance the corpus
has already eliminated.

**Finding 2 — generated code will be wrong in ways review catches only if it is legible.**
`knb-lter-ntl.356.create_ecocomDP.R` passes `location_ancillary` to
`create_variable_mapping()` (line 194) and `write_tables()` (line 214) but never creates
it. That script cannot run. A human wrote it and it shipped.

*Implication:* correctness must be checkable *before* execution, and the review surface
must be small. A 250-line R script is a poor diff; a 40-line spec is a good one.

**Finding 3 — annotation URIs are recall, not reasoning.** The corpus hand-assigns dozens
of distinct `mapped_id` URIs across two systems (The Ecosystem Ontology and Darwin Core),
plus ENVO/PCO/NCBITaxon for `is_about` — see `kb/lexicon-README.md` for the exact counts.

*Implication:* these must come from a harvested lookup table. A model asked to produce
`ECSO_00001688` from memory will produce something that looks exactly like it and is
wrong — the highest-risk silent failure in the whole workflow.

---

## 3. Architecture

```
  URL / packageId                      (or a package already on disk → skip fetch)
           │
           ▼
  ┌─────────────────┐
  │  edi-fetch      │  download via PASTA API → conversions/<id>/
  └─────────────────┘  (read-only; Python, no R)
           │
           ▼
  ┌─────────────────┐
  │  edi-inspect    │  parse EML + data → profile.json
  └─────────────────┘  (mechanical; no judgment)
           │
           ▼
  ┌─────────────────┐
  │  suitability    │  → suitability.md  ── STOP if unsuitable
  └─────────────────┘
           │
           ▼
  ┌─────────────────┐
  │  flatten-design │  → mapping.yaml   ◄── knowledge base
  │  taxon-resolve  │                        (patterns, URI lexicon)
  │  annotate       │
  └─────────────────┘
           │
           ▼  ══════ CURATOR REVIEW GATE ══════
           │
  ┌─────────────────┐
  │  script-render  │  → create_ecocomDP.R  +  conversions/<id>/<derived_id>/
  └─────────────────┘  (deterministic templating; static + conformance validators)
           │
           ▼  ══════ CURATOR RUNS & REVIEWS ══════
```

The **mapping spec is the contract**. Everything upstream produces it; the renderer
consumes it and nothing else. This keeps the reasoning-heavy and mechanical parts
separable, independently testable, and independently improvable.

---

## 4. Artifacts

Per dataset, in `conversions/<source_id>/` (created at fetch, named for the source
packageId; also holds the downloaded EML + data files):

| File | Producer | Consumer |
|---|---|---|
| `<source EML + data files>` | `edi-fetch` (or curator) | edi-inspect, the generated script |
| `profile.json` | `edi-inspect` | suitability, flatten-design |
| `suitability.md` | `ecocomdp-suitability` | curator |
| `mapping.yaml` | `ecocomdp-flatten-design` (+ taxon, annotate) | curator, renderer |
| `create_ecocomDP.R` | `ecocomdp-script-render` | curator, R |
| `NOTES.md` | agent, throughout | curator |

The converted result lands one level down, in `conversions/<source_id>/<derived_id>/` —
created by the renderer once the curator assigns `derived_id`, and populated with the
ecocomDP tables + derived EML only when the curator runs the script.

`NOTES.md` records assumptions, ambiguities, and anything the agent guessed at — it is
the honest-uncertainty channel, and should be read alongside the spec.

### 4.1 Mapping spec

`kb/mapping-schema.md` is the authoritative schema (and the contract the renderer reads).
In outline:

```yaml
source_id: knb-lter-jrn.210007001.38
derived_id: null              # curator assigns
source_tables: {...}          # files + grain
flatten: {...}                # pattern, joins, and any aggregate / pivot / filter
observation:                  # the core table
  event_id:    {group_by: [...], rationale: "..."}   # rationale REQUIRED
  location_id: {group_by: [...], rationale: "..."}   # rationale REQUIRED
  ...
location: {...}
taxon: {...}                  # from ecocomdp-taxon-resolve
ancillary: {...}
annotations: {...}            # from ecocomdp-annotate — lexicon URIs only, never invented
open_questions: [...]         # anything guessed, ambiguous, or escalated
```

The staged Jornada package (`knb-lter-jrn.210007001.38`) is the worked example — instructive
because it matches **none** of the 15 corpus patterns: each row is one captured lizard, so
counts are implicit and must be derived. Its `rcap` recapture question is exactly what
belongs in `open_questions` rather than being silently decided. A fully worked spec lives at
`conversions/knb-lter-jrn.210007001.38/mapping.yaml`.

---

## 5. Skills

Skills live in `skills/<name>/SKILL.md`, installed as a Claude Code plugin (see the repo
root `.claude-plugin/`). Each `SKILL.md` is authoritative for what its skill does; this
section records only **why each stage exists** and links it to the findings above.

| Skill | Why it exists |
|---|---|
| `edi-fetch` | Start from a URL: download the package (read-only, §9) so the curator need not fetch by hand |
| `edi-inspect` | Turn EML + data into a factual `profile.json` — mechanical, giving later reasoning a fixed substrate |
| `ecocomdp-suitability` | A genuine stop gate: end an unsuitable dataset here rather than produce a spec that cannot work |
| `ecocomdp-flatten-design` | The reasoning core — choose the flattening pattern (§6.1) and the two high-risk groupings, and justify them |
| `ecocomdp-taxon-resolve` | Plan resolution and flag names likely to fail; v1 cannot run the resolver, so it records intent, not results |
| `ecocomdp-annotate` | Look up annotation URIs in the lexicon (§6.2); **never invent one** — Finding 3 |
| `ecocomdp-script-render` | Deterministic spec → R, emitting **only** spec-declared tables — the structural fix for Finding 2 |
| `ecocomdp-convert` | Orchestrates the chain, stopping at the curator review gate |

---

## 6. Knowledge base

Built once from the corpus — the highest-leverage prep work. Each `kb/` file is
authoritative for its own content; this is a map, not a copy.

- **`kb/patterns.md`** (§6.1) — flattening patterns P1–P4, each: source shape → detection
  heuristic → pivot/join idiom → worked example. `ecocomdp-flatten-design` selects from it.
- **`kb/mapping-schema.md`** — the `mapping.yaml` contract (see §4.1).
- **`kb/lexicon-*.csv`** + **`kb/lexicon-README.md`** (§6.2) — annotation URIs harvested from
  the corpus by `tools/harvest-lexicon.py`, plus the corpus defects it repaired and the
  known `ecological community` ambiguity. The single most important artifact for output
  trustworthiness (Finding 3). `ecocomDP::annotation_dictionary()` would expand it but needs
  R, so it is deferred to execution (§9).
- **`kb/script-template.R`** (§6.3) — the canonical script with `{{slots}}` the renderer
  fills: the standard header, library block, ten sections, and the `create_eml` tail.

---

## 7. Verification without R

v1 cannot execute, so verification is static — two executable validators plus a manual
acceptance test:

1. **`tools/validate_spec.py`** — decidable from `mapping.yaml` + `profile.json` alone:
   every named column exists; join keys resolve; core and ancillary columns are disjoint;
   each `unit_<col>` has a declared unit; `event_id`/`location_id` carry a rationale; every
   `id: null` annotation has an open question. Runs as a render precondition.
2. **`tools/validate_script.py`** — conformance: the rendered R implements the approved spec
   and nothing else (groupings, datetime, `location_name`, the ancillary table set — the
   **ntl.356 guard** — ancillary vectors, annotation URIs). This is the *only* check of the
   spec→script contract; the curator's `Rscript` run and `validate_data()` are blind to the
   spec, so a script can run clean and still betray the approval.
3. **Corpus replay** (the real score): run the agent against the 15 source packages and diff
   generated specs against the known-good scripts in `examples/`. Target: on ≥12/15, the
   generated spec's core column choices match what the published script did.

Deliberately **not** re-implemented statically: syntax, variable binding, and
argument presence. The R interpreter does these better, and the curator runs the script
next; a weaker static copy would add maintenance for no gain. Corpus replay is the v1
acceptance test.

---

## 8. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Hallucinated ontology URIs | **High** — silent, survives review | Lexicon-only rule; null over guess |
| Wrong `event_id` grain | High — corrupts the model's sampling semantics | Force explicit justification in NOTES.md; surface in review |
| Plausible-but-wrong script that curator rubber-stamps | High | Keep spec small and reviewable; NOTES.md states assumptions rather than burying them |
| No execution ⇒ unknown runtime failures | Medium | Accepted for v1; static checks (§7) reduce it; §9 resolves it |
| Corpus overfitting (all 15 are LTER) | Medium | Jornada as a deliberate off-pattern case |
| Taxon resolution failures | Medium | Flag suspicious names in spec rather than assume success |

---

## 9. Staged path beyond v1

**Done — read-only fetch.** `tools/edi-fetch.py` takes a URL or packageId and downloads the
package via the PASTA REST API in Python (no `EDIutils`, so no R dependency). Originally
sequenced after execution; pulled forward so a conversion can start from a link.

Still ahead, in priority order:

- **Execution.** Install R + `ecocomDP`, `EDIutils`, `taxonomyCleanr`; the agent runs its own
  script and `validate_data()`, iterating on failures. The largest single jump in output
  quality — it turns the static checks into a real one.
- **Publication assist.** Prepare the EML and publication bundle; the curator still presses
  the button.
- **Update-triggered maintenance.** The end state the corpus script headers describe.

---

## 10. Curator decisions (settled)

These were open questions at design time; all are now settled and encoded in
`config/curator.yml`. Listed here as the rationale of record — change them in `curator.yml`,
not in the skills.

| Decision | Where it lives |
|---|---|
| Skills live in a shared plugin directory, not a per-repo `.claude/skills/` | repo-root `.claude-plugin/` + marketplace |
| `derived_id` is always assigned by the curator, never proposed by the agent | `policy.derived_id_assignment: manual` |
| The EDI contact block is configurable per curator | `contact:` |
| `suitable-with-caveats` stops for curator confirmation before spec design | `policy.on_suitable_with_caveats: stop` |
| Recapture / individual-dedup semantics are always escalated, never decided | `policy.recapture_handling: escalate` |
