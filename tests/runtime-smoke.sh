#!/usr/bin/env bash
# shellcheck disable=SC2015
# Runtime: check -> apply -> apply idempotente -> check ok -> uninstall, siempre en una raiz temporal.
#   A  perfil core en un HOME sin ~/.claude (Mac ajeno): sin enlaces, sin obsidian/context7 si faltan envs
#   A2 perfil core con variables de entorno definidas (sin secretos en disco)
#   B  perfil arca con fuentes externas simuladas, sobre un estado previo (backups y restauracion)
#   B2 perfil arca con fuentes externas ausentes (check las reporta, apply las omite)
#   C  conflicto: un fichero real donde iria un symlink (no se sobrescribe)
#   D  core -> arca (los componentes que sustituyen heredan el origen) y uninstall limpio
#   E  --config-dir / --bin-dir personalizados
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
setup_tmp

snap() { python3 "$lib_dir/snapshot.py" "$@"; }
rc=0
# run <base> <args...>: guarda la salida JSON en <base>/out.json y el exit en $rc
run() {
  local base=$1; shift
  rc=0
  env -u DESIGN_VAULT -u CONTEXT7_API_KEY -u DESIGN_RUNTIME_ROOT -u DESIGN_PROFILE \
    "$repo_root/tooling/design-runtime.sh" --repo "$base/repo" --root "$base/home" "$@" >"$base/out.json" || rc=$?
}
count_links() { find "$1" -type l | wc -l | tr -d ' '; }
mode_of() { python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$1"; }
# Tras uninstall solo debe quedar el directorio de backups (se conserva a proposito): se retira para comparar.
drop_backups() { rm -r "$1/.claude-product-design/backups" 2>/dev/null || true; rmdir "$1/.claude-product-design" 2>/dev/null || true; }

# --- huella del mundo real: nada fuera de la raiz temporal puede cambiar
real_paths=("$HOME/.claude-product-design" "$HOME/.local/bin/claude-design" "$HOME/.claude/CLAUDE.md" "$HOME/.claude/identity.md" "$HOME/.claude/settings.json" "$HOME/.claude/agents" "$HOME/.claude/hooks" "$HOME/.claude/rules" "$HOME/.claude/commands" "$HOME/.codex/AGENTS.md" "$HOME/.codex/config.toml")
snap --mtime "${real_paths[@]}" >"$tmp_base/real-before.json"
snap --mtime "$repo_root/catalog" "$repo_root/schemas" "$repo_root/tooling" >"$tmp_base/repo-before.json"

# ============================================================== A: core en un Mac limpio
echo "== A: perfil core, HOME sin ~/.claude"
A="$tmp_base/A"; make_fixture "$A" core
h="$A/home"
check "A: el HOME simulado no tiene ~/.claude ni ~/.agents" test ! -e "$h/.claude" -a ! -e "$h/.agents"
snap "$h" >"$A/s0.json"
snap --mtime "$h" >"$A/s0m.json"
run "$A"
[[ $rc -eq 1 ]] && ok "A: check sin instalar -> exit 1" || fail "A: check sin instalar deberia dar exit 1 (rc=$rc)"
check "A: check no reporta conflictos (ningun enlace externo exigido)" test "$(jget "$A/out.json" 'd["summary"].get("conflict",0)')" = 0
snap --mtime "$h" >"$A/s0m2.json"
check "A: check no escribe nada (HOME byte a byte igual, mtimes incluidos)" cmp -s "$A/s0m.json" "$A/s0m2.json"
rc=0; DESIGN_RUNTIME_ROOT="$h" "$repo_root/tooling/design-runtime.sh" --repo "$A/repo" >"$A/env.json" || rc=$?
check "A: DESIGN_RUNTIME_ROOT equivale a --root" test "$(jget "$A/env.json" 'd["root"]')" = "$(cd "$h" && pwd -P)"

run "$A" --apply
[[ $rc -eq 0 ]] && ok "A: apply -> exit 0" || { fail "A: apply rc=$rc"; head -40 "$A/out.json"; }
check "A: apply hizo cambios" test "$(jget "$A/out.json" 'd["changes"]')" -gt 0
check "A: sin ~/.claude ni ~/.agents tras apply" test ! -e "$h/.claude" -a ! -e "$h/.agents"
check "A: ningun symlink en el perfil core" test "$(count_links "$h")" = 0
check "A: CLAUDE.md == CLAUDE.core.md" cmp -s "$A/repo/harness-src/guidance/CLAUDE.core.md" "$h/.claude-product-design/CLAUDE.md"
check "A: claude-design es ejecutable (0755)" test "$(mode_of "$h/.local/bin/claude-design")" = 0o755
for hk in block-dangerous guard-protected-paths detect-secrets lib-json; do
  check "A: hook $hk proyectado (0755)" test "$(mode_of "$h/.claude-product-design/hooks/$hk.sh")" = 0o755
done
check "A: settings.json con env, deny y hooks" python3 -c '
import json,sys; d=json.load(open(sys.argv[1]))
assert d["env"]["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"]=="3" and d["permissions"]["deny"] and d["hooks"]["PreToolUse"]
assert "DESIGN_PROTECTED_PATHS" not in d["env"]' "$h/.claude-product-design/settings.json"
check "A: .claude.json solo con figma y playwright (sin obsidian/context7, sin _doc/optional)" python3 -c '
import json,sys; d=json.load(open(sys.argv[1])); raw=open(sys.argv[1]).read()
assert sorted(d["mcpServers"])==["figma","playwright"], d["mcpServers"].keys()
assert "_doc" not in d and "optional" not in raw and "requires_env" not in raw' "$h/.claude-product-design/.claude.json"
check "A: reporta 'skipped: missing env' para obsidian y context7" python3 -c '
import json,sys; t=open(sys.argv[1]).read()
assert "skipped: missing env DESIGN_VAULT (mcpServers.obsidian)" in t and "skipped: missing env CONTEXT7_API_KEY (mcpServers.context7)" in t' "$A/out.json"
run "$A"
[[ $rc -eq 0 ]] && ok "A: check tras apply -> exit 0 (todo coherente)" || { fail "A: check rc=$rc"; head -60 "$A/out.json"; }
snap --mtime "$h" >"$A/s1.json"
run "$A" --apply
check "A: 2.a ejecucion de apply -> 0 cambios" test "$(jget "$A/out.json" 'd["changes"]')" = 0
snap --mtime "$h" >"$A/s2.json"
check "A: 2.a ejecucion no toca ni el mtime de ningun fichero" cmp -s "$A/s1.json" "$A/s2.json"
# deriva: se modifica un fichero proyectado
echo "# manual" >>"$h/.claude-product-design/CLAUDE.md"
run "$A"
check "A: drift detectado en CLAUDE.md (exit 1)" test "$rc" = 1 -a "$(jget "$A/out.json" '[e["status"] for e in d["entries"] if e["capability_id"]=="guidance.claude-md"][0]')" = drift
run "$A" --apply
check "A: apply repara el drift" cmp -s "$A/repo/harness-src/guidance/CLAUDE.core.md" "$h/.claude-product-design/CLAUDE.md"
check "A: y guarda backup del fichero sobrescrito" bash -c "ls '$h'/.claude-product-design/backups/runtime-*/config/CLAUDE.md"
run "$A" --uninstall
[[ $rc -eq 0 ]] && ok "A: uninstall -> exit 0" || fail "A: uninstall rc=$rc"
drop_backups "$h"
snap "$h" >"$A/s3.json"
same_snapshot "A: uninstall deja el HOME como estaba" "$A/s0.json" "$A/s3.json"

# ============================================================== A2: core con envs definidas
echo "== A2: perfil core con DESIGN_VAULT y CONTEXT7_API_KEY"
A2="$tmp_base/A2"; make_fixture "$A2" core; h2="$A2/home"; snap "$h2" >"$A2/s0.json"
canary="canary-$$-not-a-secret"
rt_a2() { env DESIGN_VAULT=/vault/demo "CONTEXT7_API_KEY=$canary" "$repo_root/tooling/design-runtime.sh" --repo "$A2/repo" --root "$h2" "$@"; }
rc=0; rt_a2 --apply >"$A2/out.json" || rc=$?
[[ $rc -eq 0 ]] && ok "A2: apply -> exit 0" || fail "A2: apply rc=$rc"
check "A2: obsidian con la ruta sustituida y context7 instalado" python3 -c '
import json,sys; d=json.load(open(sys.argv[1]))["mcpServers"]
assert d["obsidian"]["args"][-1]=="/vault/demo" and "context7" in d' "$h2/.claude-product-design/.claude.json"
check "A2: el valor de la clave NO se escribe en disco (queda el placeholder)" bash -c "! grep -rq '$canary' '$h2' && grep -q 'CONTEXT7_API_KEY}' '$h2/.claude-product-design/.claude.json'"
rc=0; rt_a2 >"$A2/out.json" || rc=$?
[[ $rc -eq 0 ]] && ok "A2: check ok con las envs definidas" || fail "A2: check rc=$rc"
run "$A2" --uninstall
drop_backups "$h2"
snap "$h2" >"$A2/s3.json"
same_snapshot "A2: uninstall deja el HOME como estaba" "$A2/s0.json" "$A2/s3.json"

# ============================================================== B: arca con externas simuladas
echo "== B: perfil arca (fuentes externas simuladas)"
B="$tmp_base/B"; make_fixture "$B" arca; hb="$B/home"
mkdir -p "$hb/.claude-product-design/hooks" "$hb/.local/bin"
printf '{"model":"x","env":{"FOO":"1"},"permissions":{"deny":["Bash(rm:*)"]}}\n' >"$hb/.claude-product-design/settings.json"
printf '{"projects":{"a":1},"mcpServers":{"other":{"command":"x"}}}\n' >"$hb/.claude-product-design/.claude.json"
printf '# mio\n' >"$hb/.claude-product-design/CLAUDE.md"
printf '#!/bin/sh\necho previo\n' >"$hb/.local/bin/claude-design"
ln -s /nonexistent/elsewhere "$hb/.claude-product-design/hooks/panel-summary.sh"
snap "$hb" >"$B/s0.json"
run "$B" --profile arca
[[ $rc -eq 1 ]] && ok "B: check sobre estado previo -> exit 1" || fail "B: check rc=$rc"
run "$B" --profile arca --apply
[[ $rc -eq 0 ]] && ok "B: apply -> exit 0" || { fail "B: apply rc=$rc"; head -80 "$B/out.json"; }
check "B: hay backups de lo sobrescrito" bash -c "ls '$hb'/.claude-product-design/backups/runtime-*/config/CLAUDE.md '$hb'/.claude-product-design/backups/runtime-*/bin/claude-design"
check "B: los link apuntan a fuentes reales (existen y viven en la raiz simulada)" python3 - "$hb" <<'PY'
import os, sys
from pathlib import Path
home = Path(sys.argv[1]).resolve()
links = [p for p in (home / ".claude-product-design").rglob("*") if p.is_symlink()]
assert len(links) == 18, len(links)
for p in links:
    t = Path(os.readlink(p))
    assert t.exists() and t.is_relative_to(home), (p, t)
    assert (home / ".claude") in t.parents or (home / ".agents") in t.parents, (p, t)
PY
check "B: block-dangerous ahora es el enlace de arca (sustituye al de core)" test -L "$hb/.claude-product-design/hooks/block-dangerous.sh"
check "B: CLAUDE.md = arca + linea en blanco + core" python3 - "$B/repo/harness-src/guidance" "$hb/.claude-product-design/CLAUDE.md" <<'PY'
import sys
from pathlib import Path
g = Path(sys.argv[1]); got = Path(sys.argv[2]).read_text()
a = (g / "CLAUDE.arca.md").read_text().rstrip("\n"); c = (g / "CLAUDE.core.md").read_text()
assert got == a + "\n\n" + c
PY
check "B: settings.json: conserva model/FOO, une deny y hooks de core+arca, DESIGN_PROTECTED_PATHS derivado" python3 - "$hb" <<'PY'
import json, sys
from pathlib import Path
home = Path(sys.argv[1]).resolve()
d = json.load(open(home / ".claude-product-design/settings.json"))
assert d["model"] == "x" and d["env"]["FOO"] == "1"
deny = d["permissions"]["deny"]
assert "Bash(rm:*)" not in deny and any("~/.claude/" in x for x in deny) and any("harness-kimi" in x for x in deny)
assert len(deny) == len(set(deny))
assert "SessionStart" in d["hooks"] and len(d["hooks"]["PreToolUse"]) >= 3
paths = d["env"]["DESIGN_PROTECTED_PATHS"].split(":")
assert paths and all(p.startswith(str(home)) for p in paths) and any(p.endswith("harness-kimi") for p in paths), paths
PY
check "B: .claude.json conserva projects/other y trae engram + obsidian (arca)" python3 - "$hb" <<'PY'
import json, sys
d = json.load(open(sys.argv[1] + "/.claude-product-design/.claude.json"))
s = d["mcpServers"]
assert d["projects"] == {"a": 1} and "other" in s and "engram" in s and "figma" in s
assert "air-vault" in json.dumps(s["obsidian"]) and "optional" not in json.dumps(s)
PY
run "$B" --profile arca
[[ $rc -eq 0 ]] && ok "B: check tras apply -> exit 0" || { fail "B: check rc=$rc"; head -60 "$B/out.json"; }
run "$B" --profile arca --apply
check "B: 2.a ejecucion de apply -> 0 cambios" test "$(jget "$B/out.json" 'd["changes"]')" = 0
run "$B" --profile arca --uninstall
[[ $rc -eq 0 ]] && ok "B: uninstall -> exit 0" || fail "B: uninstall rc=$rc"
snap "$hb" >"$B/s3.json"
python3 - "$B/s0.json" "$B/s3.json" "$hb" <<'PY' && ok "B: uninstall restaura el estado previo (salvo backups/)" || fail "B: el estado previo no se restauro (diferencias arriba)"
import json, os, sys
a, b, home = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
b = {k: v for k, v in b.items() if not k.startswith(home + "/.claude-product-design/backups")}
diff = sorted(set(a) ^ set(b)) + [k for k in a if k in b and a[k] != b[k]]
for k in diff:
    print("  diff:", k)
sys.exit(1 if diff else 0)
PY

# ============================================================== B2: arca sin externas
echo "== B2: perfil arca con fuentes externas ausentes"
B2="$tmp_base/B2"; make_fixture "$B2" core; h3="$B2/home"; snap "$h3" >"$B2/s0.json"
run "$B2" --profile arca
check "B2: check reporta external_source_missing (exit 1)" test "$rc" = 1 -a "$(jget "$B2/out.json" 'sum(1 for e in d["entries"] if e.get("reason")=="external_source_missing")')" -ge 18
run "$B2" --profile arca --apply
[[ $rc -eq 0 ]] && ok "B2: apply omite los enlaces ausentes sin fallar (exit 0)" || { fail "B2: apply rc=$rc"; head -50 "$B2/out.json"; }
check "B2: ningun symlink creado" test "$(count_links "$h3")" = 0
run "$B2" --profile arca --uninstall
drop_backups "$h3"
snap "$h3" >"$B2/s3.json"
same_snapshot "B2: uninstall deja el HOME como estaba" "$B2/s0.json" "$B2/s3.json"

# ============================================================== C: conflicto
echo "== C: fichero real donde iria un symlink"
C="$tmp_base/C"; make_fixture "$C" arca; hc="$C/home"
mkdir -p "$hc/.claude-product-design/hooks"; printf 'no me toques\n' >"$hc/.claude-product-design/hooks/panel-summary.sh"
run "$C" --profile arca --apply
[[ $rc -eq 1 ]] && ok "C: apply con conflicto -> exit 1" || fail "C: apply rc=$rc"
check "C: el fichero real no se sobrescribe" grep -q 'no me toques' "$hc/.claude-product-design/hooks/panel-summary.sh"
check "C: el resto se instala" test -L "$hc/.claude-product-design/hooks/prompt_injection_check.sh"
run "$C" --profile arca --uninstall
check "C: uninstall no toca el fichero ajeno" grep -q 'no me toques' "$hc/.claude-product-design/hooks/panel-summary.sh"

# ============================================================== D: core -> arca
echo "== D: core y despues arca (sustitucion y herencia de origen)"
D="$tmp_base/D"; make_fixture "$D" arca; hd="$D/home"; snap "$hd" >"$D/s0.json"
run "$D" --apply
[[ $rc -eq 0 ]] && ok "D: apply core -> exit 0" || fail "D: core rc=$rc"
check "D: block-dangerous es fichero (core)" test -f "$hd/.claude-product-design/hooks/block-dangerous.sh" -a ! -L "$hd/.claude-product-design/hooks/block-dangerous.sh"
run "$D" --profile arca --apply
[[ $rc -eq 0 ]] && ok "D: apply arca encima -> exit 0" || { fail "D: arca rc=$rc"; head -60 "$D/out.json"; }
check "D: block-dangerous pasa a enlace" test -L "$hd/.claude-product-design/hooks/block-dangerous.sh"
run "$D" --profile arca
[[ $rc -eq 0 ]] && ok "D: check arca ok" || fail "D: check arca rc=$rc"
run "$D" --uninstall
drop_backups "$hd"
snap "$hd" >"$D/s3.json"
same_snapshot "D: uninstall deja el HOME como estaba" "$D/s0.json" "$D/s3.json"

# ============================================================== E: rutas personalizadas
echo "== E: --config-dir y --bin-dir"
E="$tmp_base/E"; make_fixture "$E" core; he="$E/home"; snap "$he" >"$E/s0.json"
mkdir -p "$E/custom"
rt_e() { "$repo_root/tooling/design-runtime.sh" --repo "$E/repo" --root "$he" --config-dir "$E/custom/cfg" --bin-dir "$E/custom/bin" "$@"; }
rc=0; rt_e --apply >"$E/out.json" || rc=$?
[[ $rc -eq 0 ]] && ok "E: apply -> exit 0" || { fail "E: apply rc=$rc"; head -40 "$E/out.json"; }
check "E: se instala en los directorios pedidos" test -f "$E/custom/cfg/CLAUDE.md" -a -x "$E/custom/bin/claude-design"
check "E: nada en el HOME simulado" test ! -e "$he/.claude-product-design" -a ! -e "$he/.local"
rc=0; rt_e >"$E/out.json" || rc=$?
[[ $rc -eq 0 ]] && ok "E: check ok" || fail "E: check rc=$rc"
check "E: los hooks de settings.json apuntan al config-dir real (no a \$HOME/.claude-product-design)" python3 - "$E/custom/cfg" <<'PY'
import json, os, sys
cfg = os.path.realpath(sys.argv[1])
raw = open(cfg + "/settings.json").read()
d = json.loads(raw)
cmds = [h["command"] for grp in d["hooks"]["PreToolUse"] for h in grp["hooks"]]
assert cmds and all(c.startswith(cfg + "/hooks/") for c in cmds), cmds
assert "$HOME/.claude-product-design" not in raw
PY
rt_e --uninstall >/dev/null
rm -r "$E/custom/cfg/backups" 2>/dev/null || true
rmdir "$E/custom/cfg" "$E/custom/bin" 2>/dev/null || true
check "E: uninstall deja custom/ vacio" test -z "$(ls -A "$E/custom")"

# ============================================================== F: directorios de instalacion inseguros
echo "== F: config_dir symlink / dentro de ~/.claude simulado"
F="$tmp_base/F"; make_fixture "$F" core; hf="$F/home"
mkdir -p "$hf/.claude/agents"; printf 'x\n' >"$hf/.claude/agents/a.md"
ln -s "$hf/.claude" "$hf/.claude-product-design"
snap "$hf" >"$F/s0.json"
run "$F" --apply
check "F: config_dir symlink a ~/.claude -> rechazo (exit 2, error JSON)" test "$rc" = 2 -a "$(jget "$F/out.json" '("symlink" in d["error"]) or ("protegida" in d["error"])')" = True
snap "$hf" >"$F/s1.json"
same_snapshot "F: no se escribio nada" "$F/s0.json" "$F/s1.json"
rc=0; "$repo_root/tooling/design-runtime.sh" --repo "$F/repo" --root "$hf" --config-dir "$hf/.claude/sub" --apply >"$F/out.json" || rc=$?
check "F: --config-dir dentro de ~/.claude -> rechazo (exit 2)" test "$rc" = 2 -a "$(jget "$F/out.json" '"protegida" in d["error"]')" = True
snap "$hf" >"$F/s2.json"
same_snapshot "F: tampoco se escribio nada" "$F/s0.json" "$F/s2.json"

# ============================================================== G: apply interrumpido por un error de escritura
echo "== G: bin_dir sin permiso de escritura"
G="$tmp_base/G"; make_fixture "$G" core; hg="$G/home"
mkdir -p "$hg/.claude-product-design" "$G/ro"
printf '# previo del usuario\n' >"$hg/.claude-product-design/CLAUDE.md"
chmod 0555 "$G/ro"
snap "$hg" >"$G/s0.json"
rt_g() { env -u DESIGN_VAULT -u CONTEXT7_API_KEY "$repo_root/tooling/design-runtime.sh" --repo "$G/repo" --root "$hg" --bin-dir "$G/ro" "$@"; }
rc=0; rt_g --apply >"$G/out.json" 2>"$G/err.txt" || rc=$?
check "G: apply falla con JSON de error y exit 2 (sin traceback)" test "$rc" = 2 -a ! -s "$G/err.txt" -a "$(jget "$G/out.json" '"PermissionError" in d["error"]')" = True
check "G: lo escrito antes del fallo esta registrado (state.json)" test -f "$hg/.claude-product-design/backups/state.json"
chmod 0755 "$G/ro"
rc=0; rt_g --uninstall >"$G/out.json" || rc=$?
check "G: uninstall posterior -> exit 0" test "$rc" = 0
check "G: restaura el CLAUDE.md previo del usuario" grep -q 'previo del usuario' "$hg/.claude-product-design/CLAUDE.md"
snap "$hg" >"$G/s3.json"
python3 - "$G/s0.json" "$G/s3.json" "$hg" <<'PY' && ok "G: el HOME queda como antes (salvo backups/)" || fail "G: HOME distinto tras uninstall"
import json, os, sys
a, b, home = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), os.path.normpath(sys.argv[3])
b = {k: v for k, v in b.items() if not k.startswith(home + "/.claude-product-design/backups")}
diff = sorted(set(a) ^ set(b)) + [k for k in a if k in b and a[k] != b[k]]
for k in diff:
    print("  diff:", k)
