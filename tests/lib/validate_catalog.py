"""Uso: validate_catalog.py <schema> <catalog>. Usa jsonschema si existe, si no minischema."""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))


def main() -> int:
    schema = json.loads(Path(sys.argv[1]).read_text())
    catalog = json.loads(Path(sys.argv[2]).read_text())
    try:
        import jsonschema  # type: ignore[import-not-found]

        jsonschema.Draft202012Validator.check_schema(schema)
        errs = [
            f"{'/'.join(map(str, e.absolute_path))}: {e.message}"
            for e in jsonschema.Draft202012Validator(schema).iter_errors(catalog)
        ]
        engine = "jsonschema"
    except ImportError:
        import minischema

        errs = minischema.validate(catalog, schema, schema)
        engine = "minischema"
    for e in errs:
        print(f"  schema: {e}")
    print(f"validador: {engine}, errores: {len(errs)}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
