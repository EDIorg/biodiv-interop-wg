#!/usr/bin/env python3
"""edi-fetch.py — download an EDI data package by URL or packageId, so a
conversion can start from a link instead of a hand-downloaded directory.

    edi-fetch.py <url-or-packageId> [--out DIR] [--config curator.yml] [--dry-run]

Accepts any of:
  * a packageId            knb-lter-jrn.210007001.38   (revision optional →
                           newest is resolved)         knb-lter-jrn.210007001
  * a PASTA API URL        https://pasta.lternet.edu/package/metadata/eml/
                           knb-lter-jrn/210007001/38
  * a portal landing page  https://portal.edirepository.org/nis/mapbrowse?
                           scope=knb-lter-jrn&identifier=210007001&revision=38

Writes, into <out>/<source_id>/ (default conversions/<source_id>/):
  <source_id>.xml          the EML metadata (what edi-inspect reads)
  <objectName>             each data entity, under its EML objectName

The ecocomDP result of the conversion is written later, by the generated script, into a
nested <source_id>/<derived_id>/ directory — this tool only lands the source package.

This is READ-ONLY. It downloads; it never uploads, publishes, or runs R — the
other v1 invariants are untouched. Credentials come from the `repository.auth`
block of curator.yml (env-var backed — see that file). As of 2026-07 PASTA
refuses anonymous reads even for public packages, so an API access key from
https://auth.edirepository.org is effectively required. PASTA takes that key as
a `key=` query parameter; a bearer header is rejected with 400 and a cookie with
401.

Uses only the standard library. The HTTP path has been exercised against
pasta.lternet.edu (knb-lter-jrn.210007001.38, key auth); --dry-run still covers
URL parsing and file planning without touching the network.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.request
import urllib.error
import urllib.parse
from pathlib import Path
from xml.etree import ElementTree as ET

try:
    import yaml
except ImportError:
    yaml = None   # only needed when a --config with auth is supplied

DEFAULT_BASE = "https://pasta.lternet.edu/package"


# --------------------------------------------------------------------------- #
# Identify the package from whatever the curator pasted                        #
# --------------------------------------------------------------------------- #

def parse_source(arg: str) -> tuple[str, str, str | None]:
    """Return (scope, identifier, revision|None) from a packageId or URL."""
    arg = arg.strip()

    # portal landing page: ?scope=..&identifier=..&revision=..
    m_scope = re.search(r"[?&]scope=([^&]+)", arg)
    m_ident = re.search(r"[?&]identifier=([^&]+)", arg)
    if m_scope and m_ident:
        rev = re.search(r"[?&]revision=([^&]+)", arg)
        return m_scope.group(1), m_ident.group(1), rev.group(1) if rev else None

    # PASTA API URL: .../eml/<scope>/<identifier>[/<revision>]
    m = re.search(r"/eml/([^/]+)/(\d+)(?:/(\d+))?", arg)
    if m:
        return m.group(1), m.group(2), m.group(3)

    # bare packageId: scope.identifier[.revision], scope may contain dots
    m = re.fullmatch(r"(.+)\.(\d+)\.(\d+)", arg)
    if m:
        return m.group(1), m.group(2), m.group(3)
    m = re.fullmatch(r"(.+)\.(\d+)", arg)
    if m:
        return m.group(1), m.group(2), None

    sys.exit(f"edi-fetch: cannot parse a scope/identifier/revision from {arg!r}")


# --------------------------------------------------------------------------- #
# HTTP (stdlib only)                                                          #
# --------------------------------------------------------------------------- #

def build_opener(cfg: dict) -> urllib.request.OpenerDirector:
    """An opener carrying EDI credentials if curator.yml supplies any. Absent
    credentials, requests go out unauthenticated — correct for public data."""
    auth = ((cfg.get("repository") or {}).get("auth") or {})
    handlers = []

    user = auth.get("user") or _env(auth.get("user_env"))
    password = auth.get("password") or _env(auth.get("password_env"))
    if user and password:
        mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
        base = (cfg.get("repository") or {}).get("base_url", DEFAULT_BASE)
        mgr.add_password(None, base, user, password)
        handlers.append(urllib.request.HTTPBasicAuthHandler(mgr))

    opener = urllib.request.build_opener(*handlers)
    # EDI issues an API access key at https://auth.edirepository.org. PASTA takes
    # it as a `key=` query parameter — it accepts neither a bearer header (400)
    # nor a cookie (401). http_get appends it to every request.
    opener.edi_api_key = auth.get("token") or _env(auth.get("token_env"))
    return opener


def _env(name: str | None) -> str | None:
    return os.environ.get(name) if name else None


def http_get(opener, url: str) -> bytes:
    # The access key rides on the query string. Appended here so every request
    # carries it and no caller has to remember; `url` itself stays key-free, so
    # printing it — including in the error below — never leaks the secret.
    key = getattr(opener, "edi_api_key", None)
    request_url = url
    if key:
        sep = "&" if urllib.parse.urlparse(url).query else "?"
        request_url = url + sep + urllib.parse.urlencode({"key": key})
    try:
        with opener.open(request_url, timeout=120) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        detail = "authentication failed — key missing, invalid, or expired" \
            if e.code in (401, 403) else e.reason
        sys.exit(f"edi-fetch: GET {url}\n  HTTP {e.code}: {detail}")
    except urllib.error.URLError as e:
        sys.exit(f"edi-fetch: GET {url}\n  network error: {e.reason}")


# --------------------------------------------------------------------------- #
# PASTA endpoints                                                             #
# --------------------------------------------------------------------------- #

def newest_revision(opener, base, scope, ident) -> str:
    body = http_get(opener, f"{base}/eml/{scope}/{ident}").decode().split()
    revs = [int(x) for x in body if x.strip().isdigit()]
    if not revs:
        sys.exit(f"edi-fetch: no revisions listed for {scope}.{ident}")
    return str(max(revs))


def entity_list(opener, base, scope, ident, rev) -> list[tuple[str, str]]:
    """[(entityId, entityName)] from the name endpoint (one 'id,name' per line)."""
    body = http_get(opener, f"{base}/name/eml/{scope}/{ident}/{rev}").decode()
    out = []
    for line in body.splitlines():
        if "," in line:
            eid, name = line.split(",", 1)
            out.append((eid.strip(), name.strip()))
    return out


# --------------------------------------------------------------------------- #
# EML parsing: entityName → objectName, namespace-agnostic                     #
# --------------------------------------------------------------------------- #

def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def eml_object_names(eml_bytes: bytes) -> dict[str, str]:
    """Map entityName → objectName for every dataTable/otherEntity. Matches by
    local tag name so it works whether or not the inner elements are namespaced
    (in this corpus only the root eml:eml is)."""
    root = ET.fromstring(eml_bytes)
    names: dict[str, str] = {}
    for el in root.iter():
        if _local(el.tag) in ("dataTable", "otherEntity", "spatialRaster",
                              "spatialVector", "view"):
            ename = oname = None
            for child in el.iter():
                lt = _local(child.tag)
                if lt == "entityName" and child.text:
                    ename = child.text.strip()
                elif lt == "objectName" and child.text and oname is None:
                    oname = child.text.strip()
            if ename:
                names[ename] = oname or ename
    return names


def safe_name(name: str, fallback: str) -> str:
    base = os.path.basename(name or "").strip()
    return base or fallback


# --------------------------------------------------------------------------- #
# Driver                                                                       #
# --------------------------------------------------------------------------- #

def load_config(path: str | None) -> dict:
    if not path:
        return {}
    if yaml is None:
        sys.exit("edi-fetch: --config needs PyYAML (pip install pyyaml)")
    return yaml.safe_load(Path(path).read_text()) or {}


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="packageId or URL")
    ap.add_argument("--out", default="conversions",
                    help="parent dir; package lands in <out>/<source_id>/")
    ap.add_argument("--config", help="curator.yml (for private-package auth)")
    ap.add_argument("--dry-run", action="store_true",
                    help="resolve and print the plan; make no network calls except "
                         "revision resolution")
    args = ap.parse_args(argv[1:])

    cfg = load_config(args.config)
    base = (cfg.get("repository") or {}).get("base_url", DEFAULT_BASE)
    opener = build_opener(cfg)

    scope, ident, rev = parse_source(args.source)
    if rev is None:
        if args.dry_run:
            print(f"  (would resolve newest revision of {scope}.{ident})")
            rev = "<newest>"
        else:
            rev = newest_revision(opener, base, scope, ident)
    source_id = f"{scope}.{ident}.{rev}"
    dest = Path(args.out) / source_id

    eml_url = f"{base}/metadata/eml/{scope}/{ident}/{rev}"
    name_url = f"{base}/name/eml/{scope}/{ident}/{rev}"
    print(f"edi-fetch: {source_id}")
    print(f"  base    {base}")
    print(f"  eml     {eml_url}")
    print(f"  names   {name_url}")
    print(f"  dest    {dest}/")

    if args.dry_run:
        print("  (dry run — no files written)")
        return 0

    dest.mkdir(parents=True, exist_ok=True)

    eml = http_get(opener, eml_url)
    (dest / f"{source_id}.xml").write_bytes(eml)
    obj_by_entity = eml_object_names(eml)

    entities = entity_list(opener, base, scope, ident, rev)
    if not entities:
        print("  WARNING: name endpoint returned no entities")
    for eid, ename in entities:
        fname = safe_name(obj_by_entity.get(ename, ""), eid)
        data = http_get(opener, f"{base}/data/eml/{scope}/{ident}/{rev}/{eid}")
        (dest / fname).write_bytes(data)
        print(f"  wrote   {fname}  ({len(data)} bytes)  [{ename}]")

    print(f"  done. {1 + len(entities)} files. Point edi-inspect at {dest}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
