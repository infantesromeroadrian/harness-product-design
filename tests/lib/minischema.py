"""Validador minimo de JSON Schema (stdlib): solo las palabras clave que usa
schemas/catalog.schema.json. Sustituto de `jsonschema` cuando no esta instalado.
"""

from __future__ import annotations

import re
from typing import Any

Json = Any


def _type_ok(value: Json, name: str) -> bool:
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }[name]


def validate(instance: Json, schema: Json, root: Json, path: str = "$") -> list[str]:
    if "$ref" in schema:
        node: Json = root
        for part in schema["$ref"].removeprefix("#/").split("/"):
            node = node[part]
        return validate(instance, node, root, path)
    errors: list[str] = []
    if "type" in schema and not _type_ok(instance, schema["type"]):
        return [f"{path}: tipo {schema['type']} esperado"]
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: debe ser {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: {instance!r} fuera de {schema['enum']}")
    if isinstance(instance, str):
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            errors.append(f"{path}: no cumple {schema['pattern']}")
        if len(instance) < schema.get("minLength", 0):
            errors.append(f"{path}: demasiado corto")
        if len(instance) > schema.get("maxLength", 10**9):
            errors.append(f"{path}: demasiado largo")
    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            errors.append(f"{path}: menos de {schema['minItems']} elementos")
        if schema.get("uniqueItems") and len({repr(i) for i in instance}) != len(instance):
            errors.append(f"{path}: elementos repetidos")
        if "items" in schema:
            for i, item in enumerate(instance):
                errors += validate(item, schema["items"], root, f"{path}[{i}]")
    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: falta {key!r}")
        props = schema.get("properties", {})
        for key, value in instance.items():
            if key in props:
                errors += validate(value, props[key], root, f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}: propiedad no permitida {key!r}")
    if "not" in schema and not validate(instance, schema["not"], root, path):
        errors.append(f"{path}: cumple un esquema prohibido")
    if "anyOf" in schema and not any(not validate(instance, s, root, path) for s in schema["anyOf"]):
        errors.append(f"{path}: no cumple ninguna alternativa de anyOf")
    for sub in schema.get("allOf", []):
        errors += validate(instance, sub, root, path)
    if "if" in schema:
        branch = "then" if not validate(instance, schema["if"], root, path) else "else"
        if branch in schema:
            errors += validate(instance, schema[branch], root, path)
    return errors
