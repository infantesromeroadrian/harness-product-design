#!/usr/bin/env bash
# Utilidad compartida por los hooks: lee campos de tool_input del JSON recibido por stdin.
#
#   INPUT=$(cat)
#   hook_require_json "$INPUT"                 # exit 2 si hay entrada que no se puede leer
#   valor=$(hook_field "$INPUT" 'command')     # varias claves alternativas: 'content|new_string'
#
# Prueba python3 y, si falla o no existe, jq. Si hay entrada pero ninguno puede analizarla, el hook
# bloquea (exit 2): con permisos ampliados, dejar pasar sin poder leer sería fallar abierto.

_hook_have() { command -v "$1" >/dev/null 2>&1; }

# Devuelve 0 si el JSON se analiza con python3 o jq.
_hook_parses() {
  local json="$1"
  if _hook_have python3 && printf '%s' "$json" | python3 -c 'import sys, json; json.load(sys.stdin)' >/dev/null 2>&1; then
    return 0
  fi
  if _hook_have jq && printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

hook_require_json() {
  local json="$1"
  [[ -z "${json//[[:space:]]/}" ]] && return 0
  if ! _hook_parses "$json"; then
    echo "BLOQUEADO: el hook no pudo leer la entrada JSON (falta python3/jq o el JSON no es válido). Instala python3 o jq." >&2
    exit 2
  fi
  return 0
}

# Imprime el primer campo no vacío de tool_input entre las claves dadas. Devuelve 1 si no pudo analizar.
hook_field() {
  local json="$1" key="$2" out
  if _hook_have python3; then
    if out=$(printf '%s' "$json" | python3 -c '
import sys, json
d = json.load(sys.stdin).get("tool_input", {})
if not isinstance(d, dict):
    d = {}
for k in sys.argv[1].split("|"):
    v = d.get(k)
    if isinstance(v, str) and v:
        sys.stdout.write(v)
        break
' "$key" 2>/dev/null); then
      printf '%s' "$out"
      return 0
    fi
  fi
  if _hook_have jq; then
    local filter='.tool_input | (' k first=1
    local -a ks
    IFS='|' read -ra ks <<<"$key"
    for k in "${ks[@]}"; do
      [[ $first -eq 0 ]] && filter+=' // '
      filter+=".${k}"
      first=0
    done
    filter+=') // empty'
    if out=$(printf '%s' "$json" | jq -r "$filter" 2>/dev/null); then
      printf '%s' "$out"
      return 0
    fi
  fi
  return 1
}
