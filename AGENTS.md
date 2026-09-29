# Instrucciones para trabajar en este repo

- Este repo es la **fuente** del harness `claude-design`. El runtime vive en
  `~/.claude-product-design` y solo se escribe con `tooling/design-runtime.sh --apply`.
- **Portable**: el perfil `core` no puede depender de nada fuera del repo (ni
  `~/.claude`, ni vaults, ni rutas de una persona concreta). Lo específico de
  ARCA va en ficheros `*.arca.*` y en entradas `profile: arca` del catálogo.
- No modificar `~/.claude/`, `~/.codex/` ni `~/.agents/skills/` de quien instala.
- Repo **público**: nada de credenciales, tokens, sesiones, historial, datos de
  clientes ni contenido privado (`gitleaks` antes de cada commit y push).
- Contribuciones externas: fork + pull request (ver README).
- Commits: Conventional Commits con estos scopes: `catalog`, `schemas`,
  `tooling`, `tests`, `guidance`, `config`, `mcp`, `hooks`, `agents`, `skills`,
  `docs`, `contrib`.
