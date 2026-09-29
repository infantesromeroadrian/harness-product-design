#!/usr/bin/env bash
# PreToolUse(Bash): exit 2 si el comando escribe, borra o mueve dentro de rutas protegidas:
# ~/.claude, ~/.codex, ~/.agents/skills y las de DESIGN_PROTECTED_PATHS (lista separada por ':',
# p. ej. las de permissions.deny).
#
# Cómo decide: divide el comando en segmentos (&&, ||, ;, |, saltos de línea, subshells), rastrea el
# directorio actual a través de `cd`/`pushd`/`popd` y, por cada verbo, resuelve sus DESTINOS de escritura
# (rm/mv/touch/...: todos los argumentos; cp/ln/install/rsync: el destino; tee, `>` y `>>`: su fichero;
# sed -i, dd of=, git mutante y find -delete/-exec en un directorio protegido). Leer desde una ruta
# protegida (cat, cp origen) no bloquea.
#
# Limitaciones (heurística textual, no un sandbox): no resuelve enlaces simbólicos ni variables distintas
# de HOME; un cd dentro de un subshell se trata como persistente (conservador); `bash -c`, `eval` y
# `xargs` se revisan de forma aproximada. Requiere python3 o jq (con entrada ilegible, bloquea).
set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-json.sh
source "$HERE/lib-json.sh"

INPUT=$(cat)
hook_require_json "$INPUT"
CMD=$(hook_field "$INPUT" command)
[[ -z "$CMD" ]] && exit 0

PROTECTED=("$HOME/.claude" "$HOME/.codex" "$HOME/.agents/skills")
if [[ -n "${DESIGN_PROTECTED_PATHS:-}" ]]; then
  IFS=':' read -ra EXTRA <<<"$DESIGN_PROTECTED_PATHS"
  for p in "${EXTRA[@]}"; do
    [[ -n "$p" ]] && PROTECTED+=("${p/#\~/$HOME}")
  done
fi

deny() {
  echo "BLOQUEADO (guard-protected-paths): $1 (ruta protegida: $2)" >&2
  exit 2
}

# Normaliza . y .. en una ruta absoluta sin tocar el disco
canon() {
  local p="$1" res="" seg
  local -a parts
  IFS='/' read -ra parts <<<"$p"
  for seg in "${parts[@]}"; do
    case "$seg" in
      '' | .) ;;
      ..) res="${res%/*}" ;;
      *) res="$res/$seg" ;;
    esac
  done
  printf '%s' "${res:-/}"
}

