import re, glob, csv, os, collections

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "examples", "*.R")

varmap = {}   # (var, id) -> {system,label,seen}
issues = []   # corpus defects found and repaired
isabout = {}  # (label, uri) -> seen

for path in sorted(glob.glob(SRC)):
    pkg = os.path.basename(path).replace(".create_ecocomDP.R", "")
    txt = open(path, encoding="utf-8", errors="replace").read()

    # --- variable_mapping blocks -------------------------------------------
    # i <- variable_mapping$variable_name == 'X'   ... then mapped_* assignments
    for m in re.finditer(
        r"""i\s*<-\s*variable_mapping\$variable_name\s*==\s*['"]([^'"]+)['"](.*?)(?=\n\s*i\s*<-|\Z)""",
        txt, re.S):
        var, block = m.group(1), m.group(2)
        sysm = re.search(r"mapped_system\[i\]\s*<-\s*['\"]([^'\"]+)['\"]", block)
        idm  = re.search(r"mapped_id\[i\]\s*<-\s*['\"]([^'\"]+)['\"]", block)
        labm = re.search(r"mapped_label\[i\]\s*<-\s*['\"]([^'\"]+)['\"]", block)
        if not idm:
            continue
        uri = idm.group(1)
        label = labm.group(1) if labm else ""

        # The corpus contains two defects in these blocks. Repair rather than
        # inherit; every repair is reported so it stays visible.
        if not uri.startswith("http") and label.startswith("http"):
            # mapped_id / mapped_label swapped (pie.404, pie.405)
            issues.append((pkg, var, "id/label swapped", uri, label))
            uri, label = label, uri
        elif not uri.startswith("http"):
            # mapped_id holds prose, not a URI (pie.405 ABUNDANCE)
            issues.append((pkg, var, "mapped_id is not a URI — dropped", uri, label))
            continue

        key = (var, uri)
        rec = varmap.setdefault(key, {
            "system": sysm.group(1) if sysm else "",
            "label": label,
            "seen": set()})
        rec["seen"].add(pkg)

    # --- dataset_annotations (is_about) ------------------------------------
    # Labels are backtick-quoted (`label` = "uri") or, when a single bare word,
    # unquoted (estuary = "uri"). Skip commented-out lines.
    for am in re.finditer(
        r"""(?:^|\n)(?!\s*#)[^\S\n]*(?:`([^`]+)`|(\w+))\s*=\s*\n?\s*["']([^"']+)["']""",
        txt):
        label = (am.group(1) or am.group(2)).strip()
        uri = am.group(3).strip()
        if not uri.startswith("http"):
            continue
        isabout.setdefault((label, uri), set()).add(pkg)

OUT = os.path.join(HERE, "..", "kb")

with open(f"{OUT}/lexicon-variable-mapping.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["variable_name", "mapped_system", "mapped_id", "mapped_label",
                "n_uses", "seen_in"])
    for (var, uri), r in sorted(varmap.items(),
                                key=lambda kv: (-len(kv[1]["seen"]), kv[0][0])):
        w.writerow([var, r["system"], uri, r["label"], len(r["seen"]),
                    ";".join(sorted(r["seen"]))])

with open(f"{OUT}/lexicon-is-about.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["label", "uri", "n_uses", "seen_in"])
    for (label, uri), seen in sorted(isabout.items(),
                                     key=lambda kv: (-len(kv[1]), kv[0][0])):
        w.writerow([label, uri, len(seen), ";".join(sorted(seen))])

with open(f"{OUT}/lexicon-corpus-issues.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["script", "variable_name", "issue", "mapped_id_raw", "mapped_label_raw"])
    for row in sorted(issues):
        w.writerow(row)

print(f"corpus defects repaired:  {len(issues)}")
for i in sorted(issues):
    print(f"   {i[0]} [{i[1]}] {i[2]}")
print(f"variable_mapping entries: {len(varmap)}")
print(f"is_about entries:         {len(isabout)}")
print("\n--- top variable_mapping ---")
for (var, uri), r in sorted(varmap.items(), key=lambda kv: -len(kv[1]["seen"]))[:12]:
    print(f"{len(r['seen']):2d}  {var:28s} {r['label']:24s} {uri}")
print("\n--- top is_about ---")
for (label, uri), seen in sorted(isabout.items(), key=lambda kv: -len(kv[1]))[:12]:
    print(f"{len(seen):2d}  {label:34s} {uri}")
