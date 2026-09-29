---
name: design-critique
description: Crítica de diseño con las 10 heurísticas de Nielsen (preguntas de revisión), checklist de consistencia con el sistema de diseño y formato de hallazgos con evidencia y severidad.
---

# Design critique

Critica decisiones, no personas. Demuestra el defecto con evidencia antes de pedir un cambio.

## Heurísticas de Nielsen: pregunta de revisión
1. **Visibilidad del estado**: ¿la persona sabe siempre dónde está, qué pasa y si su acción funcionó?
2. **Coincidencia con el mundo real**: ¿el lenguaje y las metáforas son los de la persona usuaria?
3. **Control y libertad**: ¿puede deshacer, cancelar o salir sin penalización?
4. **Consistencia y estándares**: ¿lo mismo se ve y se comporta igual en todas partes?
5. **Prevención de errores**: ¿se evita el error antes de que ocurra (restricciones, confirmaciones útiles)?
6. **Reconocer antes que recordar**: ¿la información necesaria está a la vista cuando hace falta?
7. **Flexibilidad y eficiencia**: ¿hay atajos para expertas sin estorbar a novatas?
8. **Diseño estético y minimalista**: ¿cada elemento aporta o solo compite por atención?
9. **Ayudar a reconocer y recuperarse de errores**: ¿el mensaje dice qué falló y cómo arreglarlo?
10. **Ayuda y documentación**: ¿hay ayuda contextual, breve y accionable?

## Checklist de sistema de diseño
- [ ] Todos los colores, tipografías, espaciados y radios salen de tokens; sin valores sueltos.
- [ ] Ningún componente duplica o altera uno existente; las variantes usadas existen en el sistema.
- [ ] Cada pantalla tiene estados vacío, carga, error y éxito.
- [ ] Texto y componentes cumplen el contraste declarado en los tokens.
- [ ] Jerarquía visual: un foco principal por pantalla; agrupación por proximidad; densidad razonable.
- [ ] Carga cognitiva: pocas decisiones simultáneas, etiquetas claras, divulgación progresiva.
- [ ] Trazabilidad: cada requisito llega a una pantalla; cada pantalla responde a un requisito.

## Severidad
| Nivel | Criterio |
|---|---|
| bloqueante | Impide completar un flujo crítico o incumple un requisito |
| mayor | Causa error o fricción frecuente; debe corregirse antes de validar |
| menor | Molestia puntual o inconsistencia local |
| sugerencia | Mejora opcional |

## Formato de hallazgo
```
## CRIT-001 - <título>
Heurística/criterio: <n. Nombre | Sistema de diseño | Trazabilidad>   Severidad: bloqueante|mayor|menor|sugerencia
Ubicación: <pantalla, ruta de fichero o URL>
Evidencia: <captura, fragmento, referencia a REQ-###>
Impacto: <qué le pasa a la persona usuaria>
Corrección propuesta: <cambio concreto>
```
Cierra el informe con un resumen por severidad, la lista de lo que funciona bien y lo no verificado.
Veredicto: `sin bloqueantes` habilita la salida de la etapa Diseño.
