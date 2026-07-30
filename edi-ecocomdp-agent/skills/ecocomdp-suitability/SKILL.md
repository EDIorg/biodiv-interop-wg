---
name: ecocomdp-suitability
description: Assess whether an EDI dataset can be represented in the ecocomDP data model by checking for the four required axes (taxon, value, datetime, location), and issue a suitable / suitable-with-caveats / unsuitable verdict. Use after edi-inspect and before designing a mapping spec.
---

# ecocomDP Suitability Assessment

Decide whether this dataset belongs in ecocomDP at all. This is a **stop gate**: an
unsuitable dataset ends the workflow here rather than producing a spec that cannot work.

Read `profile.json` from `edi-inspect`. Do not re-parse the package.

## The four required axes

ecocomDP's required tables (`observation`, `location`, `taxon`, `dataset_summary`) mean
every dataset must supply four things. Check each and record the evidence.

### 1. Taxon — *what organism?*
- A column of taxonomic names or codes resolvable to an authority (ITIS, WoRMS…)
- Or `<taxonomicCoverage>` in the EML
- **Fails when:** the biological entity is not a taxon (e.g. "total chlorophyll",
  "biomass, all species pooled") — pooled measurements have no taxon axis

### 2. Value — *how much?*
- A quantity per taxon: count, density, biomass, cover, CPUE, presence/absence
- **Or** one row per individual, so counts can be derived by aggregation (pattern P4)
- **Fails when:** the only measurements are abiotic (temperature, nutrients) with no
  organism quantity

### 3. Datetime — *when?*
- Any resolution from year to timestamp; `ntl.356` uses bare years and coerces with
  `lubridate::ymd(paste0(dates, "-01-01"))`
- **Fails when:** there is no temporal dimension at all

### 4. Location — *where?*
- Site/plot/station columns, or coordinates, or EML `<geographicCoverage>` that can be
  joined to the data
- Coordinates may come from bounding boxes averaged to a point (10/15 corpus scripts)
- **Fails when:** observations cannot be attributed to any place

## Verdicts

**`suitable`** — all four axes present and unambiguous.

**`suitable-with-caveats`** — all four present, but at least one requires a judgement
call, a lossy transformation, or curator input. Typical causes:
- abundance must be derived by aggregating individual records (P4)
- coordinates only at bounding-box resolution, so all sites collapse to one point
- taxon codes that may not resolve to any authority
- ambiguous sampling design, so `event_id` grouping is a guess

**`unsuitable`** — one or more axes absent. Say which, and say plainly that conversion
should not proceed. Do not propose workarounds that fabricate a missing axis.

## Policy

Per `config/curator.yml` (`policy.on_suitable_with_caveats: stop`), a
`suitable-with-caveats` verdict **stops for curator confirmation** before spec design
begins. Present the caveats and wait. Do not proceed on your own judgement.

## Output

Write `suitability.md`:

```markdown
# Suitability Assessment — knb-lter-jrn.210007001.38

**Verdict: suitable-with-caveats**

## Axes

| Axis | Status | Evidence |
|---|---|---|
| Taxon | ✅ | `spp` — 18 codes, resolvable via `Lizardcodelist.txt` |
| Value | ⚠️ | No quantity column. One row = one captured lizard; counts derivable by aggregation (pattern P4) |
| Datetime | ✅ | `date`, daily resolution, 1989-06-16 → 2006-… |
| Location | ✅ | `zone`/`site`/`plot` hierarchy; coordinates from EML geographicCoverage |

## Caveats requiring curator input

1. **Recapture handling.** `rcap` flags recaptured individuals. Filtering them changes
   every count. Per curator policy this is always escalated — needs a decision before
   the spec can be finalized.
2. **Individual attributes are lost on aggregation.** `sex`, `SV_length`,
   `total_length`, `weight`, `tail` are per-organism and cannot survive as
   observation_ancillary on aggregated count rows. Options: drop them, or add a second
   variable (e.g. mean SV_length per group).

## Recommendation

Proceed to mapping design once (1) is answered. The dataset is a good ecocomDP fit
otherwise — clean taxonomy, long time series, nested spatial design.
```

## Notes

- Be decisive. A hedged verdict wastes the gate.
- "No value column" is not automatically a failure — check for individual records first.
- The abstract and methods sections often reveal an axis the columns hide, and vice
  versa. Trust the columns for what is mappable.
