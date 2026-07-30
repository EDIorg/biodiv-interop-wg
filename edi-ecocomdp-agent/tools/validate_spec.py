#!/usr/bin/env python3
"""validate_spec.py — executable static checks over a mapping.yaml.

Ports the R-free half of the seven static checks in
skills/ecocomdp-script-render/SKILL.md out of prose into deterministic code, so
correctness does not ride on a model reading a checklist. Everything here is
decidable from mapping.yaml + profile.json alone — no R, no network, no EDI.

  validate_spec.py conversions/<source_id>/mapping.yaml \
                   conversions/<source_id>/profile.json

Exit status: 0 if no ERROR findings, 1 otherwise. WARN never fails the run.

The checks that need the rendered R (assign-before-use, required-arguments,
balanced-syntax, and the full three-way table_set_consistency across the
create_*/create_variable_mapping/write_tables call sites) belong in a sibling
validate_script.py — they are stubbed at the bottom, not implemented here.

Skeleton status: the five checks below are implemented and run against the
Jornada example today. Expression parsing (filter/join predicates) and lexicon
membership are the two known-thin spots, marked TODO where they bite.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from _findings import Finding, report

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")


# --------------------------------------------------------------------------- #
# Column universe                                                              #
# --------------------------------------------------------------------------- #
#
# A spec may legitimately name a column that is NOT in profile.json, because the
# flatten step creates it. column_existence has to know every source those come
# from, or it produces false positives on exactly the derived columns the design
# is built around (value, taxon_name, ...). Assemble the full set once.

# Columns the renderer's template always synthesizes (kb/script-template.R).
SYNTHESIZED = {
    "observation_id", "event_id", "location_id", "taxon_id",
    "taxon_name", "taxon_rank", "authority_system", "authority_taxon_id",
    "datetime", "variable_name", "value", "unit",
    "package_id", "original_package_id", "author",
    "length_of_survey_years", "number_of_years_sampled",
    "std_dev_interval_betw_years", "max_num_taxa", "geo_extent_bounding_box_m2",
}


def known_columns(spec: dict, profile: dict) -> tuple[set[str], dict[str, object]]:
    """Return (all known column names, {source_col: profile_attr}).

    Sources, in order of trust:
      1. profile.json entities[].columns[].name  — real, measured
      2. source_tables.<alias>.format.fields[].name  — join-side columns (the
         fixed-width code list is parsed in-script, so it is not in profile)
      3. flatten.derive[].name  — columns the spec explicitly creates
      4. SYNTHESIZED  — columns the template always adds
    """
    cols: set[str] = set()
    attr_by_name: dict[str, object] = {}

    for ent in profile.get("entities", []):
        for c in ent.get("columns", []):
            cols.add(c["name"])
            attr_by_name[c["name"]] = c            # for unit lookups

    for alias, tbl in (spec.get("source_tables") or {}).items():
        fmt = tbl.get("format") or {}
        for f in fmt.get("fields", []) or []:
            cols.add(f["name"])

    for d in (spec.get("flatten") or {}).get("derive", []) or []:
        if isinstance(d, dict) and "name" in d:
            cols.add(d["name"])

    # taxon.taxon_name_verbatim: <src> is an alias directive — the renderer
    # creates a column named by the KEY from the source column named by the
    # value. The key is a real created column; the value is a source column.
    tax = spec.get("taxon") or {}
    if "taxon_name_verbatim" in tax:
        cols.add("taxon_name_verbatim")

    cols |= SYNTHESIZED
    return cols, attr_by_name


# --------------------------------------------------------------------------- #
# Checks                                                                       #
# --------------------------------------------------------------------------- #

def check_column_existence(spec, profile, cols, attrs) -> list[Finding]:
    """Every column the spec names in a structural position exists.

    Structural positions checked: join keys, event_id/location_id/taxon_id
    group_by, datetime, location_name, and the ancillary column lists.

    NOT checked: annotation keys (those are ecocomDP *variable names* like
    'count', not source columns) and filter/join predicate *expressions* (free R
    strings — see TODO). Deliberately narrow to stay false-positive-free.
    """
    out: list[Finding] = []

    def ref(name, where):
        if name not in cols:
            out.append(Finding("ERROR", "column_existence",
                               f"column '{name}' is not in profile.json, a join "
                               f"table, or a derived/synthesized column", where))

    flat = spec.get("flatten") or {}
    for i, j in enumerate(flat.get("joins", []) or []):
        for lc, rc in (j.get("by") or {}).items():
            ref(lc, f"flatten.joins[{i}].by (left)")
            ref(rc, f"flatten.joins[{i}].by (right)")

    obs = spec.get("observation") or {}
    for key in ("event_id", "location_id", "taxon_id"):
        for c in (obs.get(key) or {}).get("group_by", []) or []:
            ref(c, f"observation.{key}.group_by")
    if isinstance(obs.get("datetime"), str):
        ref(obs["datetime"], "observation.datetime")

    for c in (spec.get("location") or {}).get("location_name", []) or []:
        ref(c, "location.location_name")

    anc = spec.get("ancillary") or {}
    for tbl in ("observation", "location", "taxon"):
        for k, c in enumerate(anc.get(tbl, []) or []):
            ref(c, f"ancillary.{tbl}[{k}]")

    # TODO: parse simple predicates out of flatten.filters[].expr / join exprs
    # ("spp != 'NONE'", "!is.na(plot)") and ref() the columns in them. Skipped
    # in the skeleton rather than done with a fragile regex.
    return out


def check_unit_columns_exist(spec, profile, cols, attrs) -> list[Finding]:
    """Static check #6. Every unit_<col> in ancillary.units names a base column
    that actually declares a unit in the EML (profile attr.unit is non-null).

    add_unit_columns() only emits unit_<col> where the attribute has a
    standard/custom unit; a spec that lists one for a unitless column references
    a column that is never created and the create_*_ancillary(unit=) call fails.
    """
    out: list[Finding] = []
    units = (spec.get("ancillary") or {}).get("units") or {}
    for tbl, entries in units.items():
        for k, u in enumerate(entries or []):
            where = f"ancillary.units.{tbl}[{k}]"
            if not u.startswith("unit_"):
                out.append(Finding("ERROR", "unit_columns_exist",
                                   f"'{u}' should be named unit_<column>", where))
                continue
            base = u[len("unit_"):]
            if base not in cols:
                out.append(Finding("ERROR", "unit_columns_exist",
                                   f"base column '{base}' for '{u}' does not exist",
                                   where))
            elif base in attrs and attrs[base].get("unit") in (None, "", "dimensionless"):
                out.append(Finding("ERROR", "unit_columns_exist",
                                   f"'{base}' declares no unit in the EML, so '{u}' "
                                   f"is never created", where))
    return out


def check_core_ancillary_disjoint(spec, profile, cols, attrs) -> list[Finding]:
    """Static check #5. No column is both a core observation column and an
    ancillary variable. Double-mapping duplicates the value into two tables."""
    out: list[Finding] = []
    obs = spec.get("observation") or {}
    core = set()
    for key in ("datetime", "value", "variable_name", "unit"):
        v = obs.get(key)
        if isinstance(v, str):
            core.add(v)
    anc = spec.get("ancillary") or {}
    for tbl in ("observation", "location", "taxon"):
        for k, c in enumerate(anc.get(tbl, []) or []):
            if c in core:
                out.append(Finding("ERROR", "core_ancillary_disjointness",
                                   f"'{c}' is a core observation column and also "
                                   f"ancillary.{tbl}", f"ancillary.{tbl}[{k}]"))
    return out


def check_rationale_present(spec, profile, cols, attrs) -> list[Finding]:
    """Invariant (DESIGN.md §8): event_id and location_id must each carry a
    non-empty rationale. The two highest-risk, least-verifiable decisions."""
    out: list[Finding] = []
    obs = spec.get("observation") or {}
    for key in ("event_id", "location_id"):
        r = (obs.get(key) or {}).get("rationale")
        if not (isinstance(r, str) and r.strip()):
            out.append(Finding("ERROR", "rationale_present",
                               f"observation.{key} has no rationale", key))
    return out


def check_null_annotation_has_question(spec, profile, cols, attrs) -> list[Finding]:
    """Schema rule: every variable_mapping entry with id: null must be traceable
    to an open_questions entry, so a gap is a visible decision, not a silent one.

    Matching is by mention: the variable name (or an `affected:` list) appears in
    some open question. Loose on purpose — the point is coverage, not linkage.
    """
    out: list[Finding] = []
    ann = ((spec.get("annotations") or {}).get("variable_mapping") or {})
    qs = spec.get("open_questions") or []
    mentioned: set[str] = set()
    for q in qs:
        blob = json.dumps(q)
        for name in ann:
            if name in blob:
                mentioned.add(name)
        for a in q.get("affected", []) or []:
            mentioned.add(a)
    for name, body in ann.items():
        if (body or {}).get("id") is None and name not in mentioned:
            out.append(Finding("WARN", "null_annotation_has_question",
                               f"'{name}' has id: null but no open_questions entry "
                               f"mentions it", f"annotations.variable_mapping.{name}"))
    return out


CHECKS = [
    check_column_existence,
    check_unit_columns_exist,
    check_core_ancillary_disjoint,
    check_rationale_present,
    check_null_annotation_has_question,
]


# --------------------------------------------------------------------------- #
# Stubs — implemented in the sibling validate_script.py (needs rendered R)     #
# --------------------------------------------------------------------------- #

def _script_level_stub():
    """These operate on create_ecocomDP.R, not the spec, so they live elsewhere:

      table_set_consistency  — the ntl.356 guard: the ancillary table set must be
                               identical across the create_*_ancillary
                               assignments, create_variable_mapping() args, and
                               write_tables() args. The spec's ancillary block is
                               a single source, but the three call sites are only
                               materialized in the R; verify there.
      assign_before_use      — every object assigned before reference.
      required_arguments     — create_observation/create_taxon/... arg presence.
      balanced_syntax        — parens/quotes/%>% not truncated.
    """
    raise NotImplementedError("see validate_script.py")


# --------------------------------------------------------------------------- #
# Driver                                                                       #
# --------------------------------------------------------------------------- #

def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.exit(f"usage: {Path(argv[0]).name} <mapping.yaml> <profile.json>")
    spec = yaml.safe_load(Path(argv[1]).read_text())
    profile = json.loads(Path(argv[2]).read_text())
    cols, attrs = known_columns(spec, profile)

    findings: list[Finding] = []
    for check in CHECKS:
        findings.extend(check(spec, profile, cols, attrs))

    return report(f"validate_spec: {spec.get('source_id', '?')}", findings,
                  "all checks pass (static; script not rendered or executed)")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
