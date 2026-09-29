---
name: design-flow
description: Arranca o retoma un proyecto de diseño con /design-flow <proyecto>. Crea la estructura de artefactos, muestra la etapa actual y su gate, y delega en el owner de la etapa.
disable-model-invocation: true
argument-hint: <proyecto>
---

# /design-flow

Conduce un proyecto de diseño por cinco etapas: Discovery, Definición, Diseño, Prototipo y Validación.
Argumento: `$ARGUMENTS` (nombre del proyecto en minúsculas y con guiones). Si está vacío, pídelo.

## 1. Localizar o crear la estructura
1. Destino de artefactos:
   - si el MCP `obsidian` está disponible (o existe la variable `DESIGN_VAULT`), la carpeta del proyecto en
     el vault, en la sección que indique la persona usuaria;
   - si no, `docs/design/<proyecto>/` en el repo del producto (directorio actual).
2. Si la carpeta existe, es una reanudación: lee `00-Panel-Control.md` y el fichero de la última etapa.
   No sobrescribas nada existente.
3. Si no existe, créala con estos ficheros (plantilla mínima, con estado `pendiente`):
   `00-Panel-Control.md` (hub: objetivo, etapa actual, tabla de etapas con estado, decisiones, riesgos),
   `discovery.md`, `definicion.md`, `diseno.md`, `prototipo.md` y `validacion.md`. Cada fichero de etapa
   lleva: objetivo, owner, artefactos, gate de salida (casillas) y notas.

## 2. Mostrar etapa actual y gate
Determina la etapa actual como la primera cuyo gate no esté cumplido y muéstrala junto a su gate:

| Etapa | Owner | Gate de salida |
|---|---|---|
| Discovery | `ux-researcher` (+ `product-strategist`) | Cada insight enlaza al menos una evidencia; supuestos marcados validado o por validar |
| Definición | `product-strategist` | Métricas cuantificadas y aprobación de la persona responsable del producto |
| Diseño | `ui-designer` + `design-system-architect` | 100 % de requisitos trazados a pantalla o flujo; `design-critic` sin bloqueantes |
| Prototipo | `prototype-engineer` (+ `ui-designer`) | Flujos críticos recorribles de extremo a extremo; build en verde |
| Validación | `accessibility-auditor`, `design-critic`, `ux-researcher` | 0 violaciones critical/serious; tasa de éxito >= umbral de Definición; hallazgos convertidos en tareas |

## 3. Delegar
1. Lanza al owner de la etapa (herramienta `Agent`, `subagent_type` = su nombre) con un brief
   autocontenido: proyecto, etapa, rutas de los artefactos previos, ruta de salida, criterio de hecho.
2. Máximo tres subagentes a la vez. Un solo owner por cada fichero que se escribe.
3. Los validadores (`accessibility-auditor`, `design-critic`) son de solo lectura: devuelven el informe y
   quien coordina lo guarda en `validacion.md` o `diseno.md`.

## 4. Cerrar la etapa
Comprueba el gate con evidencia leída de los ficheros, no con lo que el subagente afirma. Si se cumple,
marca la etapa y actualiza `00-Panel-Control.md`; si no, lista qué falta. La etapa Definición exige
aprobación expresa de la persona responsable del producto. No avances de etapa sin gate cumplido.