sys.exit(1 if diff else 0)
PY

# ============================================================== H: uninstall respeta lo modificado por el usuario
echo "== H: modificaciones del usuario tras apply"
H="$tmp_base/H"; make_fixture "$H" core; hh="$H/home"
run "$H" --apply
printf '# nota del usuario\n' >>"$hh/.claude-product-design/CLAUDE.md"
python3 - "$hh/.claude-product-design/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["permissions"]["deny"].append("Bash(mine:*)"); d["otra"] = 1
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
run "$H" --uninstall
check "H: uninstall con algo conservado -> exit 1" test "$rc" = 1
check "H: CLAUDE.md modificado se conserva (comparado con lo instalado)" grep -q 'nota del usuario' "$hh/.claude-product-design/CLAUDE.md"
check "H: la clave permissions.deny modificada se conserva y se reporta" python3 - "$H/out.json" "$hh/.claude-product-design/settings.json" <<'PY'
import json, sys
out = json.load(open(sys.argv[1])); d = json.load(open(sys.argv[2]))
assert "Bash(mine:*)" in d["permissions"]["deny"] and d["otra"] == 1 and "hooks" not in d
e = [x for x in out["entries"] if x["capability_id"] == "config.settings"][0]
assert e["reason"] == "kept_modified" and any("permissions.deny" in t for t in e["detail"]), e
PY
check "H: hay backup previo del settings.json conservado" bash -c "ls '$hh'/.claude-product-design/backups/uninstall-*/config/settings.json"
check "H: lo intacto (claude-design) si se retiro" test ! -e "$hh/.local/bin/claude-design"

