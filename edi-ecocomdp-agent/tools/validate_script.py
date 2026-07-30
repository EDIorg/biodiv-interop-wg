#!/usr/bin/env python3
"""validate_script.py — conformance checks: does create_ecocomDP.R implement the
approved mapping.yaml?

Scope, deliberately narrow (see the design discussion): this does NOT re-check
anything the curator's `Rscript` run or ecocomDP::validate_data() already covers
— syntax, variable binding, argument presence, output-table validity. Those are
the curator's job and R does them better. This checks the ONE thing nothing else
does: that the mechanical renderer produced the spec the curator approved, and
did not silently diverge.

  validate_script.py conversions/<id>/create_ecocomDP.R conversions/<id>/mapping.yaml

Every check compares a decision extracted from the R text against the same
decision in the spec. It is data-independent (no EDI, no R, no network) and
spec-aware (which the R interpreter and validate_data() are not). A script that
passes here and runs clean is faithful to the approved spec; a script that runs
clean but fails here betrays the approval, which is exactly the gap the review
model leaves open.

Text-parsing skeleton: regexes are tuned to the corpus idiom in
kb/script-template.R. A script hand-edited away from that idiom may not parse —
in which case a check reports "could not locate", never a false pass.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from _findings import Finding, report

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")


# --------------------------------------------------------------------------- #
# R text helpers (no interpreter — string extraction only)                    #
# --------------------------------------------------------------------------- #

def code_only(text: str) -> str:
    """Drop full-line comments so the commented-out annotation stubs (which name
    real variables and empty URIs) never read as active code. Inline trailing
    comments are left — no active pattern here spans one."""
    return "\n".join(
        ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))


def call_region(text: str, open_paren: int) -> str:
    """Return text from the '(' at open_paren to its matching ')', quote-aware.
    Needed because create_*_ancillary() nests c(...), so a non-greedy regex would
    truncate at the inner close paren."""
    depth, i, instr = 0, open_paren, None
    while i < len(text):
        ch = text[i]
        if instr:
            if ch == instr:
                instr = None
        elif ch in "\"'":
            instr = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren:i + 1]
        i += 1
    return text[open_paren:]


def find_call(text: str, fn: str) -> list[str]:
    """All balanced argument regions for calls to `fn` (e.g.
    'ecocomDP::create_observation_ancillary')."""
    regions = []
    for m in re.finditer(re.escape(fn) + r"\s*\(", text):
        regions.append(call_region(text, m.end() - 1))
    return regions


def string_vec(region: str, arg: str) -> list[str] | None:
    """Pull the quoted tokens from `arg = c("a", "b", ...)` inside a call region.
    Returns None if the argument isn't present."""
    m = re.search(arg + r"\s*=\s*c\(([^)]*)\)", region)
    if not m:
        return None
    return re.findall(r"""['"]([^'"]+)['"]""", m.group(1))


def col_list(s: str) -> list[str]:
    return [c.strip() for c in s.split(",") if c.strip()]


# --------------------------------------------------------------------------- #
# Conformance checks                                                           #
# --------------------------------------------------------------------------- #

def check_groupings(r, code, spec) -> list[Finding]:
    """event_id / location_id / taxon_id must group by exactly the spec columns.
    The single most consequential thing the renderer can get wrong, and neither R
    nor validate_data() knows what the grouping was supposed to be."""
    out = []
    found = dict(re.findall(
        r"flat\$(\w+)\s*<-\s*flat\s*%>%\s*dplyr::group_by\(([^)]*)\)"
        r"\s*%>%\s*dplyr::group_indices\(\)", code))
    obs = spec.get("observation") or {}
    wanted = {
        "event_id": (obs.get("event_id") or {}).get("group_by"),
        "location_id": (obs.get("location_id") or {}).get("group_by"),
        "taxon_id": (obs.get("taxon_id") or {}).get("group_by"),
    }
    for key, want in wanted.items():
        if want is None:
            continue
        if key not in found:
            out.append(Finding("ERROR", "groupings",
                               f"{key}: no group_by(...) %>% group_indices() found "
                               f"in the script"))
            continue
        got = col_list(found[key])
        if set(got) != set(want):
            out.append(Finding("ERROR", "groupings",
                               f"{key}: script groups by {got}, spec says {want}"))
    return out


def check_datetime_rename(r, code, spec) -> list[Finding]:
    out = []
    want = (spec.get("observation") or {}).get("datetime")
    m = re.search(r"dplyr::rename\(datetime\s*=\s*(\w+)\)", code)
    if want and not m:
        out.append(Finding("ERROR", "datetime",
                           f"spec renames datetime from '{want}' but no "
                           f"rename(datetime = ...) found"))
    elif want and m and m.group(1) != want:
        out.append(Finding("ERROR", "datetime",
                           f"script renames datetime from '{m.group(1)}', "
                           f"spec says '{want}'"))
    return out


def check_location_name(r, code, spec) -> list[Finding]:
    out = []
    want = (spec.get("location") or {}).get("location_name")
    for region in find_call(code, "ecocomDP::create_location"):
        got = string_vec(region, "location_name")
        if want and got is not None and got != want:
            out.append(Finding("ERROR", "location_name",
                               f"create_location location_name = {got}, "
                               f"spec says {want}"))
    return out


def _anc_table_name(obj: str) -> str:
    # object 'observation_ancillary' -> spec key 'observation'
    return obj[:-len("_ancillary")] if obj.endswith("_ancillary") else obj


