#!/usr/bin/env bash
# PreToolUse(Bash): bloquea comandos destructivos evidentes. Exit 2 + stderr = bloqueo.
# Portable: sin dependencias de ~/.claude. Requiere python3 o jq (si no hay, no bloquea).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-json.sh
source "$HERE/lib-json.sh"

INPUT=$(cat)
CMD=$(hook_field "$INPUT" command)
[[ -z "$CMD" ]] && exit 0

split_segments() {
  local c="$1" nl=$'\n'
  c="${c//&&/$nl}"; c="${c//||/$nl}"; c="${c//;/$nl}"; c="${c//|/$nl}"
  printf '%s\n' "$c"
}

block() { echo "BLOQUEADO (block-dangerous): $1" >&2; exit 2; }

# rm recursivo sobre la raíz, el HOME o rutas críticas del sistema
RM_RE='(^|[;&|[:space:]])(sudo[[:space:]]+)?rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)[^;&|]*[[:space:]]'
# shellcheck disable=SC2016
RM_RE+='(/|/\*|~|~/|~/\*|\$HOME|\$\{HOME\}|/(etc|usr|var|bin|sbin|lib|opt|System|Library|Users|Applications))([[:space:]]|$|;|&|\|)'
grep -Eq "$RM_RE" <<<"$CMD" && block "rm recursivo sobre raíz, HOME o ruta del sistema"
grep -Eq 'rm[[:space:]].*--no-preserve-root' <<<"$CMD" && block "rm --no-preserve-root"

# Script remoto canalizado al shell
grep -Eq '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh)([[:space:]]|$)' <<<"$CMD" && block "script remoto canalizado al shell"

# Force push a main/master (se evalúa cada segmento por separado)
while IFS= read -r seg; do
  if grep -Eq '(^|[[:space:]])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)' <<<"$seg"; then
    if grep -Eq '(^|[[:space:]])(-f|--force|--force-with-lease[^[:space:]]*)([[:space:]]|$)' <<<"$seg" \
       && grep -Eq '(^|[[:space:]:/])(main|master)([[:space:]]|$)' <<<"$seg"; then
      block "force push a main/master"
    fi
    grep -Eq '[[:space:]]\+[^[:space:]]*(main|master)([[:space:]]|$)' <<<"$seg" && block "force push (+refspec) a main/master"
  fi
done < <(split_segments "$CMD")

# Operaciones git que pierden trabajo sin confirmar
grep -Eq 'git[[:space:]]+reset[[:space:]]+--hard' <<<"$CMD" && block "git reset --hard (puede perder trabajo sin commitear)"
grep -Eq 'git[[:space:]]+clean[[:space:]]+(-[a-zA-Z]*f|--force)' <<<"$CMD" && block "git clean forzado"

# Permisos y dispositivos
grep -Eq 'chmod[[:space:]]+(-R[[:space:]]+)?777[[:space:]]+(/|~)([[:space:]]|$)' <<<"$CMD" && block "chmod 777 sobre raíz o HOME"
grep -Eq '(mkfs(\.[a-z0-9]+)?[[:space:]]|dd[[:space:]].*of=/dev/)' <<<"$CMD" && block "escritura destructiva sobre dispositivo"

exit 0
