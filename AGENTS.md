# Instrucciones para trabajar en este repo

- Este repo es la **fuente** del harness `claude-design`. El runtime vive en
  `~/.claude-product-design` y solo se escribe con `tooling/design-runtime.sh --apply`.
- Límite duro: no modificar `~/.claude/`, `~/.codex/`, `~/.agents/skills/` ni los
  repos `harness-claude`, `harness-codex` y `harness-kimi`. Leer y enlazar sí.
- Nada de credenciales, sesiones ni historial en Git (ver `.gitignore`).
- Toda mutación Git pasa por `git-master` con autoridad expresa de Adrián.