# ============================================================== I: copia parcial de una skill
echo "== I: copia de directorio interrumpida a mitad"
I="$tmp_base/I"; make_fixture "$I" core; hi="$I/home"
mkdir -p "$I/repo/harness-src/skills/wcag-audit"
printf 'a\n' >"$I/repo/harness-src/skills/wcag-audit/SKILL.md"
printf 'b\n' >"$I/repo/harness-src/skills/wcag-audit/zz-sin-permiso.md"
chmod 000 "$I/repo/harness-src/skills/wcag-audit/zz-sin-permiso.md"
snap "$hi" >"$I/s0.json"
run "$I" --apply
check "I: apply falla con JSON de error y exit 2" test "$rc" = 2 -a "$(jget "$I/out.json" '"error" in d')" = True
check "I: quedo un directorio parcial de la skill" test -d "$hi/.claude-product-design/skills/wcag-audit"
run "$I" --uninstall
check "I: uninstall -> exit 0 y reporta removed_partial" test "$rc" = 0 -a "$(jget "$I/out.json" 'sum(1 for e in d["entries"] if e.get("reason")=="removed_partial")')" = 1
chmod 644 "$I/repo/harness-src/skills/wcag-audit/zz-sin-permiso.md"
drop_backups "$hi"
snap "$hi" >"$I/s3.json"
same_snapshot "I: uninstall deja el HOME como estaba" "$I/s0.json" "$I/s3.json"

# ============================================================== nada fuera de la raiz temporal
snap --mtime "${real_paths[@]}" >"$tmp_base/real-after.json"
snap --mtime "$repo_root/catalog" "$repo_root/schemas" "$repo_root/tooling" >"$tmp_base/repo-after.json"
check "el HOME real (~/.claude-product-design, ~/.local/bin/claude-design, ~/.claude, ~/.codex) no cambio" cmp -s "$tmp_base/real-before.json" "$tmp_base/real-after.json"
check "el repo (catalog, schemas, tooling) no cambio" cmp -s "$tmp_base/repo-before.json" "$tmp_base/repo-after.json"

finish runtime-smoke