def check_ancillary_table_set(r, code, spec) -> list[Finding]:
    """The ntl.356 guard, as conformance. The set of ancillary tables must be
    identical across: the create_*_ancillary assignments, the
    create_variable_mapping() args, the write_tables() args, AND the spec's
    non-empty ancillary block. R catches an omitted-create only at runtime, late
    and cryptically, and only if that path runs; this catches every mismatch,
    early, and names the offending table."""
    out = []

    assigned = set(re.findall(r"(\w+_ancillary)\s*<-\s*ecocomDP::create_\w+_ancillary",
                              code))

    vm = find_call(code, "ecocomDP::create_variable_mapping")
    vm_args = set()
    if vm:
        vm_args = {a for a in re.findall(r"(\w+_ancillary)\s*=", vm[0])}

    wt = find_call(code, "ecocomDP::write_tables")
    wt_args = set()
    if wt:
        wt_args = {a for a in re.findall(r"(\w+_ancillary)\s*=", wt[0])}

    anc = spec.get("ancillary") or {}
    spec_tables = {f"{t}_ancillary" for t in ("observation", "location", "taxon")
                   if anc.get(t)}                      # non-empty only

    sites = {"assigned": assigned, "variable_mapping": vm_args,
             "write_tables": wt_args, "spec": spec_tables}
    union = set().union(*sites.values())
    for tbl in sorted(union):
        missing = [name for name, s in sites.items() if tbl not in s]
        if missing:
            present = [name for name, s in sites.items() if tbl in s]
            out.append(Finding("ERROR", "ancillary_table_set",
                               f"'{tbl}' appears in {present} but is MISSING from "
                               f"{missing} (this is the ntl.356 class)"))
    return out


def check_ancillary_vectors(r, code, spec) -> list[Finding]:
    """Each create_*_ancillary variable_name / unit vector equals the spec list."""
    out = []
    anc = spec.get("ancillary") or {}
    units = (anc.get("units") or {})
    fn = {"observation": "ecocomDP::create_observation_ancillary",
          "taxon": "ecocomDP::create_taxon_ancillary",
          "location": "ecocomDP::create_location_ancillary"}
    for tbl, want in (("observation", anc.get("observation")),
                      ("taxon", anc.get("taxon")),
                      ("location", anc.get("location"))):
        if not want:
            continue
        regions = find_call(code, fn[tbl])
        if not regions:
            out.append(Finding("ERROR", "ancillary_vectors",
                               f"{tbl}_ancillary declared in spec but no "
                               f"{fn[tbl]}(...) call found"))
            continue
        got = string_vec(regions[0], "variable_name")
        if got is not None and got != want:
            out.append(Finding("ERROR", "ancillary_vectors",
                               f"{tbl}_ancillary variable_name = {got}, "
                               f"spec says {want}"))
        want_u = units.get(tbl)
        if want_u:
            got_u = string_vec(regions[0], "unit")
            if got_u is not None and got_u != want_u:
                out.append(Finding("ERROR", "ancillary_vectors",
                                   f"{tbl}_ancillary unit = {got_u}, "
                                   f"spec says {want_u}"))
    return out


def check_annotations(r, code, spec) -> list[Finding]:
    """Every emitted variable_mapping URI equals the approved one, and no URI is
    emitted for a variable the spec left id: null. This is the ECSO_00001688-vs-
    ECSO_00001685 hazard: a three-character drift in a rendered URI passes every
    R check and validate_data(), publishing wrong semantics. Only a spec diff
    catches it."""
    out = []
    emitted = dict(re.findall(
        r"variable_name\s*==\s*'([^']+)'[\s\S]*?"
        r"mapped_id\[i\]\s*<-\s*'([^']+)'", code))
    vm = ((spec.get("annotations") or {}).get("variable_mapping") or {})
    approved = {k: v["id"] for k, v in vm.items() if (v or {}).get("id")}

    for name, uri in emitted.items():
        if name not in approved:
            out.append(Finding("ERROR", "annotations",
                               f"'{name}' is annotated in the script (id {uri}) but "
                               f"the spec leaves it id: null — unapproved URI"))
        elif uri != approved[name]:
            out.append(Finding("ERROR", "annotations",
                               f"'{name}' URI drift: script {uri}, "
                               f"spec {approved[name]}"))
    for name, uri in approved.items():
        if name not in emitted:
            out.append(Finding("ERROR", "annotations",
                               f"'{name}' approved (id {uri}) but not emitted in the "
                               f"script"))
    return out


CHECKS = [
    check_groupings,
    check_datetime_rename,
    check_location_name,
    check_ancillary_table_set,
    check_ancillary_vectors,
    check_annotations,
]

# Extension points, same conformance pattern, not in this skeleton:
#   - is_about dataset_annotations c(...) vs spec.annotations.is_about
#   - taxon resolver / data.sources vs spec.taxon
#   - filter predicates vs spec.flatten.filters (needs expr parsing)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.exit(f"usage: {Path(argv[0]).name} <create_ecocomDP.R> <mapping.yaml>")
    r = Path(argv[1]).read_text()
    code = code_only(r)
    spec = yaml.safe_load(Path(argv[2]).read_text())

    findings = []
    for check in CHECKS:
        findings.extend(check(r, code, spec))

    return report(f"validate_script: {spec.get('source_id', '?')} (conformance to spec)",
                  findings, "script conforms to the approved spec (static; not executed)")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
