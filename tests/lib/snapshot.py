"""Uso: snapshot.py [--mtime] [--exclude REL ...] <ruta>...  -> huella JSON estable.

Registra tipo, modo, hash y destino de symlink de cada entrada, sin seguir enlaces.
Las rutas inexistentes se anotan como ausentes. `--mtime` incluye el mtime de ficheros.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
from pathlib import Path


def entry(p: Path, mtime: bool) -> dict[str, object]:
    st = p.lstat()
    if stat.S_ISLNK(st.st_mode):
        return {"k": "link", "to": os.readlink(p)}
    if stat.S_ISDIR(st.st_mode):
        return {"k": "dir", "m": stat.S_IMODE(st.st_mode)}
    d: dict[str, object] = {
        "k": "file",
        "m": stat.S_IMODE(st.st_mode),
        "sha": hashlib.sha256(p.read_bytes()).hexdigest(),
    }
    if mtime:
        d["mt"] = st.st_mtime_ns
    return d


def main() -> int:
    args = sys.argv[1:]
    mtime = "--mtime" in args
    excl: list[str] = []
    paths: list[str] = []
    it = iter([a for a in args if a != "--mtime"])
    for a in it:
        if a == "--exclude":
            excl.append(next(it))
        else:
            paths.append(a)
    snap: dict[str, object] = {}
    for raw in paths:
        base = Path(raw)
        if not (base.exists() or base.is_symlink()):
            snap[raw] = {"k": "absent"}
            continue
        walk = [base] + (sorted(base.rglob("*")) if base.is_dir() and not base.is_symlink() else [])
        for p in walk:
            if any(str(p).startswith(str(base / e)) for e in excl):
                continue
            snap[str(p)] = entry(p, mtime)
    print(json.dumps(snap, sort_keys=True, indent=0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
