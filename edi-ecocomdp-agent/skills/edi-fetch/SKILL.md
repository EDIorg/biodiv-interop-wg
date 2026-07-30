---
name: edi-fetch
description: Download an EDI data package from a URL or packageId into a local directory that edi-inspect can read, using the EDI PASTA REST API. Use as the first step when a conversion is started from a link or identifier rather than an already-downloaded package on disk.
---

# EDI Package Fetch

Turn a **URL or packageId** into a downloaded package directory, so a conversion can start
from a link. This is the only stage that contacts EDI, and it is **read-only** — it
downloads and nothing else. The agent still never uploads, publishes, or runs R.

If the curator already has the package on disk, skip this entirely and start at
`edi-inspect`.

## Input

Any one of:

- a packageId — `knb-lter-jrn.210007001.38`, or `knb-lter-jrn.210007001` (revision omitted
  ⇒ the newest is resolved)
- a PASTA API URL — `https://pasta.lternet.edu/package/metadata/eml/knb-lter-jrn/210007001/38`
- a portal landing page — `https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-jrn&identifier=210007001&revision=38`

## Procedure

Run the downloader. It is pure Python (stdlib) — no R, consistent with v1:

```sh
python3 ecocomdp-agent/tools/edi-fetch.py <url-or-packageId> \
  --config ecocomdp-agent/config/curator.yml
```

It creates `conversions/` if absent and a `conversions/<source_id>/` subdirectory named for
the source packageId, then writes into it:

- `<source_id>.xml` — the EML metadata (the file `edi-inspect` reads)
- one file per data entity, under its EML `objectName`

Preview without downloading with `--dry-run` (prints the resolved id and URLs, writes
nothing). Use it to confirm the identifier parsed correctly before a large fetch.

## Credentials

Public EDI packages need none — run the tool as-is. For a **private or embargoed** package
the download returns HTTP 401/403; supply credentials via the `repository.auth` block of
`config/curator.yml`, which reads them from environment variables (`EDI_PASSWORD` or
`EDI_TOKEN` by default). Never put a real secret in `curator.yml` itself.

If a fetch fails auth, say so and stop — do not fall back to fabricating a profile from
the metadata alone.

## Output

- `conversions/<source_id>/` containing the EML and data files

The nested `conversions/<source_id>/<derived_id>/` directory — the destination for the
converted ecocomDP result — is **not** created here; it is created at render time, once the
curator has assigned `derived_id`.

Hand off to `edi-inspect`, pointing it at `conversions/<source_id>/`. From there the
workflow is unchanged.

## Boundaries

- **Read-only.** Downloading is the entire job. No `write_*`, no publication, no PASTA
  POST/PUT.
- **Do not verify or repair the download here.** Whether the data matches its metadata is
  `edi-inspect`'s finding to make.
- The tool's HTTP path is not exercised in the build environment; its URL parsing and
  file planning are. Treat a clean local run as the first real network test, and report
  what it actually wrote.
