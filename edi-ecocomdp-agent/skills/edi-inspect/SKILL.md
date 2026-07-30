---
name: edi-inspect
description: Parse a downloaded EDI data package (EML XML + data files) into a structured profile.json describing entities, attributes, units, geographic coverage, code lists, and candidate ecocomDP columns. Use this as the first step of any ecocomDP conversion, or whenever asked to inspect, profile, or summarize an EDI package on disk.
---

# EDI Package Inspection

Produce `profile.json` — a factual description of a downloaded EDI package. This step is
**mechanical**: report what is there. Do not judge suitability (that is
`ecocomdp-suitability`) and do not design a mapping (that is `ecocomdp-flatten-design`).

## Input

A directory containing a downloaded package — either the curator's own download or the
`conversions/<source_id>/` directory produced by `edi-fetch`. Either way this step is
disk-only; it does not contact EDI. For example:

```
knb-lter-jrn.210007001.38/
├── knb-lter-jrn.210007001.38.xml          # EML metadata
├── knb-lter-jrn.210007001.38.report.xml   # quality report — ignore
├── manifest.txt
├── JRN007001_lizard_pitfall_data_89-06.csv
├── Lizardcodelist.txt
└── ...
```

The EML is the `<packageId>.xml` file — **not** the `.report.xml`, which is a quality
report and will mislead you (it repeats `<entityName>` elements).

## Procedure

### 1. Parse the EML

Extract, per `<dataTable>` / `<otherEntity>`:

- `entityName`, `entityDescription`, `objectName` (the actual filename)
- field delimiter, header line count, orientation
- for each `<attribute>`: `attributeName`, `attributeDefinition`, storage type,
  measurement scale (nominal / ordinal / interval / ratio / dateTime), `unit`,
  `numberType`, date format string, missing value codes
- enumerated domains — `<codeDefinition>` pairs are code lists and matter for taxon
  resolution

Also extract package-level:

- `<geographicCoverage>`: `geographicDescription` and the four bounding coordinates per
  block (there may be many — one per site)
- `<temporalCoverage>`: begin/end dates
- `<taxonomicCoverage>`: if present, this is strong evidence of a taxon axis
- `<methods>`: read it. The sampling design determines `event_id` grouping. Summarize
  the sampling frequency and unit in the profile.
- `<keywordSet>`: seeds `is_about` annotations later

### 2. Profile each data file

Read the actual data (not just the metadata — they disagree more often than you would
like). For each file and column:

- inferred type, non-null count, unique count
- min/max for numeric and date columns
- for low-cardinality columns, the actual distinct values (cap at ~30)
- whether the EML-declared type matches the observed type — **report mismatches**

### 3. Nominate candidate columns

Flag, with evidence and without committing:

| Role | Signals |
|---|---|
| `datetime` | dateTime measurement scale; parseable date values; names like date, year, collection_date |
| `taxon` | values matching a code list; `<taxonomicCoverage>`; names like spp, species, taxon, code |
| `value` | ratio/interval scale numerics; names like count, abundance, biomass, density, CPUE |
| `location` | low-cardinality nominal columns matching `geographicDescription` values; names like site, plot, station, watershed |
| `individual` | tag/toe/band numbers, recapture flags, per-organism measurements |

The `individual` role matters: its presence means one row is one organism, which implies
flattening pattern P4 and an aggregation step.

### 4. Determine grain

State, per table, what one row represents. This is the single most useful line in the
profile. Base it on unique-count analysis: if no combination of the obvious keys is
unique, rows are probably individual records or repeated measures.

## Output

Write `profile.json` to the conversion directory:

```json
{
  "source_id": "knb-lter-jrn.210007001.38",
  "eml_file": "knb-lter-jrn.210007001.38.xml",
  "title": "...",
  "abstract_summary": "...",
  "methods_summary": "Pitfall traps at 4 sites, checked ...",
  "temporal_coverage": {"begin": "1989-06-16", "end": "2006-..."},
  "geographic_coverage": [
    {"description": "CALI", "north": 32.6, "south": 32.5, "east": -106.7, "west": -106.8}
  ],
  "taxonomic_coverage": true,
  "keywords": ["lizards", "population dynamics"],
  "entities": [
    {
      "alias": "lizards",
      "object_name": "JRN007001_lizard_pitfall_data_89-06.csv",
      "entity_name": "Lizard pitfall data file",
      "n_rows": 4091,
      "grain": "one row = one captured individual",
      "columns": [
        {"name": "date", "eml_type": "dateTime", "observed_type": "date",
         "n_unique": 731, "min": "1989-06-16", "max": "2006-...",
         "definition": "...", "unit": null, "candidate_roles": ["datetime"]},
        {"name": "spp", "eml_type": "nominal", "observed_type": "string",
         "n_unique": 18, "values": ["CNTI", "UTST", "..."],
         "code_list": "Lizardcodelist.txt", "candidate_roles": ["taxon"]}
      ]
    }
  ],
  "eml_data_mismatches": [
    {"entity": "lizards", "column": "pc", "issue": "declared ratio, observed all 0/1"}
  ],
  "candidates": {
    "datetime": ["date"], "taxon": ["spp"], "value": [],
    "location": ["zone", "site", "plot"],
    "individual": ["toe_num", "rcap", "sex", "SV_length", "weight"]
  }
}
```

An empty `value` candidate list is a real and important finding — it means abundance is
implicit and must be derived by aggregation.

## Notes

- Prefer reading the EML with a real XML parser over regex; namespaces vary across EML
  2.1.x and 2.2.x.
- Non-tabular entities (PDF protocols, `.dsd`/`.his` documentation files) are context for
  a human, not data. List them, do not profile them.
- If the EML and the data disagree about columns, the **data** is authoritative for what
  can be mapped, and the disagreement itself belongs in the profile.
