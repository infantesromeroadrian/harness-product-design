#!/usr/bin/env bash
# PreToolUse(Write|Edit|MultiEdit): bloquea (exit 2) contenido con secretos evidentes.
# Señales: prefijos de token conocidos, claves privadas, JWT y valores largos (>= 32) de alta entropía
# asignados a una clave tipo secret/token/password/api_key. No bloquea tokens de diseño
# (`color.background.primary`), colores hex ni `var(--x)`. Los .env de ejemplo se omiten.
# Requiere python3 o jq; con entrada ilegible bloquea (ver lib-json.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-json.sh
source "$HERE/lib-json.sh"

INPUT=$(cat)
hook_require_json "$INPUT"
CONTENT=$(hook_field "$INPUT" 'content|new_string')
FILE=$(hook_field "$INPUT" 'file_path|path')
[[ -z "$CONTENT" ]] && exit 0

case "$(basename "${FILE:-x}")" in
  .env.example | .env.template | .env.sample) exit 0 ;;
esac

block() {
  echo "BLOQUEADO (detect-secrets): $1 en ${FILE:-el contenido}. Usa una variable de entorno o un placeholder." >&2
  exit 2
}

# 1. Señales inequívocas
grep -Eq 'AKIA[0-9A-Z]{16}' <<<"$CONTENT" && block "clave de acceso de AWS"
grep -Eq -- '-----BEGIN[[:space:]]+([A-Z]+[[:space:]]+)*PRIVATE[[:space:]]+KEY' <<<"$CONTENT" && block "clave privada"
grep -Eq 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}' <<<"$CONTENT" && block "JWT"

TOKENS='sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}'
TOKENS+='|xox[bp]-[A-Za-z0-9-]{10,}|xox[ars]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|ctx7sk-[A-Za-z0-9-]{20,}'
TOKENS+='|figd_[A-Za-z0-9_-]{30,}|glpat-[A-Za-z0-9_-]{20}'
grep -Eq "($TOKENS)" <<<"$CONTENT" && block "token de servicio conocido"

# 2. Asignación a una clave sensible de un valor largo y de alta entropía
ASSIGN='(api[_-]?key|secret|token|passw(or)?d)[A-Za-z0-9_]*["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{32,}["'\'']'
VALUE_RE='[:=][[:space:]]*["'\'']([^"'\'']+)["'\'']$'
DESIGN_PATH_RE='^[A-Za-z]+(\.[A-Za-z0-9-]+)+$'
IDENT_RE='^([A-Z][a-z]+|[a-z]+)+[0-9]*$'
FIGMA_ID_RE='^VariableID:[0-9]+:[0-9]+$'
HEX_RE='^#[0-9a-fA-F]{3,8}$'
while IFS= read -r line; do
  [[ $line =~ $VALUE_RE ]] || continue
  v="${BASH_REMATCH[1]}"
  ((${#v} >= 32)) || continue
  [[ $v =~ $DESIGN_PATH_RE || $v =~ $HEX_RE || $v =~ $IDENT_RE || $v =~ $FIGMA_ID_RE ]] && continue
  # shellcheck disable=SC2016
  [[ $v == var\(--* || $v == *'${'* || $v == '$'* || $v == *'<'* ]] && continue
  shopt -s nocasematch
  if [[ $v == *process.env* || $v == *placeholder* || $v == *example* || $v == your[_-]* || $v == *xxxx* ]]; then
    shopt -u nocasematch
    continue
  fi
  shopt -u nocasematch
  # Alta entropía: al menos 3 clases de carácter (minúscula, mayúscula, dígito, símbolo)
  classes=0
  [[ $v =~ [a-z] ]] && classes=$((classes + 1))
  [[ $v =~ [A-Z] ]] && classes=$((classes + 1))
  [[ $v =~ [0-9] ]] && classes=$((classes + 1))
  [[ $v =~ [^A-Za-z0-9] ]] && classes=$((classes + 1))
  ((classes >= 3)) && block "credencial literal asignada"
done < <(grep -Eio "$ASSIGN" <<<"$CONTENT")
exit 0
