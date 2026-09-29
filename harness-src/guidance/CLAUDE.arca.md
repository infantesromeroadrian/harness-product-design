@~/.claude/identity.md

# Perfil arca: equivalencias de runtime

El núcleo ARCA describe mecánica de Codex. En este harness se lee así:

| Núcleo (Codex) | Claude Code |
|---|---|
| `spawn_agent` / `agent_type` | herramienta `Agent` con `subagent_type` |
| `followup_task` | `SendMessage` al mismo subagente |
| `interrupt_agent` | `TaskStop` |
| `$skill` | herramienta `Skill` o `/skill` |
| `obsidian-cli` | CLI `obsidian` con `vault="air-vault"` delante, o MCP `mcp__obsidian__*` |
| Memoria de trabajo | MCP `engram`, `scope=project` |

- Máximo tres subagentes concurrentes. Toda mutación Git pasa por `git-master` con autoridad expresa.
