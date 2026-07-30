# Flattening Pattern Library

Derived from the 15 conversion scripts in `examples/`. Each pattern gives the source
shape, how to detect it, the idiom, and a worked reference.

The goal of flattening is a single wide "flat" data frame (`L0_flat`) where **one row =
one observation** of one taxon's one variable at one place and time, carrying every
column the `create_*` functions will need.

---

## P1 — species-as-columns

**Source shape:** one column per taxon; cells hold counts/abundances.

**Detect:** many numeric columns whose names are taxon names or taxon codes; column names
appear in a code list or match a taxonomic authority.

**Idiom** — prefix value columns, then pivot the names into a taxon variable:

```r
wide <- wide %>% dplyr::rename_with(
  ~paste0("value.", .),
  .cols = starts_with(c("N_SNAILS", "N_SLUGS")))

wide <- wide %>% dplyr::rename(
  "unit.N_SNAILS" = "unit_N_SNAILS",
  "unit.N_SLUGS"  = "unit_N_SLUGS")

flat <- wide %>%
  tidyr::pivot_longer(cols = matches(c("N_SNAILS", "N_SLUGS")),
                      names_to = c(".value", "taxon_name_verbatim"),
                      names_sep = "\\.")

flat$variable_name <- "count"   # single measurement type, from metadata
```

**Reference:** `knb-lter-hbr.126` (gastropods)

**Notes:** `variable_name` is a constant here — the columns encoded *taxon*, not
variable. Keep the raw column name as `taxon_name_verbatim` in `taxon_ancillary`;
strip prefixes (`N_`) to get `taxon_name`.

---

## P2 — multi-measure wide

**Source shape:** one row per taxon-event, several measurement columns (CPUE, biomass,
density…).

**Detect:** a taxon identifier column *plus* 2+ numeric measure columns sharing a naming
convention.

**Idiom** — rename measures to `value_<name>`, pivot with `.value` and a variable slot:

```r
wide <- wide %>%
  dplyr::rename(value_CPUE    = CPUE,
                value_LOGCPUE = LOGCPUE)

flat <- tidyr::pivot_longer(
  wide,
  cols      = matches("CPUE"),
  names_to  = c(".value", "variable_name"),
  names_sep = "\\_")
```

**Reference:** `knb-lter-ntl.356` (fish abundance)

**Notes:** the separator must not occur inside the measure names, or the pivot silently
mis-splits. Prefer `.` as separator (as in P1) when names contain underscores.

---

## P3 — already-long with taxon lookup

**Source shape:** tidy long data, one row per observation, taxon referenced by FK.

**Detect:** a `taxon_id`/`species_code` column plus a separate taxon table in the package.

**Idiom** — join, no pivot:

```r
wide <- dplyr::left_join(fish, taxa, by = "taxon_id")
wide <- wide %>% dplyr::left_join(location, by = "WBIC")
```

**Reference:** `knb-lter-ntl.356` (the fish/taxa/location join)

**Notes:** the easiest case. Check the join is not fan-out — a duplicated key in the
lookup silently multiplies observation rows.

---

## P4 — individual organism records

**Source shape:** one row per captured/observed individual. No count column exists;
abundance is implicit in row multiplicity.

**Detect:** one row per organism, with individual-level attributes (sex, length, weight,
tag/toe number, recapture flag) and no quantity column.

**Idiom** — aggregate to counts before anything else:

```r
flat <- lizards %>%
  dplyr::group_by(date, zone, site, plot, taxon_name) %>%
  dplyr::summarise(value = dplyr::n(), .groups = "drop")

flat$variable_name <- "count"
flat$unit          <- "number"
```

**Reference:** the staged Jornada package `knb-lter-jrn.210007001.38` (lizard pitfall).
No corpus script uses this pattern — it is a deliberate off-corpus case.

**⚠ Escalate, never decide:** individual-level data usually carries a **recapture flag**
(`rcap` in Jornada). Whether recaptures are filtered before aggregation changes every
count in the output and is a scientific judgement about what the abundance measure
means. Per curator policy this is **always escalated** — record it in `open_questions`
and stop; do not pick a default.

Aggregating also destroys individual-level attributes (sex, length, weight). Those can
no longer be `observation_ancillary` on the aggregated rows. Either keep them out, or
propose a second `variable_name` (e.g. mean length) — and say which you did in NOTES.md.

---

## Cross-cutting: grouping decisions

These two are the highest-risk choices in any pattern. They are dataset-specific and
the corpus shows no default worth trusting.

### `location_id`
Group by the finest spatial unit that observations are actually attributed to:

```r
flat$location_id <- flat %>% group_by(WATERSHED) %>% group_indices()
```

If the source has a spatial hierarchy, pass it to `create_location()` **coarse → fine**
and let the package build the nesting via `parent_location_id`:

```r
location_name = c("block", "fence", "plot")   # bnz.502
location_name = c("SITENAME", "TREATMENT")    # fce.1203
```

### `event_id`
Group by what constitutes one sampling event. The corpus varies genuinely:

| Script | Grouping | Meaning |
|---|---|---|
| `ntl.356` | `group_by(YEAR)` | annual survey |
| `hbr.126` | `group_by(floor_date(DATE,"month"), WATERSHED)` | monthly, per watershed |

Read the methods section of the EML before choosing. State the reasoning in NOTES.md.

---

## Constant tail (all patterns)

After flattening, every script does the same thing:

```r
dates <- flat$DATE %>% na.omit() %>% sort()

flat$package_id          <- derived_id
flat$original_package_id <- source_id
flat$length_of_survey_years      <- ecocomDP::calc_length_of_survey_years(dates)
flat$number_of_years_sampled     <- ecocomDP::calc_number_of_years_sampled(dates)
flat$std_dev_interval_betw_years <- ecocomDP::calc_std_dev_interval_betw_years(dates)
flat$max_num_taxa                <- length(unique(flat$taxon_name))
flat$geo_extent_bounding_box_m2  <- ecocomDP::calc_geo_extent_bounding_box_m2(
  min(flat$longitude, na.rm = TRUE), max(flat$longitude, na.rm = TRUE),
  max(flat$latitude,  na.rm = TRUE), min(flat$latitude,  na.rm = TRUE))

flat <- flat %>% dplyr::rename(datetime = DATE)
flat$author <- NA_character_
```

Where the source has only a year (`ntl.356`), dates must be coerced first:

```r
dates <- lubridate::ymd(paste0(dates, "-01-01"))
```
