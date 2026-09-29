# harness-product-design

Harness de Claude Code **para diseñadoras y diseñadores de producto**:
investigación UX · diseño de producto/UI y sistema de diseño · accesibilidad ·
producto y prototipado.

Se instala **al lado** de tu Claude Code habitual, sin tocarlo:

- Configuración propia en `~/.claude-product-design` (`CLAUDE_CONFIG_DIR`).
- Se abre con el comando `claude-design`; tu `claude` y tu `~/.claude` siguen igual.
- Portable: todo lo necesario va dentro del repo. No depende de la configuración
  de nadie.

## Perfiles

| Perfil | Para quién | Qué instala |
|---|---|---|
| `core` (por defecto) | Cualquier Mac | Identidad de diseño, agentes, skills, hooks de seguridad y MCP de diseño (Figma, Playwright, context7) incluidos en este repo |
| `arca` (opcional) | Quien ya tenga el harness ARCA | Además enlaza su núcleo ARCA, su vault y su memoria, si existen |

## Instalación (macOS)

Requisitos: Claude Code instalado (`claude`), `python3` 3.9 o superior (el de macOS sirve) y `git`.
Cierra cualquier sesión de `claude-design` antes de `--apply` o `--uninstall`.

```bash
git clone https://github.com/infantesromeroadrian/harness-product-design.git ~/Projects/harness-product-design
cd ~/Projects/harness-product-design
tooling/design-runtime.sh             # comprueba, sin escribir nada
tooling/design-runtime.sh --apply     # instala el perfil core
claude-design                         # primera vez: /login con tu cuenta de Claude
```

- Si `claude-design` no se encuentra, añade `~/.local/bin` al `PATH`
  (`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc` y abre otra terminal).
- `claude-design` ignora `ANTHROPIC_API_KEY` para usar tu suscripción. Si prefieres
  la clave: `CLAUDE_DESIGN_USE_API_KEY=1 claude-design`.
- **Figma**: dentro de `claude-design`, ejecuta `/mcp` y autoriza `figma` (OAuth).
- Opcional: `export DESIGN_VAULT=/ruta/a/tu/vault` (Obsidian) y
  `export CONTEXT7_API_KEY=...` antes de `--apply` para activar esos MCP.
- Tu `claude` y tu `~/.claude` no se tocan. El agente de `claude-design` trabaja con
  acceso completo a tu máquina, sin pedir permiso en cada paso, salvo escribir en la
  configuración de tus otros agentes (`~/.claude`, `~/.codex`, `~/.agents/skills`).

**Actualizar:** `git pull` y `tooling/design-runtime.sh --apply`.
**Desinstalar:** `tooling/design-runtime.sh --uninstall` (retira solo lo que instaló).

## Qué incluye

| Agente | Para qué |
|---|---|
| `ux-researcher` | Plan de investigación, entrevistas, test de usabilidad y síntesis |
| `product-strategist` | Problema, métricas de éxito, requisitos y priorización |
| `design-system-architect` | Tokens, componentes y gobernanza del sistema de diseño |
| `ui-designer` | Flujos, wireframes, pantallas y sus estados |
| `prototype-engineer` | Prototipo navegable en código |
| `accessibility-auditor` | Auditoría WCAG 2.2 AA (solo lectura) |
| `design-critic` | Crítica heurística y de sistema de diseño (solo lectura) |

Skills: `/design-flow <proyecto>` (conduce las 5 etapas: discovery, definición,
diseño, prototipo y validación), `research-synthesis`, `wcag-audit` y
`design-critique`. MCP: Figma, Playwright, Context7 y Obsidian (opcional).

## Contribuir

El repo es público. Para proponer agentes, skills o comandos:

1. Haz **fork** y crea una rama.
2. Añade tus piezas en `harness-src/` (agentes en `harness-src/agents/`,
   skills en `harness-src/skills/<nombre>/SKILL.md`) o, si prefieres que las
   integremos nosotros, en `contrib/<tu-nombre>/`.
3. Abre un **pull request**.

Nunca subas credenciales, tokens, datos de clientes ni contenido privado.
No enlaces tu `~/.claude` al repo: la instalación se hace siempre con
`tooling/design-runtime.sh`.
