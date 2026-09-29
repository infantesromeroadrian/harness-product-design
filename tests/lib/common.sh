# Utilidades compartidas por los smoke tests (se carga con `source`).
# shellcheck shell=bash

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
lib_dir="$repo_root/tests/lib"
tmp_base=""
fails=0
export PYTHONDONTWRITEBYTECODE=1

setup_tmp() {
  tmp_base=$(mktemp -d "${TMPDIR:-/tmp}/hpd-test.XXXXXX")
  tmp_base=${tmp_base//\/\//\/}
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_base'" EXIT
}

ok()   { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check() { # check <descripcion> <comando...>
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

# jget <fichero-json> <expresion-python-sobre-d>
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# make_fixture <base> [core|arca]: copia catalogo/fuentes a <base>/repo, crea <base>/home y lo completa.
make_fixture() {
  local base=$1 profile=${2:-core}
  mkdir -p "$base/repo/harness-src" "$base/home"
  cp -R "$repo_root/catalog" "$repo_root/schemas" "$repo_root/tooling" "$base/repo/"
  if [[ -d $repo_root/harness-src ]]; then cp -R "$repo_root/harness-src/." "$base/repo/harness-src/"; fi
  python3 "$lib_dir/fixtures.py" "$base/repo" "$base/home" "$profile"
}

# same_snapshot <descripcion> <a.json> <b.json>: compara huellas e imprime las diferencias.
same_snapshot() {
  if python3 - "$2" "$3" <<'PY'
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
diff = sorted(set(a) ^ set(b)) + [k for k in a if k in b and a[k] != b[k]]
for k in diff:
    print("  diff:", k, a.get(k), "->", b.get(k))
sys.exit(1 if diff else 0)
PY
  then ok "$1"; else fail "$1"; fi
}

finish() {
  if ((fails > 0)); then printf '\n%s: %d fallo(s)\n' "$1" "$fails"; exit 1; fi
  printf '\n%s: OK\n' "$1"
}
