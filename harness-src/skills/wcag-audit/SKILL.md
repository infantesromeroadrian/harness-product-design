---
name: wcag-audit
description: Procedimiento de auditoría WCAG 2.2 AA con axe-core inyectado con Playwright, checklist manual (teclado, foco, contraste, lector, movimiento, objetivos táctiles) y formato de informe con severidad.
---

# WCAG 2.2 AA audit

## 1. Automática con axe-core (Playwright MCP)
1. `browser_navigate` a la URL y `browser_wait_for` a que cargue.
2. Con `browser_evaluate`, inyecta axe-core desde un CDN y ejecútalo (versión fijada):

```js
async () => {
  if (!window.axe) {
    await new Promise((res, rej) => {
      const s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/axe-core@4.10.2/axe.min.js';
      s.onload = res; s.onerror = () => rej(new Error('axe no cargó (CSP o sin red)'));
      document.head.appendChild(s);
    });
  }
  const r = await window.axe.run(document, {
    runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'] }
  });
  return r.violations.map(v => ({
    id: v.id, impact: v.impact, help: v.help, tags: v.tags.filter(t => t.startsWith('wcag')),
    nodes: v.nodes.slice(0, 5).map(n => ({ target: n.target, summary: n.failureSummary }))
  }));
}
```

3. Repite por pantalla y por estado (vacío, error, diálogo abierto, móvil con `browser_resize`).
4. Si la CSP bloquea el CDN, dilo: es una limitación, no un resultado limpio. Alternativa: axe-core
   instalado en el proyecto y expuesto por el prototipo.
5. Correspondencia de severidad: `critical` y `serious` de axe se conservan; `moderate` y `minor` igual.
Axe no cubre todos los criterios: 0 violaciones no equivale a conformidad.

## 2. Checklist manual (por flujo crítico)
- [ ] Teclado: todo operable con Tab, Shift+Tab, Enter, Espacio, flechas y Esc; sin trampas (2.1.1, 2.1.2).
- [ ] Orden de foco lógico y coherente con el visual (2.4.3); foco visible (2.4.7) y no oculto por
      cabeceras o banners fijos (2.4.11).
- [ ] Contraste: texto 4.5:1 (3:1 grande), componentes y estados 3:1 (1.4.3, 1.4.11).
- [ ] Nombre, rol y valor en el árbol de accesibilidad (`browser_snapshot`) (4.1.2); imágenes con
      alternativa (1.1.1); encabezados y regiones (1.3.1, 2.4.1).
- [ ] Formularios: etiquetas, instrucciones, errores identificados y sugerencias (3.3.1, 3.3.2, 3.3.3);
      no se pide reintroducir datos ya dados (3.3.7).
- [ ] Reflujo a 320 px y zoom 200 % sin pérdida ni scroll bidireccional (1.4.10, 1.4.4).
- [ ] Movimiento: respeta `prefers-reduced-motion`; nada parpadea más de 3 veces por segundo (2.3.1, 2.3.3).
- [ ] Objetivos táctiles de al menos 24x24 px o con espacio suficiente (2.5.8).
- [ ] Arrastrar tiene alternativa sin arrastre (2.5.7); ayuda en el mismo lugar entre páginas (3.2.6).
- [ ] Lector de pantalla real (VoiceOver, NVDA): no se puede automatizar; si no se probó, «no verificado».

## 3. Formato de informe
```
# Auditoría WCAG 2.2 AA - <proyecto> - <fecha>
Alcance: <URLs, flujos, viewports>  Método: axe-core <versión> + checklist manual
Resumen: critical N, serious N, moderate N, minor N. Veredicto: aprobado | no aprobado (0 critical/serious)

## A11Y-001 - <título>
Criterio: <n.n.n Nombre> (nivel A|AA)   Severidad: critical|serious|moderate|minor
Ubicación: <URL + selector o fichero:línea>
Evidencia: <captura, fragmento del árbol, salida de axe>
Impacto: <quién queda excluido y cómo>
Corrección: <cambio concreto>

## No verificado
<criterios o dispositivos no cubiertos y motivo>
```
