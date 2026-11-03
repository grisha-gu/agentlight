#!/bin/sh
# Board DRC: summary by type + everything that isn't silkscreen.
cd "$(dirname "$0")"
/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli pcb drc --format json -o build/drc.json agentlight.kicad_pcb >/dev/null 2>&1
python3 - <<'PY'
import collections, json
d = json.load(open("build/drc.json"))
print(dict(collections.Counter(v["type"] for v in d["violations"])), "unconnected:", len(d.get("unconnected_items", [])))
seen = collections.Counter()
for v in d["violations"]:
    if v["type"].startswith("silk") or v["type"] == "nonmirrored_text_on_back_layer":
        continue
    seen[v["type"]] += 1
    if seen[v["type"]] <= 5:
        print(" ", v["type"], "|", v["description"], "|", " / ".join(i["description"] for i in v["items"]))
PY
