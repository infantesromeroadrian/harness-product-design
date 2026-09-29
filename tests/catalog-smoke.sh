#!/usr/bin/env bash
# shellcheck disable=SC2015
# Catalogo: valido contra el esquema, fuentes presentes (o planned), sin duplicados.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
setup_tmp

catalog="$repo_root/catalog/catalog.json"
schema="$repo_root/schemas/catalog.schema.json"

check "catalog.json es JSON valido" python3 -m json.tool "$catalog"
check "catalog.schema.json es JSON valido" python3 -m json.tool "$schema"

if out=$(python3 "$lib_dir/validate_catalog.py" "$schema" "$catalog" 2>&1); then ok "catalogo valida contra el esquema ($(tail -1 <<<"$out"))"; else fail "catalogo no valida: $out"; fi

# Casos negativos: el esquema debe rechazar contratos rotos.
mutate() { # mutate <descripcion> <expresion-python-sobre-c>
  local desc=$1 expr=$2
  python3 - "$catalog" "$tmp_base/neg.json" "$expr" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = d["components"]
exec(sys.argv[3])
json.dump(d, open(sys.argv[2], "w"))
PY
  if python3 "$lib_dir/validate_catalog.py" "$schema" "$tmp_base/neg.json" >/dev/null 2>&1; then fail "esquema acepta: $desc"; else ok "esquema rechaza: $desc"; fi
}
mutate "link sin expected_kind" 'next(x for x in c if x["destination"]["mode"]=="link")["destination"].get("x"); del next(x for x in c if x["destination"]["mode"]=="link")["expected_kind"]'
mutate "link con source" 'next(x for x in c if x["destination"]["mode"]=="link")["source"]="harness-src/x"'
mutate "merge sin owned_keys" 'del next(x for x in c if x["destination"]["mode"]=="merge")["destination"]["owned_keys"]'
mutate "projection con owned_keys" 'next(x for x in c if x["destination"]["mode"]=="projection")["destination"]["owned_keys"]=["a"]'
mutate "agente sin role/model/effort" 'del next(x for x in c if x["destination"]["surface"]=="agents")["agent"]'
mutate "link en perfil core" 'next(x for x in c if x["destination"]["mode"]=="link")["profile"]="core"'
mutate "perfil desconocido" 'c[0]["profile"]="pro"'
mutate "activation desconocida" 'c[0]["activation"]="enabled"'
mutate "destino fuera de ~/" 'c[0]["destination"]["path"]="/etc/passwd"'
mutate "ruta con .." 'c[0]["destination"]["path"]="~/../x"'

# Coherencia semantica del catalogo real.
python3 - "$repo_root" <<'PY' && ok "fuentes, duplicados y planned coherentes" || fail "coherencia semantica (ver arriba)"
import json, os, sys
from pathlib import Path
repo = Path(sys.argv[1])
cat = json.loads((repo / "catalog" / "catalog.json").read_text())
errs, notes = [], []
ids, dests = set(), set()
by_id = {c["capability_id"]: c for c in cat["components"]}
home_claude = Path.home() / ".claude"
for c in cat["components"]:
    cid, d = c["capability_id"], c["destination"]
    if cid in ids: errs.append(f"capability_id duplicado: {cid}")
    ids.add(cid)
    prof = c.get("profile", "core")
    if prof == "core" and (c.get("external_source") or "/Users/" in json.dumps(c)):
        errs.append(f"{cid}: core no puede depender de fuentes externas ni rutas absolutas")
    rep = c.get("replaces")
    if rep:
        tgt = by_id.get(rep)
        if tgt is None: errs.append(f"{cid}: replaces desconocido {rep}")
        elif tgt["destination"]["path"] != d["path"]: errs.append(f"{cid}: replaces {rep} con otro destino")
        elif tgt.get("profile", "core") != "core" or prof != "arca": errs.append(f"{cid}: replaces solo arca -> core")
    elif d["path"] in dests and not (d["mode"] == "merge" and c["activation"] != "disabled" and all(o["destination"]["mode"] == "merge" for o in cat["components"] if o["destination"]["path"] == d["path"])):
        errs.append(f"destino duplicado: {d['path']}")
    dests.add(d["path"])
    src = c.get("source")
    if src:
        exists = (repo / src).exists()
        if c["activation"] == "active" and not exists:
            errs.append(f"{cid}: fuente activa inexistente {src}")
        if c["activation"] == "planned" and exists:
            notes.append(f"{cid}: planned pero la fuente ya existe (activar cuando proceda)")
    for a in c.get("append_sources", []):
        if not (repo / a).exists(): errs.append(f"{cid}: append_source inexistente {a}")
    ext = c.get("external_source")
    if ext and c["activation"] == "active" and (Path(os.path.expanduser(ext)).parent.is_dir() or home_claude.is_dir()):
        p = Path(os.path.expanduser(ext))
        if not p.exists(): errs.append(f"{cid}: external_source inexistente {ext}")
        elif (c["expected_kind"] == "dir") != p.is_dir(): errs.append(f"{cid}: expected_kind no coincide con {ext}")
        elif p.is_symlink(): errs.append(f"{cid}: external_source es un symlink (resolver al destino real): {ext}")
    if d["mode"] == "projection" and d.get("file_mode") and d["surface"] not in ("bin", "hooks"):
        errs.append(f"{cid}: file_mode solo en bin/hooks")
for n in notes: print("  nota:", n)
for e in errs: print("  error:", e)
print(f"perfiles: core={sum(c.get('profile','core')=='core' for c in cat['components'])}, arca={sum(c.get('profile')=='arca' for c in cat['components'])}")
print(f"componentes: {len(cat['components'])} (active={sum(c['activation']=='active' for c in cat['components'])}, planned={sum(c['activation']=='planned' for c in cat['components'])})")
sys.exit(1 if errs else 0)
PY

finish catalog-smoke
