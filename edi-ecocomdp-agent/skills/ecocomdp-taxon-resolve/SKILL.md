---
name: ecocomdp-taxon-resolve
description: Plan taxonomic resolution for an ecocomDP conversion — choose between taxonomyCleanr resolve_sci_taxa and resolve_comm_taxa, select the authority, and flag names unlikely to resolve. Use while designing the mapping spec's taxon block.
---

# Taxon Resolution Planning

Fill the `taxon:` block of `mapping.yaml`. In v1 the agent **cannot run R**, so this
skill plans resolution and flags risk — it does not verify that names resolve.

Be honest about that limit. The generated script calls the resolver; whether it succeeds
is discovered when the curator runs it.

## Choose the resolver

| Function | Use when | Corpus |
|---|---|---|
| `taxonomyCleanr::resolve_sci_taxa` | Scientific names (`Aspidoscelis tigris`) | 10/15 |
| `taxonomyCleanr::resolve_comm_taxa` | Common names (`snails`, `slugs`) | 3/15 |

Decide from the actual values in `profile.json`, not the column name. If the column holds
**codes** (`CNTI`, `UTST`), neither resolver applies directly — the codes must first be
joined to a code list to get names. Record that join in `flatten.joins`.

Mixed scientific and common names in one column: resolve the scientific subset and flag
the rest. Do not silently pass common names to `resolve_sci_taxa`.

## Choose the authority

`data.sources` is a Global Names index id. The corpus uses `3` (ITIS) throughout.
Prefer ITIS for North American terrestrial/freshwater taxa; WoRMS is the better choice
for marine datasets. State the choice in the spec:

```yaml
taxon:
  names_from: {table: codes, column: scientific_name}
  resolver: resolve_sci_taxa
  data_sources: [3]           # ITIS
```

## Flag names unlikely to resolve

Scan the distinct taxon values and list anything that will probably fail. These are the
common failure classes:

| Class | Examples | Why it fails |
|---|---|---|
| Placeholder / unknown | `UNKN`, `UNKNOWN`, `NA`, `999` | Not a taxon |
| Genus-level qualifier | `Aspidoscelis sp.`, `Uta spp.` | Resolvers often reject the qualifier |
| Morphospecies | `Chironomid A`, `sp. 2` | Field labels, not published names |
| Aggregates | `Diptera larvae`, `mixed algae` | A group, not a taxon |
| Life stage in the name | `Cnemidophorus juvenile` | Stage belongs in ancillary |
| Misspellings / legacy synonyms | `Cnemidophorus tigris` | Reclassified — may resolve to a synonym |
| Raw codes not joined | `CNTI` | Needs the code list join first |

```yaml
  suspicious_names:
    - {name: "UNKN", reason: "unknown-taxon placeholder", suggestion: "drop rows or map to a higher rank"}
    - {name: "Aspidoscelis sp.", reason: "genus-level qualifier", suggestion: "resolve to genus rank"}
```

Include a `suggestion`, but do not apply it — the curator decides.

## What the rendered script does

The renderer emits the corpus idiom: resolve unique names, select and rename the
authority columns, join back to `flat`.

```r
taxa_resolved <- taxonomyCleanr::resolve_sci_taxa(
  x = unique(flat$taxon_name),
  data.sources = 3)

taxa_resolved <- taxa_resolved %>%
  dplyr::select(taxa, rank, authority, authority_id) %>%
  dplyr::rename(
    taxon_rank         = rank,
    taxon_name         = taxa,
    authority_system   = authority,
    authority_taxon_id = authority_id)

flat <- dplyr::left_join(flat, taxa_resolved, by = "taxon_name")
```

`create_taxon()` requires `taxon_id`, `taxon_rank`, `taxon_name`, `authority_system`,
`authority_taxon_id`. Unresolved names produce `NA` in the authority columns — the table
still builds, so a low resolution rate is **not** a validation failure. It is a quality
problem only a human will notice, which is exactly why the flags above matter.

## Notes

- Resolution hits a network service and is slow for large taxon lists; the corpus always
  resolves `unique()` names, never the full column.
- Keep the original code or label as `taxon_name_verbatim` in `taxon_ancillary` — it is
  the only record of what the source actually said.
- Never invent an `authority_taxon_id`. If you cannot verify it, leave it to the script.
