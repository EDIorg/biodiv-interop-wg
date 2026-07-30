# ecocomdp-agent

A curator-driven agent workflow for converting environmental datasets published in the
[EDI Data Repository](https://edirepository.org) to the
[ecocomDP](https://ediorg.github.io/ecocomDP/) data model.

Given an EDI data package — **from a URL/packageId it downloads, or one already on disk** —
the agent produces a reviewable **mapping spec** and, once a curator approves it, an **R
conversion script** built from the
[`ecocomDP` R package](https://ediorg.github.io/ecocomDP/reference/index.html).

## Scope (v1)

| Does | Does not |
|---|---|
| Download a package from a URL/packageId (read-only) | Upload or publish anything |
| Read a package from disk, assess suitability | Execute R or run `validate_data()` |
| Design a declarative mapping spec | Decide recapture / dedup semantics |
| Render `create_ecocomDP.R` | Run unattended |
| Stop for curator review | Guess annotation URIs |

The agent **never claims the generated script works** — it has not been run. The curator
runs it, and the script's own `ecocomDP::validate_data()` call is the first real
verification. See `DESIGN.md` §9 for the staged path to execution (v2) and beyond.

## Install

This is a Claude Code plugin, registered through the local marketplace manifest at the
repository root (`.claude-plugin/marketplace.json`):

```sh
/plugin marketplace add <absolute path to the repo root>
/plugin install ecocomdp-agent@biodiv-interop
```

Restart the session so the skills are discovered. Once installed they are namespaced —
invoke them as `ecocomdp-agent:ecocomdp-convert`, not by the bare name. After editing a
`SKILL.md`, run `/reload-plugins`.

Then edit `config/curator.yml` with your contact details before rendering any script —
those values are written into the generated EML.

## Use

Start from a link or identifier (the agent downloads it):

```
> Convert https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-jrn&identifier=210007001 to ecocomDP
> Convert knb-lter-jrn.210007001.38 to ecocomDP
```

…or from a package already on disk (fetch is skipped):

```
> Convert the dataset in ./knb-lter-jrn.210007001.38 to ecocomDP
```

This invokes the `ecocomdp-convert` orchestrator, which runs:

```
[0] edi-fetch           → conversions/<id>/          ← only for a URL/id; read-only download
[1] edi-inspect          → profile.json
[2] ecocomdp-suitability → suitability.md        ← stops if unsuitable
[3] ecocomdp-flatten-design → mapping.yaml + NOTES.md
      ├─ ecocomdp-taxon-resolve
      └─ ecocomdp-annotate

    ═══ CURATOR REVIEW GATE ═══                  ← always stops here

[4] ecocomdp-script-render → create_ecocomDP.R
```

The source package is downloaded into `conversions/<source_id>/`, where the working
artifacts (`profile.json`, `mapping.yaml`, `create_ecocomDP.R`, …) also land; the converted
ecocomDP result goes in a nested `conversions/<source_id>/<derived_id>/`, created once the
curator assigns the derived packageId. Stages are resumable — answering an open question
means re-running only from the gate.

Downloading public EDI data needs no credentials. For a private/embargoed package, set an
env var (`EDI_PASSWORD` or `EDI_TOKEN`) and point `config/curator.yml`'s `repository.auth`
block at it — never commit a secret.

You can also invoke any skill on its own, e.g. just `edi-inspect` to profile a package.

## Reviewing a conversion

The **mapping spec is the review surface**. Read `mapping.yaml` before the R script; the
script is rendered mechanically from it, so an error in the script is almost always an
error in the spec.

Check, in order:

1. **`open_questions`** — anything `blocking: true` must be answered first.
2. **`event_id` and `location_id` rationales.** These define the sampling and spatial
   grain of the output. They are the two decisions most likely to be wrong and least
   likely to be caught by validation. An unconvincing rationale should fail review.
3. **`flatten.joins` cardinality.** A fan-out join silently multiplies observations and
   still validates cleanly.
4. **Annotations with `id: null`** — gaps the curator must fill. The agent is forbidden
   from guessing URIs, so nulls are expected and correct.
5. **`derived_id`** — always `null` from the agent; you assign it.

`NOTES.md` records what the agent assumed and why. Read it alongside the spec.

## Layout

```
ecocomdp-agent/
├── DESIGN.md                    # design rationale, risks, staged roadmap
├── README.md
├── .claude-plugin/plugin.json
├── config/curator.yml           # contact block + workflow policy
├── skills/
│   ├── ecocomdp-convert/        # orchestrator — entry point
│   ├── edi-fetch/               # URL/packageId → conversions/<id>/ (read-only download)
│   ├── edi-inspect/             # EML + data → profile.json
│   ├── ecocomdp-suitability/    # four-axis check, stop gate
│   ├── ecocomdp-flatten-design/ # the reasoning core → mapping.yaml
│   ├── ecocomdp-taxon-resolve/  # resolver choice, risky-name flagging
│   ├── ecocomdp-annotate/       # lexicon-only URI lookup
│   └── ecocomdp-script-render/  # spec → R, runs the validators
├── kb/
│   ├── patterns.md              # flattening patterns P1–P4
│   ├── mapping-schema.md        # mapping.yaml schema reference
│   ├── lexicon-variable-mapping.csv   # 73 harvested annotations
│   ├── lexicon-is-about.csv           # 40 harvested dataset annotations
│   ├── lexicon-corpus-issues.csv      # 3 defects found in the corpus
│   ├── lexicon-README.md
│   └── script-template.R        # canonical script with slots
├── tools/
│   ├── harvest-lexicon.py       # regenerates the lexicons from examples/
│   ├── edi-fetch.py             # downloads a package by URL/packageId (PASTA API)
│   ├── validate_spec.py         # static checks on mapping.yaml + profile.json
│   └── validate_script.py       # conformance: create_ecocomDP.R vs mapping.yaml
└── examples/                    # 15 hand-written corpus conversions
```

## Design in one paragraph

The 15 scripts in `examples/` are the same function: identical ten sections, identical
`ecocomDP::` calls in all 15. The only real variation is how the source is flattened and
which columns feed which arguments. So conversion is a **constrained mapping problem**,
not open-ended code generation — which is why the agent produces a declarative spec that
a curator can review in a minute, and renders the R mechanically from it. Two failure
modes drive the guardrails: a hand-written corpus script (`ntl.356`) ships a
`location_ancillary` it never creates, so the renderer emits only spec-declared tables
and checks table-set consistency; and ontology URIs are opaque enough that a hallucinated
one would publish wrong semantics undetectably, so annotations come strictly from a
lexicon harvested from the corpus. Full rationale in `DESIGN.md`.
