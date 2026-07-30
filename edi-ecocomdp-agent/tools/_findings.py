"""Shared Finding type and reporter for the static validators
(validate_spec.py, validate_script.py). Defined once so the two agree on finding
format and exit semantics; imported as a sibling module when either runs."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Finding:
    level: str          # "ERROR" | "WARN"
    check: str          # check id, e.g. "column_existence"
    message: str
    where: str = ""     # optional location, e.g. "ancillary.observation[3]"

    def __str__(self) -> str:
        loc = f" ({self.where})" if self.where else ""
        return f"  [{self.level}] {self.check}: {self.message}{loc}"


def report(header: str, findings: list[Finding], pass_message: str) -> int:
    """Print a check report; return 1 if any ERROR finding, else 0."""
    errors = [f for f in findings if f.level == "ERROR"]
    print(header)
    if not findings:
        print(f"  {pass_message}")
    for f in findings:
        print(f)
    print(f"  {len(errors)} error(s), {len(findings) - len(errors)} warning(s)")
    return 1 if errors else 0
