#!/usr/bin/env python3
"""Runtime del harness de diseno: check (solo lectura) | --apply | --uninstall.

Contrato: cada componente del catalogo declara capability_id -> fuente ->
destino {surface, mode, path, owned_keys} -> activacion. Modos:
  projection  copia un fichero o directorio del repo al destino
  merge       fusiona las owned_keys de un JSON fuente en un JSON destino
  link        symlink al external_source (nunca se escribe a traves de el)

`~` en el catalogo se resuelve contra la raiz (--root / DESIGN_RUNTIME_ROOT /
HOME), lo que permite probar todo en un directorio temporal. Los prefijos
`~/.claude-product-design` y `~/.local/bin` pueden redirigirse con
--config-dir y --bin-dir.

Perfiles: `core` (por defecto) instala solo lo que vive en el repo y funciona en
cualquier Mac; `arca` anade los extras enlazados a instalaciones locales de ARCA
(~/.claude, ~/.agents). Un componente `arca` con `replaces` sustituye al de core.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Final

FORMAT: Final = "harness-product-design/runtime/v1"
DESIGN_DIRNAME: Final = ".claude-product-design"
CONFIG_PREFIX: Final = "~/.claude-product-design"
BIN_PREFIX: Final = "~/.local/bin"
PROFILES: Final = ("core", "arca")
ABSENT: Final = object()

Json = Any


class RuntimeFault(Exception):
    """Error de uso o de catalogo: aborta antes de tocar nada."""


@dataclass(frozen=True)
class Component:
    capability_id: str
    activation: str
    profile: str
    replaces: str | None
    mode: str
    dest: Path
    source: Path | None
    external_source: Path | None
    expected_kind: str | None
    file_mode: int | None
    owned_keys: tuple[str, ...]
    strategy: str
    append_sources: tuple[Path, ...]
    protected_paths_key: str | None


@dataclass
class Result:
    capability_id: str
    status: str  # ok | missing | drift | conflict | skipped
    reason: str = ""
    action: str = ""
    detail: list[str] = field(default_factory=list)

    def as_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {"capability_id": self.capability_id, "status": self.status}
        for key in ("reason", "action"):
            if getattr(self, key):
                out[key] = getattr(self, key)
        if self.detail:
            out["detail"] = self.detail
        return out


# ---------------------------------------------------------------- catalogo


@dataclass(frozen=True)
class Locations:
    root: Path
    config_dir: Path
    bin_dir: Path

    def expand(self, raw: str) -> Path:
        if not raw.startswith("~/"):
            raise RuntimeFault(f"ruta no admitida (debe empezar por ~/): {raw}")
        if ".." in Path(raw).parts:
            raise RuntimeFault(f"ruta con '..': {raw}")
        for prefix, base in ((CONFIG_PREFIX, self.config_dir), (BIN_PREFIX, self.bin_dir)):
            if raw == prefix or raw.startswith(prefix + "/"):
                return base / raw[len(prefix) :].lstrip("/")
        return self.root / raw[2:]


def load_components(repo: Path, loc: Locations) -> list[Component]:
    try:
        data = json.loads((repo / "catalog" / "catalog.json").read_text())
        items = data["components"]
    except (OSError, ValueError, KeyError) as exc:
        raise RuntimeFault(f"catalogo ilegible: {exc}") from exc
    out: list[Component] = []
    for item in items:
        try:
            dest_spec = item["destination"]
            mode = dest_spec["mode"]
            if mode not in ("projection", "merge", "link"):
                raise RuntimeFault(f"modo desconocido: {mode}")
            dest = loc.expand(dest_spec["path"])
            src = item.get("source")
            ext = item.get("external_source")
            fm = dest_spec.get("file_mode")
            out.append(
                Component(
                    capability_id=item["capability_id"],
                    activation=item["activation"],
                    profile=item.get("profile", "core"),
                    replaces=item.get("replaces"),
                    mode=mode,
                    dest=dest,
                    source=(repo / src) if src else None,
                    external_source=loc.expand(ext) if ext else None,
                    expected_kind=item.get("expected_kind"),
                    file_mode=int(fm, 8) if fm else None,
                    owned_keys=tuple(dest_spec.get("owned_keys", ())),
                    strategy=dest_spec.get("strategy", "replace"),
                    append_sources=tuple(repo / a for a in item.get("append_sources", ())),
                    protected_paths_key=dest_spec.get("protected_paths_key"),
                )
            )
        except KeyError as exc:
            raise RuntimeFault(f"componente incompleto (falta {exc}): {item.get('capability_id')}") from exc
    _check_shared_destinations(out)
    return out


def _check_shared_destinations(components: list[Component]) -> None:
    """Un destino solo puede compartirse entre capas merge, o entre un componente y el que lo sustituye."""
    groups: dict[Path, list[Component]] = {}
    for c in components:
        groups.setdefault(c.dest, []).append(c)
    for dest, group in groups.items():
        if len(group) == 1 or all(c.mode == "merge" for c in group):
            continue
        ids = {c.capability_id for c in group}
        if all(c.mode != "merge" for c in group) and all(
            c.replaces in ids for c in group[1:]
        ):
            continue
        raise RuntimeFault(f"destino duplicado: {dest}")


# ---------------------------------------------------------------- utilidades


def sha_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_digest(path: Path) -> str:
    """Digest de un fichero o arbol: contenido + bit ejecutable por fichero."""
    h = hashlib.sha256()
    if path.is_file():
        h.update(b"F" + sha_file(path).encode())
        return h.hexdigest()
    for p in sorted(path.rglob("*")):
        rel = p.relative_to(path).as_posix().encode()
        if p.is_symlink():
            h.update(b"L" + rel + os.readlink(p).encode())
        elif p.is_file():
            exe = b"x" if p.stat().st_mode & stat.S_IXUSR else b"-"
            h.update(b"F" + rel + exe + sha_file(p).encode())
        elif p.is_dir():
            h.update(b"D" + rel)
    return h.hexdigest()


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def make_dirs(path: Path) -> list[str]:
    """Crea `path` y devuelve las rutas absolutas que no existian."""
    missing: list[Path] = []
    cur = path
    while not cur.exists() and not cur.is_symlink():
        missing.append(cur)
        cur = cur.parent
    path.mkdir(parents=True, exist_ok=True)
    return [str(p) for p in reversed(missing)]


def dotted_get(obj: Json, key: str) -> Json:
    cur = obj
    for part in key.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return ABSENT
        cur = cur[part]
    return cur


def dotted_set(obj: dict[str, Any], key: str, value: Json) -> None:
    parts = key.split(".")
    cur = obj
    for part in parts[:-1]:
        nxt = cur.get(part)
        if not isinstance(nxt, dict):
            nxt = cur[part] = {}
        cur = nxt
    cur[parts[-1]] = value


def dotted_del(obj: dict[str, Any], key: str) -> None:
    parts = key.split(".")
    chain: list[dict[str, Any]] = [obj]
    for part in parts[:-1]:
        nxt = chain[-1].get(part)
        if not isinstance(nxt, dict):
            return
        chain.append(nxt)
    chain[-1].pop(parts[-1], None)
    for parent, part in zip(reversed(chain[:-1]), reversed(parts[:-1])):
        if parent.get(part) == {}:
            del parent[part]


def extend_value(base: Json, extra: Json) -> Json:
    """Capa `extend`: listas se concatenan sin duplicados, objetos se fusionan, el resto se sustituye."""
    if isinstance(base, list) and isinstance(extra, list):
        return base + [x for x in extra if x not in base]
    if isinstance(base, dict) and isinstance(extra, dict):
        out = dict(base)
        for k, v in extra.items():
            out[k] = extend_value(out[k], v) if k in out else v
        return out
    return extra


def rewrite_prefix(value: Json, cfg: Path) -> Json:
    """Reescribe $HOME/.claude-product-design (o ~/) al config_dir real en todas las cadenas."""
    if isinstance(value, str):
        for pre in ("$HOME/" + DESIGN_DIRNAME, "${HOME}/" + DESIGN_DIRNAME, "~/" + DESIGN_DIRNAME):
            if value == pre or value.startswith(pre + "/"):
                return str(cfg) + value[len(pre) :]
        return value
    if isinstance(value, list):
        return [rewrite_prefix(v, cfg) for v in value]
    if isinstance(value, dict):
        return {k: rewrite_prefix(v, cfg) for k, v in value.items()}
    return value


VAR_RE: Final = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def _subst(value: Json, name: str, replacement: str) -> Json:
    if isinstance(value, str):
        return value.replace("${" + name + "}", replacement)
    if isinstance(value, list):
        return [_subst(v, name, replacement) for v in value]
    return value


def prepare_source(src: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """Prepara un fuente para instalarlo; devuelve (fuente, servidores omitidos).

    En mcpServers: `optional` y `requires_env` no son campos de Claude Code y se eliminan.
    Un servidor `optional` se omite si alguna variable que exige (`requires_env`) o que
    referencia como ${VAR} en `args`/`env` no esta definida en el entorno del instalador.
    En `args` se sustituyen las variables de `requires_env` (rutas, no secretos); los
    valores de `env` se dejan como ${VAR}: nunca se escriben secretos en disco.
    """
    out = json.loads(json.dumps(src))
    omitted: list[str] = []
    servers = out.get("mcpServers")
    if isinstance(servers, dict):
        for name in list(servers):
            srv = servers[name]
            if not isinstance(srv, dict):
                continue
            optional = bool(srv.pop("optional", False))
            req = srv.pop("requires_env", None)
            required = [req] if isinstance(req, str) else list(req or [])
            referenced = set(VAR_RE.findall(json.dumps([srv.get("args", []), srv.get("env", {})])))
            needed = set(required) | (referenced if optional else set())
            missing = sorted(v for v in needed if not os.environ.get(v))
            if missing:
                del servers[name]
                omitted.append(f"skipped: missing env {','.join(missing)} (mcpServers.{name})")
                continue
            if isinstance(srv.get("args"), list):
                for var in required:
                    srv["args"] = _subst(srv["args"], var, os.environ[var])
    return out, omitted


def read_json_object(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("no es un objeto JSON")
    return data


# ---------------------------------------------------------------- check


class Runtime:
    def __init__(self, repo: Path, loc: Locations, profile: str) -> None:
        self.repo = repo
        self.root = loc.root
        self.cfg = loc.config_dir
        self.default_cfg = loc.root / DESIGN_DIRNAME
        self.bin_dir = loc.bin_dir
        self.allowed = (loc.config_dir, loc.bin_dir)
        self.check_locations(loc)
        self.profile = profile
        self._backed: dict[Path, str] = {}
        self._created: list[str] = []
        self._dirty = False
        self._detail: list[str] = []
        self.components = load_components(repo, loc)
        self.by_id = {c.capability_id: c for c in self.components}
        self.state_path = self.cfg / "backups" / "state.json"
        # Un componente arca disponible sustituye al de core que declara `replaces`.
        self.replaced_by: dict[str, str] = {
            c.replaces: c.capability_id for c in self.components if c.replaces and self._available(c)
        }

    @staticmethod
    def check_locations(loc: Locations) -> None:
        """Rechaza (antes de escribir nada) directorios de instalacion inseguros."""
        protected = [loc.root / d for d in (".claude", ".codex", ".agents")]
        for name, base in (("config_dir", loc.config_dir), ("bin_dir", loc.bin_dir)):
            real = base.resolve()
            for prot in protected:
                if real == prot.resolve() or real.is_relative_to(prot.resolve()):
                    raise RuntimeFault(f"{name} resuelve dentro de una ruta protegida ({prot.name}): {base}")
        p = loc.config_dir
        while True:
            if p.is_symlink():
                raise RuntimeFault(f"config_dir o un directorio padre es un symlink: {p}")
            if p == loc.root or not p.is_relative_to(loc.root):
                break
            p = p.parent

    def _selected(self, c: Component) -> bool:
        return c.profile == "core" or self.profile == "arca"

    def _available(self, c: Component) -> bool:
        if c.activation != "active" or not self._selected(c):
            return False
        origin = c.external_source if c.mode == "link" else c.source
        return origin is not None and origin.exists()

    # -- estado por componente (solo lectura)

    def _dest_confined(self, dest: Path) -> bool:
        for base in self.allowed:
            if dest.is_relative_to(base):
                cur = dest.parent
                while cur != base:  # ningun directorio intermedio puede ser un symlink
                    if cur.is_symlink():
                        return False
                    cur = cur.parent
                return True
        return False

    def evaluate(self, c: Component) -> Result:
        r = Result(c.capability_id, "ok")
        if c.activation == "disabled":
            return Result(c.capability_id, "skipped", "disabled")
        if not self._selected(c):
            return Result(c.capability_id, "skipped", "profile_not_selected")
        if c.capability_id in self.replaced_by:
            return Result(c.capability_id, "skipped", f"replaced_by:{self.replaced_by[c.capability_id]}")
        if c.activation == "planned":
            present = c.source is not None and c.source.exists()
            return Result(c.capability_id, "skipped", "planned_source_present" if present else "planned")
        if not self._dest_confined(c.dest):
            return Result(c.capability_id, "conflict", "destination_escapes_root")
        handler = {"projection": self._eval_projection, "merge": self._eval_merge, "link": self._eval_link}[c.mode]
        handler(c, r)
        return r

    def _projection_bytes(self, c: Component) -> bytes | None:
        """Contenido construido si el destino se compone de varias fuentes (fichero unico)."""
        if not c.append_sources:
            return None
        assert c.source is not None
        parts = [c.source, *c.append_sources]
        missing = [p for p in parts if not p.is_file()]
        if missing:
            raise FileNotFoundError(missing[0])
        head = [p.read_bytes().rstrip(b"\n") for p in parts[:-1]]
        return b"\n\n".join([*head, parts[-1].read_bytes()])

    def _eval_projection(self, c: Component, r: Result) -> None:
        assert c.source is not None
        if not c.source.exists() or any(not a.exists() for a in c.append_sources):
            r.status, r.reason = "conflict", "source_missing"
            return
        if c.dest.is_symlink():
            r.status, r.reason = "conflict", "destination_is_symlink"
            return
        if not c.dest.exists():
            r.status = "missing"
            return
        built = self._projection_bytes(c)
        if c.source.is_dir() != c.dest.is_dir():
            r.status, r.reason = "conflict", "kind_mismatch"
            return
        if built is not None:
            if built != c.dest.read_bytes():
                r.status, r.reason = "drift", "content_differs"
        elif tree_digest(c.source) != tree_digest(c.dest):
            r.status, r.reason = "drift", "content_differs"
        elif c.file_mode is not None and c.dest.is_file() and stat.S_IMODE(c.dest.stat().st_mode) != c.file_mode:
            r.status, r.reason = "drift", "file_mode_differs"

    def _merge_layers(self, dest: Path) -> list[Component]:
        return [c for c in self.components if c.mode == "merge" and c.dest == dest and self._available(c)]

    def _merge_expected(self, dest: Path) -> tuple[dict[str, Json], list[str]]:
        """Valor esperado por clave tras aplicar en orden las capas (core, luego arca)."""
        expected: dict[str, Json] = {}
        omitted: list[str] = []
        for layer in self._merge_layers(dest):
            assert layer.source is not None
            src, skipped = prepare_source(read_json_object(layer.source))
            if self.cfg != self.default_cfg:
                src = rewrite_prefix(src, self.cfg)
            omitted += skipped
            for k in layer.owned_keys:
                v = dotted_get(src, k)
                if v is ABSENT:
                    continue  # omitido por requires_env, o clave derivada
                expected[k] = extend_value(expected[k], v) if layer.strategy == "extend" and k in expected else v
            if layer.protected_paths_key:
                expected[layer.protected_paths_key] = self._protected_paths(dotted_get(src, "permissions.deny"))
        return expected, omitted

    def _protected_paths(self, deny: Json) -> str:
        """Lista `a:b:c` para DESIGN_PROTECTED_PATHS, derivada de las reglas Edit/Write del propio fuente."""
        paths: list[str] = []
        for rule in deny if isinstance(deny, list) else []:
            m = re.fullmatch(r"(?:Edit|Write|MultiEdit)\((.+?)/\*\*\)", str(rule))
            if m:
                path = m.group(1)
                path = str(self.root / path[2:]) if path.startswith("~/") else path
                if path not in paths:
                    paths.append(path)
        return ":".join(paths)

    def _eval_merge(self, c: Component, r: Result) -> None:
        assert c.source is not None
        try:
            raw = read_json_object(c.source)
            expected, omitted = self._merge_expected(c.dest)
            r.detail += omitted
        except (OSError, ValueError) as exc:
            r.status, r.reason, r.detail = "conflict", "source_unreadable", [str(exc)]
            return
        absent_in_src = [k for k in c.owned_keys if k != c.protected_paths_key and dotted_get(raw, k) is ABSENT]
        if absent_in_src:
            r.status, r.reason, r.detail = "conflict", "source_missing_owned_keys", absent_in_src
            return
        keys = [k for k in c.owned_keys if k in expected]
        if not keys:
            return  # todo omitido por requires_env: nada que instalar
        if c.dest.is_symlink():
            r.status, r.reason = "conflict", "destination_is_symlink"
            return
        if not c.dest.exists():
            r.status = "missing"
            return
        try:
            dst = read_json_object(c.dest)
        except (OSError, ValueError):
            r.status, r.reason = "conflict", "destination_not_json_object"
            return
        bad = [k for k in keys if dotted_get(dst, k) != expected[k]]
        if bad:
            all_absent = all(dotted_get(dst, k) is ABSENT for k in keys)
            r.status, r.reason, r.detail = ("missing" if all_absent else "drift"), "owned_keys", bad

    def _eval_link(self, c: Component, r: Result) -> None:
        assert c.external_source is not None
        ext = c.external_source
        if not ext.exists():
            r.status, r.reason = "conflict", "external_source_missing"
            return
        if (c.expected_kind == "dir") != ext.is_dir():
            r.status, r.reason = "conflict", "external_source_kind_mismatch"
            return
        if c.dest.is_symlink():
            if Path(os.readlink(c.dest)) != ext:
                r.status, r.reason = "drift", "link_target_differs"
        elif c.dest.exists():
            r.status, r.reason = "conflict", "destination_not_a_symlink"
        else:
            r.status = "missing"

    def check(self) -> list[Result]:
        return [self.evaluate(c) for c in self.components]

    # -- estado persistente

    def load_state(self) -> dict[str, Any]:
        if not self.state_path.exists():
            return {"entries": {}, "created_dirs": [], "merges": {}}
        try:
            data = json.loads(self.state_path.read_text())
        except ValueError as exc:
            raise RuntimeFault(f"state.json corrupto: {exc}") from exc
        data.setdefault("entries", {})
        data.setdefault("created_dirs", [])
        data.setdefault("merges", {})
        return data

    def save_state(self, state: dict[str, Any], created: list[str]) -> None:
        for rel in created:
            if rel not in state["created_dirs"]:
                state["created_dirs"].append(rel)
        new = make_dirs(self.state_path.parent)
        for rel in new:
            if rel not in state["created_dirs"]:
                state["created_dirs"].append(rel)
        atomic_write(self.state_path, (json.dumps(state, indent=2, sort_keys=True) + "\n").encode(), 0o600)

    # -- apply

    def apply(self) -> tuple[list[Result], int]:
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup_dir = self.cfg / "backups" / f"runtime-{ts}"
        n = 1
        while backup_dir.exists():
            n += 1
            backup_dir = self.cfg / "backups" / f"runtime-{ts}-{n}"
        state = self.load_state()
        self._created = []
        self._dirty = False
        results: list[Result] = []
        changes = 0
        failure: OSError | None = None
        try:
            for c in self.components:
                if c.capability_id in self.replaced_by.values():
                    self._dirty |= self._take_over(c, state)
            for c in self.components:
                r = self._apply_one(c, state, backup_dir)
                results.append(r)
                changes += int(r.action in ("created", "updated", "adopted"))
                if self._dirty:  # el estado se persiste tras cada componente
                    self.save_state(state, self._created)
                    self._dirty = False
        except OSError as exc:
            failure = exc
        finally:
            if self._dirty:
                self.save_state(state, self._created)
        if failure is not None:
            raise RuntimeFault(
                f"apply interrumpido ({type(failure).__name__}: {failure}); lo escrito hasta ahora queda registrado: usa --uninstall para revertirlo"
            ) from failure
        return results, changes

    def _apply_one(self, c: Component, state: dict[str, Any], backup_dir: Path) -> Result:
        r = self.evaluate(c)
        first_owner = c.capability_id not in state["entries"]
        if r.status in ("skipped", "conflict"):
            r.action = "refused" if r.status == "conflict" else "skipped"
            return r
        if r.status == "ok":
            if first_owner and c.mode == "merge":
                state["entries"][c.capability_id] = self._origin(c, backup_dir, state)
                self._record_installed(c, state)
            elif first_owner:
                state["entries"][c.capability_id] = {"origin": "preexisting"}
            else:
                r.action = "unchanged"
                return r
            self._dirty = True
            r.action = "adopted"
            return r
        if first_owner:
            entry = self._origin(c, backup_dir, state)
        else:
            entry = state["entries"][c.capability_id]
            if r.status == "drift":
                self._backup(c, backup_dir)
        state["entries"][c.capability_id] = entry  # antes de escribir: un fallo a mitad sigue siendo revertible
        self._dirty = True
        self._write(c, entry, state)
        r.action = "created" if r.status == "missing" else "updated"
        return r

    def _record_installed(self, c: Component, state: dict[str, Any]) -> None:
        expected, _ = self._merge_expected(c.dest)
        m = state["merges"][str(c.dest)]
        for k in c.owned_keys:
            if k in expected:
                m.setdefault("installed", {})[k] = {"value": expected[k]}

    def _take_over(self, c: Component, state: dict[str, Any]) -> bool:
        """El componente `c` sustituye a uno de core ya instalado: hereda su origen."""
        old = self.by_id.get(c.replaces or "")
        if old is None or old.capability_id not in state["entries"] or c.capability_id in state["entries"]:
            return False
        if old.dest == c.dest and old.mode == "projection" and old.source is not None and c.dest.exists() and not c.dest.is_symlink():
            if tree_digest(old.source) != tree_digest(c.dest):
                return False  # modificado por el usuario: se reporta como conflicto
            shutil.rmtree(c.dest) if c.dest.is_dir() else c.dest.unlink()
        state["entries"][c.capability_id] = state["entries"].pop(old.capability_id)
        return True

    def _origin(self, c: Component, backup_dir: Path, state: dict[str, Any]) -> dict[str, Any]:
        """Registra que habia en el destino antes de que el catalogo lo posea."""
        if c.mode == "merge":
            # El origen se guarda por fichero y clave: las capas core/arca comparten claves.
            m = state["merges"].setdefault(str(c.dest), {"file_existed": c.dest.exists(), "orig": {}})
            dst = read_json_object(c.dest) if c.dest.exists() else {}
            for k in c.owned_keys:
                if k not in m["orig"]:
                    v = dotted_get(dst, k)
                    m["orig"][k] = {"present": v is not ABSENT, "value": None if v is ABSENT else v}
            if m["file_existed"] and c.dest.exists():
                rel = self._backup(c, backup_dir)
                m.setdefault("backup", rel)
            return {"origin": "merge"}
        if c.dest.is_symlink() or c.dest.exists():
            rel = self._backup(c, backup_dir)
            return {"origin": "backup", "backup": rel}
        return {"origin": "absent"}

    def _backup_rel(self, dest: Path) -> Path:
        for tag, base in (("config", self.cfg), ("bin", self.bin_dir), ("root", self.root)):
            if dest.is_relative_to(base):
                return Path(tag) / dest.relative_to(base)
        raise RuntimeFault(f"destino fuera de las raices permitidas: {dest}")

    def _backup(self, c: Component, backup_dir: Path) -> str:
        if c.dest in self._backed:  # un solo backup por destino y ejecucion
            return self._backed[c.dest]
        self._backed[c.dest] = rel = self._do_backup(c, backup_dir)
        return rel

    def _do_backup(self, c: Component, backup_dir: Path) -> str:
        target = backup_dir / self._backup_rel(c.dest)
        target.parent.mkdir(parents=True, exist_ok=True)
        if c.dest.is_symlink():
            target.with_name(target.name + ".symlink").write_text(os.readlink(c.dest))
            return target.with_name(target.name + ".symlink").relative_to(self.cfg).as_posix()
        if c.dest.is_dir():
            shutil.copytree(c.dest, target, symlinks=True)
        else:
            shutil.copy2(c.dest, target)
        return target.relative_to(self.cfg).as_posix()

    def _write(self, c: Component, entry: dict[str, Any], state: dict[str, Any]) -> None:
        self._created += make_dirs(c.dest.parent)
        if c.mode == "link":
            assert c.external_source is not None
            if c.dest.is_symlink():
                c.dest.unlink()
            c.dest.symlink_to(c.external_source)
            entry.pop("sha", None)
        elif c.mode == "projection":
            assert c.source is not None
            if c.dest.exists():
                shutil.rmtree(c.dest) if c.dest.is_dir() else c.dest.unlink()
            if c.source.is_dir():
                shutil.copytree(c.source, c.dest, symlinks=True)
                if c.file_mode is not None:
                    os.chmod(c.dest, c.file_mode)
            else:
                mode = c.file_mode if c.file_mode is not None else 0o644
                built = self._projection_bytes(c)
                atomic_write(c.dest, built if built is not None else c.source.read_bytes(), mode)
        else:
            assert c.source is not None
            expected, _ = self._merge_expected(c.dest)
            dst = read_json_object(c.dest) if c.dest.exists() else {}
            for k in c.owned_keys:
                if k in expected:
                    dotted_set(dst, k, expected[k])
            mode = stat.S_IMODE(c.dest.stat().st_mode) if c.dest.exists() else 0o600
            atomic_write(c.dest, (json.dumps(dst, indent=2, ensure_ascii=False) + "\n").encode(), mode)
            self._record_installed(c, state)
        if c.mode == "projection":
            entry["sha"] = tree_digest(c.dest)  # lo instalado, no lo que diga la fuente mas adelante

    # -- uninstall

    def uninstall(self) -> tuple[list[Result], int]:
        state = self.load_state()
        changes = 0
        results: list[Result] = []
        for c in self.components:
            ent = state["entries"].get(c.capability_id)
            r = Result(c.capability_id, "skipped", "not_installed")
            results.append(r)
            if ent is None or c.activation == "disabled":
                continue
            if ent.get("origin") == "preexisting":
                r.reason = "preexisting_kept"
                continue
            self._detail = []
            changed, why = self._remove(c, ent, state)
            r.detail = list(self._detail)
            r.status, r.reason = ("ok" if changed else "skipped"), why
            r.action = "removed" if changed else "kept"
            changes += int(changed)
            if why in ("removed", "restored", "already_absent", "not_written"):
                del state["entries"][c.capability_id]
        self._finalize_merges(state)
        self._finish_uninstall(state)
        return results, changes

    def _remove(self, c: Component, ent: dict[str, Any], state: dict[str, Any]) -> tuple[bool, str]:
        if c.mode == "merge":
            return self._remove_merge(c, state)
        if c.mode == "projection" and "sha" not in ent:
            # el apply se corto antes de terminar esta escritura: no hay nada instalado que retirar
            if ent.get("origin") == "backup" and not (c.dest.exists() or c.dest.is_symlink()):
                self._restore(c, self.cfg / ent["backup"])
            return False, "not_written"
        if c.mode == "link":
            if c.dest.is_symlink():
                if Path(os.readlink(c.dest)) != c.external_source:
                    return False, "kept_modified"
                c.dest.unlink()
            elif c.dest.exists():
                return False, "kept_modified"
        else:
            if c.dest.is_symlink():
                return False, "kept_modified"
            if c.dest.exists():
                installed = ent.get("sha")
                if tree_digest(c.dest) != installed:  # se compara con lo instalado, no con la fuente actual
                    return False, "kept_modified"
                shutil.rmtree(c.dest) if c.dest.is_dir() else c.dest.unlink()
        if ent.get("origin") == "backup":
            self._restore(c, self.cfg / ent["backup"])
            return True, "restored"
        return True, "removed"

    def _restore(self, c: Component, backup: Path) -> None:
        c.dest.parent.mkdir(parents=True, exist_ok=True)
        if backup.name.endswith(".symlink"):
            c.dest.symlink_to(backup.read_text())
        elif backup.is_dir():
            shutil.copytree(backup, c.dest, symlinks=True)
        else:
            shutil.copy2(backup, c.dest)

    def _remove_merge(self, c: Component, state: dict[str, Any]) -> tuple[bool, str]:
        if not c.dest.exists():
            return False, "already_absent"
        try:
            dst = read_json_object(c.dest)
        except (OSError, ValueError):
            return False, "kept_unreadable"
        m = state["merges"].get(str(c.dest), {})
        orig, installed = m.get("orig", {}), m.get("installed", {})
        kept: list[str] = []
        removed = False
        for k in c.owned_keys:
            cur = dotted_get(dst, k)
            o = orig.get(k)
            orig_val = o["value"] if o and o["present"] else ABSENT
            if k not in installed or cur == orig_val:
                continue  # nunca instalada, o ya devuelta a su valor original por otra capa
            if cur != installed[k]["value"]:
                kept.append(k)  # el usuario la ha cambiado: se conserva
                continue
            dotted_del(dst, k)
            if orig_val is not ABSENT:
                dotted_set(dst, k, orig_val)
            removed = True
        if kept:
            self._uninstall_backup(c.dest)
            self._detail = [f"kept (modified by user): {k}" for k in kept]
        if removed:
            atomic_write(c.dest, (json.dumps(dst, indent=2, ensure_ascii=False) + "\n").encode(), stat.S_IMODE(c.dest.stat().st_mode))
        return removed, ("kept_modified" if kept else "removed")

    def _uninstall_backup(self, dest: Path) -> None:
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        target = self.cfg / "backups" / f"uninstall-{ts}" / self._backup_rel(dest)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(dest, target)

    def _finalize_merges(self, state: dict[str, Any]) -> None:
        """Cuando ya no queda ninguna capa instalada de un fichero, lo borra si lo creamos y quedo vacio."""
        live = {c.dest for c in self.components if c.mode == "merge" and c.capability_id in state["entries"]}
        for dest_str, m in list(state["merges"].items()):
            if Path(dest_str) in live:
                continue
            dest = Path(dest_str)
            saved = self.cfg / m["backup"] if m.get("backup") else None
            if saved is not None and saved.is_file() and dest.is_file():
                try:
                    if read_json_object(dest) == read_json_object(saved):
                        atomic_write(dest, saved.read_bytes(), stat.S_IMODE(dest.stat().st_mode))  # bytes originales
                except (OSError, ValueError):
                    pass
            if not m["file_existed"] and dest.is_file():
                try:
                    empty = read_json_object(dest) == {}
                except (OSError, ValueError):
                    empty = False
                if empty:
                    dest.unlink()
            del state["merges"][dest_str]

    def _finish_uninstall(self, state: dict[str, Any]) -> None:
        dirs = list(state["created_dirs"])
        for ent in state["entries"].values():
            dirs += ent.get("created_dirs", [])
        if state["entries"]:
            if self.state_path.exists():
                atomic_write(self.state_path, (json.dumps(state, indent=2, sort_keys=True) + "\n").encode(), 0o600)
            return
        self.state_path.unlink(missing_ok=True)
        for rel in sorted(set(dirs), key=lambda s: -s.count("/")):
            path = Path(rel)
            if path.is_dir() and not path.is_symlink() and not any(path.iterdir()):
                path.rmdir()


# ---------------------------------------------------------------- CLI


def emit(mode: str, root: Path, results: list[Result], changes: int, exit_code: int, profile: str) -> None:
    counts: dict[str, int] = {}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1
    print(
        json.dumps(
            {
                "format": FORMAT,
                "mode": mode,
                "profile": profile,
                "root": str(root),
                "valid": exit_code == 0,
                "changes": changes,
                "summary": counts,
                "entries": [r.as_json() for r in results],
            },
            indent=2,
        )
    )


def coherent(results: list[Result], tolerate_missing_external: bool = False) -> bool:
    """Todo ok/skipped. En apply se tolera un link cuya fuente externa no existe (se omite)."""
    return all(
        r.status in ("ok", "skipped")
        or (tolerate_missing_external and r.status == "conflict" and r.reason == "external_source_missing")
        for r in results
    )


def main(argv: list[str] | None = None) -> int:
    env = os.environ.get
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    grp = p.add_mutually_exclusive_group()
    grp.add_argument("--apply", action="store_true", help="escribe los destinos del catalogo (con backup)")
    grp.add_argument("--uninstall", action="store_true", help="retira solo lo que posee el catalogo")
    p.add_argument("--profile", choices=PROFILES, default=env("DESIGN_PROFILE", "core"), help="core (por defecto) | arca (core + extras enlazados)")
    p.add_argument("--root", default=env("DESIGN_RUNTIME_ROOT"), help="sustituye a ~ (por defecto $HOME)")
    p.add_argument("--config-dir", default=env("DESIGN_CONFIG_DIR"), help="sustituye a ~/.claude-product-design")
    p.add_argument("--bin-dir", default=env("DESIGN_BIN_DIR"), help="sustituye a ~/.local/bin")
    p.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent), help="raiz del repo con catalog/ y harness-src/")
    args = p.parse_args(argv)

    mode = "apply" if args.apply else "uninstall" if args.uninstall else "check"
    try:
        root = Path(args.root) if args.root else Path.home()
        if not root.is_dir():
            raise RuntimeFault(f"raiz inexistente: {root}")
        root = root.resolve()
        loc = Locations(
            root=root,
            config_dir=Path(args.config_dir).expanduser().resolve() if args.config_dir else root / ".claude-product-design",
            bin_dir=Path(args.bin_dir).expanduser().resolve() if args.bin_dir else root / ".local" / "bin",
        )
        rt = Runtime(Path(args.repo), loc, args.profile)
        if args.apply:
            applied, changes = rt.apply()
            results = rt.check()  # estado final, tras escribir
            actions = {a.capability_id: a.action for a in applied}
            for r in results:
                r.action = actions.get(r.capability_id, "")
            code = 0 if coherent(results, tolerate_missing_external=True) else 1
        elif args.uninstall:
            results, changes = rt.uninstall()
            code = 1 if any(r.reason.startswith("kept") for r in results) else 0
        else:
            results, changes = rt.check(), 0
            code = 0 if coherent(results) else 1
    except (RuntimeFault, OSError) as exc:
        print(json.dumps({"format": FORMAT, "mode": mode, "valid": False, "error": f"{type(exc).__name__}: {exc}" if isinstance(exc, OSError) else str(exc)}))
        return 2
    emit(mode, root, results, changes, code, args.profile)
    return code


if __name__ == "__main__":
    sys.exit(main())
