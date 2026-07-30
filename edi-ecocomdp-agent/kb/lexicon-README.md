# Annotation Lexicon

Ontology URIs harvested from the 15 conversion scripts in `examples/`. The
`ecocomdp-annotate` skill may **only** emit URIs found here.

## Files

| File | Rows | Columns |
|---|---|---|
| `lexicon-variable-mapping.csv` | 73 | `variable_name, mapped_system, mapped_id, mapped_label, n_uses, seen_in` |
| `lexicon-is-about.csv` | 40 | `label, uri, n_uses, seen_in` |
| `lexicon-corpus-issues.csv` | 3 | defects found in the corpus during harvest |

`n_uses` = how many corpus scripts used that pairing. `seen_in` = which ones.

## Corpus defects found during harvest

Harvesting surfaced three genuine bugs in the published corpus scripts. The harvester
repairs or drops them rather than letting the lexicon inherit them; all three are
recorded in `lexicon-corpus-issues.csv`.

| Script | Variable | Defect |
|---|---|---|
| `pie.404` | `Latitude` | `mapped_id` and `mapped_label` swapped — id held `decimalLatitude`, label held the URI |
| `pie.405` | `LAT` | same swap |
| `pie.405` | `ABUNDANCE` | `mapped_id` holds an ECSO **definition sentence** ("The density, or more precisely, the volumetric count density…") instead of a URI |

The two swaps are repaired (id/label exchanged). The third is **dropped** — the intended
URI is not recoverable from the text, so the correct ECSO term for volumetric count
density is a gap a curator should fill.

These are worth reporting upstream: they are in datasets already published to EDI, where
`mapped_id` is what downstream consumers read as the semantic identifier.

## Coverage

83 distinct annotation URIs appear in the corpus; 82 are captured. The two omissions are
in `knb-lter-hbr.82`, where the author **commented out** two `mapped_id` assignments
(`ECSO_00001177` length, `ECSO_00001685` biomass) — evidently unsure of them. Excluding
them is deliberate: the lexicon records annotations that were actually used, not ones an
author declined to commit to. A curator who wants them can add them (see below).

Systems represented:

- **The Ecosystem Ontology** (ECSO) — `purl.dataone.org/odo/…`, 47 variable_mapping uses
- **Darwin Core** — `rs.tdwg.org/dwc/terms/…`, 35 uses
- **ENVO / PCO / NCBITaxon** — `purl.obolibrary.org/obo/…`, mostly `is_about`

## Known inconsistency

`ecological community` appears with **two different URIs**, 3 uses each:

- `http://purl.obolibrary.org/obo/PCO_0000002`
- `http://purl.obolibrary.org/obo/NCBITaxon_3193`

The corpus does not settle this. `ecocomdp-annotate` must surface the ambiguity rather
than pick one. Worth a curator ruling — resolving it here would improve every future
conversion.

## Caveats

- This is **15 datasets by a handful of authors**, all LTER. `n_uses` is a weak
  attestation signal, not authority.
- Coverage is biased toward the variables those datasets happened to contain. Expect
  gaps on new dataset types; gaps are handled by `id: null` + an open question, which is
  the intended behavior.
- No URI here has been verified against a live ontology service. They are what the
  corpus used. v1 does no network lookups.

## Extending

Add rows when a curator supplies a URI, with `seen_in: curator`:

```csv
sex,Darwin Core,http://rs.tdwg.org/dwc/terms/sex,sex,1,curator
```

The agent may append **only** curator-supplied URIs — never ones recalled from its own
knowledge.

If `examples/` changes, regenerate from the corpus:

```sh
python3 tools/harvest-lexicon.py
```

Note this **overwrites** both CSVs, discarding curator-added rows. Re-apply them, or
keep curator additions in a separate file.

## Seeding further

`ecocomDP::annotation_dictionary()` returns annotations used across published ecocomDP
datasets and would substantially expand this lexicon. It requires R, so it is deferred to
v2 (see `DESIGN.md` §9).