# resolve <token> <cwd> -> ruta absoluta canónica (expande ~ y $HOME iniciales)
resolve() {
  local tok="$1" cwd="$2"
  tok="${tok/#\$\{HOME\}/$HOME}"
  tok="${tok/#\$HOME/$HOME}"
  # shellcheck disable=SC2088
  if [[ $tok == "~" || $tok == "~/"* ]]; then tok="$HOME${tok#\~}"; fi
  [[ $tok == /* ]] || tok="$cwd/$tok"
  canon "$tok"
}

# in_protected <abs> [ancestor]: dentro de una ruta protegida (o, con "ancestor", contenedora de una)
in_protected() {
  local a="$1" mode="${2:-}" p
  for p in "${PROTECTED[@]}"; do
    if [[ $a == "$p" || $a == "$p"/* ]]; then
      HIT="$p"
      return 0
    fi
    if [[ $mode == ancestor && ( $a == / || $p == "$a"/* ) ]]; then
      HIT="$p"
      return 0
    fi
  done
  return 1
}

# check_targets <cwd> <verbo> <ancestor|""> <token>...
check_targets() {
  local cwd="$1" verb="$2" mode="$3" tok abs
  shift 3
  for tok in "$@"; do
    abs=$(resolve "$tok" "$cwd")
    if in_protected "$abs" "$mode"; then deny "'$verb' escribe o borra en $abs" "$HIT"; fi
  done
}

# Divide en segmentos: && || ; | \n ( ) ` $(  y & suelto
split_segments() {
  local c="$1" nl=$'\n'
  c="${c//&&/$nl}"
  c="${c//||/$nl}"
  c="${c//;/$nl}"
  c="${c//|/$nl}"
  c="${c//\$(/$nl}"
  c="${c//\`/$nl}"
  c="${c//(/$nl}"
  c="${c//)/$nl}"
  c="${c// & /$nl}"
  printf '%s\n' "$c"
}

INITIAL_CWD="$PWD"
CWD="$INITIAL_CWD"
REDIR_RE='>>?[[:space:]]*([^[:space:]<>]+)'
MUT_ANY='(^|[[:space:]])(rm|rmdir|mv|cp|ln|tee|touch|mkdir|chmod|chown|truncate|dd|rsync|unlink|shred|install)[[:space:]]|sed[[:space:]]+-[a-zA-Z]*i|>>?[[:space:]]*[^[:space:]&]'
GIT_MUT=' checkout reset restore clean stash rebase merge pull commit add rm mv apply cherry-pick revert switch am '

while IFS= read -r seg; do
  seg="${seg//\"/}"
  seg="${seg//\'/}"
  read -ra w <<<"$seg"
  n=${#w[@]}
  ((n == 0)) && continue

  # Redirecciones: solo el fichero de destino importa
  rest="$seg"
  while [[ $rest =~ $REDIR_RE ]]; do
    t="${BASH_REMATCH[1]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    [[ $t == \&* ]] && continue
    check_targets "$CWD" "redirección" "" "$t"
  done

  # Verbo: salta envolventes y asignaciones de entorno
  i=0
  while ((i < n)); do
    case "${w[i]}" in
      sudo | command | env | nohup | time | exec | builtin | '{' | '}' | '!' | then | do | else | if | while) i=$((i + 1)) ;;
      [A-Za-z_]*=*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  ((i >= n)) && continue
  verb="${w[i]##*/}"
  args=("${w[@]:$((i + 1))}")

  # Argumentos que no son opciones, y valor de -t/--target-directory
  nonopt=()
  tdir=""
  prev=""
  for a in "${args[@]}"; do
    if [[ $prev == -t ]]; then
      tdir="$a"
      prev=""
      continue
    fi
    case "$a" in
      --target-directory=*) tdir="${a#*=}" ;;
      -t) prev="-t" ;;
      -*) ;;
      *) nonopt+=("$a") ;;
    esac
  done

  case "$verb" in
    cd | pushd)
      if ((${#nonopt[@]} == 0)); then
        CWD="$HOME"
      elif [[ ${nonopt[0]} != - ]]; then
        CWD=$(resolve "${nonopt[0]}" "$CWD")
      fi
      continue
      ;;
    popd)
      CWD="$INITIAL_CWD"
      continue
      ;;
    rm | rmdir | unlink | shred | mv)
      ((${#nonopt[@]})) && check_targets "$CWD" "$verb" ancestor "${nonopt[@]}"
      [[ -n $tdir ]] && check_targets "$CWD" "$verb" "" "$tdir"
      ;;
    touch | mkdir | truncate | chmod | chown | chgrp | tee)
      ((${#nonopt[@]})) && check_targets "$CWD" "$verb" "" "${nonopt[@]}"
      ;;
    cp | ln | install | rsync)
      if [[ -n $tdir ]]; then
        check_targets "$CWD" "$verb" "" "$tdir"
      elif ((${#nonopt[@]})); then
        check_targets "$CWD" "$verb" "" "${nonopt[${#nonopt[@]} - 1]}"
      fi
      ;;
    sed | perl)
      if printf '%s\n' "${args[@]}" | grep -Eq '^(-[a-zA-Z]*i|--in-place)'; then
        ((${#nonopt[@]})) && check_targets "$CWD" "$verb -i" "" "${nonopt[@]}"
      fi
      ;;
    dd)
      for a in "${args[@]}"; do
        [[ $a == of=* ]] && check_targets "$CWD" "dd" "" "${a#of=}"
      done
      ;;
    git)
      gdir="$CWD"
      sub=""
      j=0
      while ((j < ${#args[@]})); do
        case "${args[j]}" in
          -C) gdir=$(resolve "${args[j + 1]:-.}" "$CWD"); j=$((j + 1)) ;;
          -c) j=$((j + 1)) ;;
          -*) ;;
          *) sub="${args[j]}"; break ;;
        esac
        j=$((j + 1))
      done
      if [[ -n $sub && $GIT_MUT == *" $sub "* ]] && in_protected "$gdir"; then
        deny "git $sub modifica el árbol de trabajo" "$HIT"
      fi
      ;;
    find)
      if printf '%s\n' "${args[@]}" | grep -Eq '^-(delete|exec|execdir|ok|okdir)$'; then
        paths=()
        for a in "${args[@]}"; do
          [[ $a == -* || $a == '!' ]] && break
          paths+=("$a")
        done
        ((${#paths[@]})) && check_targets "$CWD" "find -delete/-exec" "" "${paths[@]}"
      fi
      ;;
    bash | sh | zsh | eval | xargs | source | .)
      # Aproximación: si el segmento menciona una ruta protegida (o se ejecuta desde una) y contiene
      # un verbo de escritura, se bloquea.
      norm="${seg//\$\{HOME\}/$HOME}"
      norm="${norm//\$HOME/$HOME}"
      norm="${norm//\~\//$HOME/}"
      if [[ $norm =~ $MUT_ANY ]]; then
        for p in "${PROTECTED[@]}"; do
          if [[ $norm == *"$p"* ]] || in_protected "$CWD"; then
            deny "'$verb' con una operación de escritura que afecta a una ruta protegida" "${HIT:-$p}"
          fi
        done
      fi
      ;;
  esac
done < <(split_segments "$CMD")
exit 0
