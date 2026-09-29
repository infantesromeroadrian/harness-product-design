"""Uso: fixtures.py <repo> <home> [core|arca]

Completa una copia del repo y una raiz temporal para que el catalogo real sea
instalable en pruebas: crea las fuentes de harness-src que aun no existan (solo
componentes `active`) y, solo con el perfil `arca`, las fuentes externas de los
`link` en <home>. Con `core` <home> queda sin ~/.claude ni ~/.agents (Mac ajeno).
Nunca sobrescribe lo que ya existe.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def nested(keys: list[str]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for k in keys:
        cur = out
        parts = k.split(".")
        for part in parts[:-1]:
            cur = cur.setdefault(part, {})
        cur[parts[-1]] = {"fixture": True} if parts[0] == "mcpServers" else ["fixture"]
    return out


def agent_text(name: str, agent: dict[str, Any]) -> str:
    tools = "Read, Grep, Glob" if agent["role"] == "gate" else "Read, Write, Edit"
    lines = ["---", f"name: {name}", f"model: {agent['model']}", f"effort: {agent['effort']}", f"tools: {tools}", "---", "", "fixture", ""]
    return "\n".join(lines)


def main() -> int:
    repo, home = Path(sys.argv[1]), Path(sys.argv[2])
    profile = sys.argv[3] if len(sys.argv) > 3 else "core"
    cat = json.loads((repo / "catalog" / "catalog.json").read_text())
    for c in cat["components"]:
        dest = c["destination"]
        src = c.get("source")
        if src and c["activation"] == "active" and (profile == "arca" or c.get("profile", "core") == "core"):
            p = repo / src
            if not p.exists():
                p.parent.mkdir(parents=True, exist_ok=True)
                if dest["mode"] == "merge":
                    p.write_text(json.dumps(nested(dest["owned_keys"])) + "\n")
                elif dest["surface"] == "agents":
                    p.write_text(agent_text(Path(src).stem, c["agent"]))
                else:
                    p.write_text("#!/usr/bin/env bash\necho fixture\n")
        ext = c.get("external_source")
        if ext and profile == "arca":
            p = home / ext[2:]
            if not p.exists():
                p.parent.mkdir(parents=True, exist_ok=True)
                if c.get("expected_kind") == "dir":
                    p.mkdir()
                    (p / "SKILL.md").write_text("---\nname: fixture\n---\n")
                elif dest["surface"] == "agents":
                    p.write_text(agent_text(p.stem, c["agent"]))
                else:
                    p.write_text("#!/usr/bin/env bash\nexit 0\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
