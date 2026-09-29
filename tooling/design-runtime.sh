#!/usr/bin/env bash
# Wrapper de design-runtime.py: sin flags = check (solo lectura);
# --apply | --uninstall; --root <dir> o DESIGN_RUNTIME_ROOT redirigen "~".

set -euo pipefail

runtime_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
runtime_python=${DESIGN_PYTHON:-}

for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
  if [[ -n $runtime_python ]]; then break; fi
  if command -v "$candidate" >/dev/null 2>&1 &&
     "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
    runtime_python=$candidate
    break
  fi
done

if [[ -z $runtime_python ]]; then
  printf '%s\n' '{"format":"harness-product-design/runtime/v1","valid":false,"error":"python_3_9_unavailable"}'
  exit 2
fi

PYTHONDONTWRITEBYTECODE=1 exec "$runtime_python" "$runtime_dir/design-runtime.py" "$@"
