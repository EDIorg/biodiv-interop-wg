---
name: ecocomdp-annotate
description: Assign ontology URIs for an ecocomDP dataset's variable_mapping table and is_about dataset annotations, looked up strictly from the harvested lexicon. Use while designing the mapping spec's annotations block. Never emit a URI from memory.
---

# Annotation Lookup

Fill the `annotations:` block of `mapping.yaml` with ontology URIs for the
`variable_mapping` table and the `is_about` dataset annotations.

## The one rule that matters

> **Never emit a URI that is not present in `kb/lexicon-variable-mapping.csv` or
> `kb/lexicon-is-about.csv`.**

Ontology URIs are opaque identifiers — `ECSO_00001688` vs `ECSO_00001685` differ by three
characters and mean different things. A URI recalled from memory will look exactly as
plausible as a correct one, will pass every validation the package performs, and will
publish incorrect semantics under an authoritative-looking identifier. This is the
highest-severity failure mode in the workflow (DESIGN.md §8).

Not in the lexicon ⇒ `id: null` plus an entry in `open_questions`. A gap is recoverable
in review; a wrong URI is not.

## Lexicon

Harvested from the 15 corpus scripts:

- `kb/lexicon-variable-mapping.csv` — 73 entries
  (`variable_name, mapped_system, mapped_id, mapped_label, n_uses, seen_in`)
- `kb/lexicon-is-about.csv` — 40 entries (`label, uri, n_uses, seen_in`)

Two systems appear: **The Ecosystem Ontology** (ECSO, `purl.dataone.org/odo/…`) and
**Darwin Core** (`rs.tdwg.org/dwc/terms/…`). Dataset-level `is_about` annotations also
draw on ENVO, PCO, and NCBITaxon (`purl.obolibrary.org/obo/…`).

`n_uses` is a weak confidence signal — a term used in 3 scripts is better attested than
one used once. It is not authority; the corpus is 15 datasets by a handful of authors.

## Procedure

### 1. variable_mapping

For every variable that will appear in `observation` and the ancillary tables:

1. Exact match on `variable_name` in the lexicon → use it, `source: lexicon`.
2. No exact match → look for a semantic equivalent under a different name (`count` vs
   `COUNT` vs `abundance`; `ELEV_BAND` vs `elevation`). Reuse the URI, but say so in
   `open_questions` — you are asserting an equivalence the corpus did not.
3. Still nothing → `system: null, id: null, label: null` and an open question.

```yaml
annotations:
  variable_mapping:
    count:
      system: Darwin Core
      id: http://rs.tdwg.org/dwc/terms/individualCount
      label: individualCount
      source: lexicon
    sex:
      system: null
      id: null
      label: null
      source: null
```

Case and separators vary in the source (`Sex`, `SEX`, `sex`). Match case-insensitively,
but write the variable name exactly as it appears in the data.

### 2. is_about

Dataset-level annotations describing what the dataset is *about*. Seed candidates from
the EML `<keywordSet>` and `<taxonomicCoverage>` in `profile.json`, then look each up.

Well-attested entries in the corpus:

| Label | URI | n |
|---|---|---|
| Population | `http://purl.dataone.org/odo/ECSO_00000311` | 6 |
| species abundance | `http://purl.dataone.org/odo/ECSO_00001688` | 4 |
| ecosystem | `http://purl.obolibrary.org/obo/ENVO_01001110` | 3 |
| ecological community | `http://purl.obolibrary.org/obo/PCO_0000002` | 3 |
| lake | `http://purl.obolibrary.org/obo/ENVO_00000020` | 3 |
| Mammalia | `http://purl.obolibrary.org/obo/NCBITaxon_40674` | 3 |

Note `ecological community` appears in the corpus with **two different URIs**
(`PCO_0000002` and `NCBITaxon_3193`, 3 uses each). Where the lexicon is inconsistent, say
so and let the curator choose — do not silently pick one.

Aim for 3–6 annotations covering: the ecological concept (population/community), the
measurement (species abundance/biomass), the habitat (lake/grassland/estuary), and the
taxonomic group if there is a clean match.

### 3. Extending the lexicon

Curator-supplied URIs should be added to the CSVs with `seen_in: curator` so later
conversions benefit. The agent may append entries **only** when the curator provides the
URI — never from its own knowledge, and never from a web lookup in v1.

## What the rendered script produces

```r
i <- variable_mapping$variable_name == 'count'
variable_mapping$mapped_system[i] <- 'Darwin Core'
variable_mapping$mapped_id[i]     <- 'http://rs.tdwg.org/dwc/terms/individualCount'
variable_mapping$mapped_label[i]  <- 'individualCount'
```

Entries with `id: null` are emitted as a commented-out block with a `# TODO(curator)`
marker, so the gap is visible in the script rather than silently absent. The corpus does
this already — `hbr.82` has two commented-out mappings where the author was unsure.
