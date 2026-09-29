#!/usr/bin/env bash
# shellcheck disable=SC2015
# Roster (placeholder de R4/R5): valida rol/modelo/effort/tools de los agentes PRESENTES.
# Los componentes `planned` o cuya fuente no existe en esta maquina se omiten (p. ej. los
# enlaces de arca en un Mac sin ~/.claude). Politica: gate/architecture -> opus,
# implementation -> sonnet; los gate no llevan Write/Edit/NotebookEdit/Bash.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

if python3 - "$repo_root" <<'PY'
import json, os, re, sys
from pathlib import Path

repo = Path(sys.argv[1])
cat = json.loads((repo / "catalog" / "catalog.json").read_text())
WRITERS = {"Write", "Edit", "NotebookEdit", "Bash"}
POLICY = {"gate": "opus", "architecture": "opus", "implementation": "sonnet"}


def frontmatter(path):
    text = path.read_text()
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}
    out = {}
    for line in m.group(1).splitlines():
        if re.match(r"^[A-Za-z][\w-]*:", line):
            k, _, v = line.partition(":")
            out[k.strip()] = v.strip().strip('"')
    return out


def csv(v):
    return {x.strip() for x in v.split(",")} if v else set()


fails = []
checked = skipped = 0
for c in cat["components"]:
    cid, dest = c["capability_id"], c["destination"]
    if dest["surface"] == "agents":
        if c["activation"] != "active":
            print(f"SKIP  {cid} ({c['activation']})"); skipped += 1; continue
        origin = repo / c["source"] if "source" in c else Path(os.path.expanduser(c["external_source"]))
        if not origin.is_file():
            print(f"SKIP  {cid} (fuente ausente en esta maquina)"); skipped += 1; continue
        fm, a = frontmatter(origin), c["agent"]
        errs = []
        if fm.get("name") != origin.stem: errs.append(f"name={fm.get('name')!r} != {origin.stem!r}")
        if fm.get("model") != a["model"]: errs.append(f"model={fm.get('model')!r}, catalogo {a['model']!r}")
        if fm.get("effort") != a["effort"]: errs.append(f"effort={fm.get('effort')!r}, catalogo {a['effort']!r}")
        want = POLICY.get(a["role"])
        if want and a["model"] != want: errs.append(f"politica: rol {a['role']} exige modelo {want}")
        if a["role"] == "gate":
            forbidden = WRITERS - set(a.get("accepted_deviations", []))
            tools, denied = csv(fm.get("tools")), csv(fm.get("disallowedTools"))
            if "tools" in fm:
                bad = forbidden & tools
            else:  # hereda todas: hay que denegarlas explicitamente
                bad = forbidden - denied
            if bad: errs.append(f"validador con herramientas de escritura: {sorted(bad)}")
        checked += 1
        print(("FAIL  " if errs else "PASS  ") + f"{cid} [{a['role']}/{a['model']}/{a['effort']}]" + ("".join(f"\n        {e}" for e in errs)))
        fails += [f"{cid}: {e}" for e in errs]
    elif dest["surface"] == "skills" and dest["mode"] == "projection":
        origin = repo / c["source"] / "SKILL.md"
        if c["activation"] != "active" or not origin.is_file():
            print(f"SKIP  {cid} ({c['activation']})"); skipped += 1; continue
        fm = frontmatter(origin)
        errs = []
        if len(fm.get("description", "")) > 250: errs.append("description > 250 caracteres")
        if not fm.get("description"): errs.append("sin description")
        if cid == "skills.own.design-flow" and fm.get("disable-model-invocation") != "true":
            errs.append("design-flow debe llevar disable-model-invocation: true")
        checked += 1
        print(("FAIL  " if errs else "PASS  ") + cid + ("".join(f"\n        {e}" for e in errs)))
        fails += [f"{cid}: {e}" for e in errs]

print(f"\nroster: {checked} comprobados, {skipped} omitidos, {len(fails)} fallos")
sys.exit(1 if fails else 0)
PY
then ok "roster conforme a la politica"; else fail "roster no conforme"; fi

finish roster-smoke
