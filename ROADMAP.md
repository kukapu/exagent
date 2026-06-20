# ExAgent — Roadmap

> Plan de ejecución por fases. Cada fase deja algo **agnóstico, testeable e
> independiente**. El caso motor (partida de D&D en Phoenix) se construye
> incrementalmente sobre las fases, pero ninguna fase es específica de D&D.
> Fundamento de diseño: ver `DESIGN.md`.

Convención: cada fase = módulos + tests + un ejemplo en `examples/` o
`test/support/`. `mix check` (`compile --warnings-as-errors + format + test`)
debe pasar al cerrar cada fase.

---

## Fase 0 — Núcleo funcional ✅ (HECHO)

Loop `model ⇄ tools`, providers (OpenAI/Anthropic/ZAI/OpenRouter/Test),
`deftool`, output estructurado Ecto, streaming lazy, capabilities, `UsageLimits`,
telemetría, serialización de message history.

Sin cambios. Es la base sobre la que se apoya todo.

---

## Fase 1 — Agente con estado: `ExAgent.Server`

**Objetivo.** Un agente longevo, supervisado, con memoria e historial, que emite
eventos. La pieza que falta para cualquier uso más allá de one-shot.

**Módulos.**
- `ExAgent.Event` — envelope versionado y serializable. Campos mínimos:
  `version`, `id`, `seq`, `type`, `source`, `occurred_at`, `run_id`,
  `request_id`, `agent_id`, `session_id`, `participant_id`, `payload`,
  `metadata`.
- `ExAgent.PubSub` behaviour — `broadcast/3` y `subscribe/2` opcional.
  Implementaciones: `None` (default), `Local` (Registry local), `Phoenix`
  (adaptador dinámico sin dependencia dura).
- `ExAgent.Server` (GenServer) — `start_link/1`, `chat/3`, `stream/3`,
  `send_message/3` (async → eventos), `steer/2`, `abort/1`, `set_model/2`,
  `history/1`, `usage/1`, `health/1`.
- Estado interno del Server (no público): agent + history + usage acumulado +
  model + status + current_task + pending queue + pubsub/topic + metadata.
- `ExAgent.AgentSupervisor` — `DynamicSupervisor` + `Registry` para
  arrancar/localizar agentes por id/nombre.
- `ExAgent.TaskSupervisor` — tareas supervisadas para que el GenServer siga
  respondiendo a `abort/1`, `health/1` y backpressure durante un run largo.

**Cambios pequeños al core funcional.**
- `ExAgent.run/3` debe aceptar un `:on_event` opcional usado por `Server` para
  publicar eventos del loop. Default: no-op.
- El result debe exponer el `model` final o provider state equivalente para que
  `Server` preserve modelos stateful como `ExAgent.Models.Test` entre chats.
- `Server` no debe duplicar system instructions en cada chat: las instrucciones
  se materializan una vez en el history de conversación y los siguientes runs
  agregan solo el nuevo user prompt.

**Semántica de concurrencia.**
- `chat/3`: bloquea al caller, ejecuta un run completo y actualiza history/usage.
- `send_message/3`: devuelve `{:ok, request_id}` inmediatamente y publica eventos
  en `"exagent:agent:<agent_id>"`.
- `stream/3`: usa el streaming actual para texto/deltas. En Fase 1 no promete
  tool-loop streaming completo; eso requiere el futuro stream de eventos del core.
- `abort/1`: cancela la tarea actual y emite `:server_request_cancelled`.
- `steer/2`: en Fase 1 encola un follow-up o metadata para el siguiente run. No
  modifica una request HTTP ya enviada al provider.
- Backpressure explícito: `:busy` si no hay cola; `:queue_full` si `max_pending`
  se supera.

**Cierre de fase.**
- Tests: arrancar un Server con `TestModel`, encadenar dos `chat/3` (el segundo
  ve el history del primero), `send_message/3` entrega resultado vía evento,
  eventos tienen envelope estable + `seq` monotónico, `abort/1` cancela la tarea,
  `send_message/3` respeta `:busy`/`:queue_full`.
- Ejemplo `examples/stateful_agent.exs`: agente conversacional offline.

**No incluye.** Durabilidad tras restart. Eso empieza en Fase 2.

**Sin esto no hay:** DM con vida ni ningún agente persistente.

---

## Fase 2 — Persistencia: `ExAgent.Store` (behaviour) + impl ETS ✅ (HECHO)

**Objetivo.** Estado resumible tras crash/restart. Desacoplado vía behaviour y
sin persistir procesos vivos, secrets ni function captures.

**Módulos.**
- `ExAgent.Server.Snapshot` — snapshot serializable: `agent_id`,
  `message_history`, `usage`, `model_ref/provider_state` si es serializable,
  `metadata`, timestamps. No contiene pids, API keys ni tool captures.
- `ExAgent.Store` (behaviour) — `save_agent_snapshot/2`,
  `load_agent_snapshot/1`, `save_session_snapshot/2`, `load_session_snapshot/1`,
  `list_agent_snapshots/1`, `delete/1`.
- `ExAgent.Store.ETS` — implementación en proceso (dev/test). Aunque ETS pueda
  guardar términos arbitrarios, sus tests deben pasar por serialización para no
  diseñar una API imposible de llevar a Postgres.
- `ExAgent.Server` se engancha: checkpoint tras cada `:run_finished`; al restart,
  recibe de la app el `agent` vivo y rehidrata history/usage desde el Store.

**Cierre de fase.**
- Tests: matar un Server supervisado → reaparece con su history intacta;
  guardar/cargar snapshot serializado; ETS aislado por namespace/sesión;
  confirmar que snapshots no incluyen secrets ni captures de tools.
- Documentar el contrato del behaviour para que Postgres venga después trivial.

**Sin esto no hay:** durabilidad; un crash pierde la partida.

---

## Fase 3 — Sesión: `ExAgent.Session` (agnóstica) ✅ (HECHO)

**Objetivo.** Una interacción con estado coordinada entre varios participantes
(humanos y/o agentes), con turnos y estado compartido. **El núcleo del
multi-agente y de la partida.**

**Módulos.**
- `ExAgent.Session` (GenServer) — lifecycle:
  `new/1 · join/2 · leave/2 · start/1 · take_turn/2 · pause/1 · resume/1 · close/1`.
  Mantiene `participants`, `shared_state` (struct app-defined), `turn_state` y
  `policy_state`.
- `ExAgent.Session.TurnPolicy` (behaviour) — `init/1`, `next_participant/2`,
  `can_act?/3` y estado propio de política. Implementaciones: `RoundRobin`,
  `Initiative`, `SupervisorDriven`.
- `ExAgent.Session.SharedState` — conveniencia para leer/escribir el struct
  compartido. La Session es el único writer: los tools reciben en
  `RunContext.deps` un servicio/ref que llama a la Session para leer o proponer
  cambios (patrón pydanticAI, sin estado mutable compartido).
- Session emite eventos por PubSub: `:participant_joined ·
  :session_turn_changed · :shared_state_updated · :session_closed`.

**Cierre de fase.**
- Tests: 2 `ExAgent.Server` + 1 "humano" (proceso de test) coordinados por
  `RoundRobin`; un turno modifica `shared_state` y el siguiente participante lo
  lee; escrituras concurrentes pasan por la Session; `pause/resume` congela y
  reanuda; `Initiative` respeta el orden dado.
- Ejemplo `examples/multi_agent_session.exs`: dos agentes (TestModel)
  intercambian turnos sobre un estado compartido.

**Agnosticidad explícita:** nada sabe de D&D. `shared_state` puede ser un mundo,
un ticket de soporte, un doc colaborativo.

---

## Fase 4 — Coordinación multi-agente: `ExAgent.Coordination` ✅ (HECHO)

**Objetivo.** Patrones de orquestación sobre la Session.

**Módulos.**
- `ExAgent.Coordination.delegation_tool/2` — genera un `Tool` que invoca a otro
  agente (patrón pydanticAI nivel 2); **usage compartido** entre padre e hijo.
- `ExAgent.Coordination.handoff/2` — pasa el control de un participante a otro
  (mensajería directa entre procesos).
- `ExAgent.Coordination.SupervisorPolicy` (TurnPolicy) — un participante
  "DM/supervisor" decide a quién delegar cada turno.

**Cierre de fase.**
- Tests: delegación con TestModel (el agente padre llama al hijo, el `usage`
  final suma ambos); handoff transfiere el turno; supervisor dirige a 2 bots.
- Cubre niveles 2 y 3 de la taxonomía pydanticAI.

---

## Fase 5 — Robustez/coste: Compaction, Cost guard, Prompt caching ✅ (HECHO)

**Objetivo.** Sesiones largas sin reventar contexto ni presupuesto.

**Módulos.**
- `ExAgent.Compaction` (behaviour) + `ExAgent.Compaction.Summary` —
  resume el historial al acercarse al límite de tokens (alloy/Pi). Se engancha
  como `Capability` (hook `before_model_request`).
- `ExAgent.CostGuard` — `max_budget_cents` / `max_tokens` frena el loop
  (alloy). Integrado en `UsageLimits` ya existente, añadiendo `tool_calls_limit`
  si aún no existe.
- Prompt caching Anthropic — `cache: true` añade breakpoints (alloy); ahorro
  60–90% en input.

**Cierre de fase.** Tests con historial sintético largo → compaction reduce
tokens manteniendo coherencia (TestModel); cost guard detiene al superar budget.

---

## Fase 6 — Producción y ecosistema: Permissions, MCP, Postgres, LiveView (parcial)

**Objetivo.** Lo que falta para llevar D&D (y apps reales) a producción.

**Hecho en 0.3.0:**

- `ExAgent.Permissions` — `allow/ask/deny` con globs por tool (opencode),
  fail-closed, integrado en `run/3` vía `:permissions` + `:approve`.
- `ExAgent.PubSub.Phoenix` — adaptador validado con LiveView real.

**Hecho en 0.4.0:**

- `ExAgent.Store.Postgres` — store durable vía Ecto/Postgrex (deps opcionales).
  Serialización JSON estricta (nunca terms opacos), `migrate/1` idempotente.
  Testado con Postgres real (auto-skip del tag `:postgres` si no hay BD).

**Pendiente (0.5.0+):**

- Aprobación async real (`:approval_requested` que pausa/reanuda el run o la
  Session, no bloquea dentro de un tool) sobre la base de Permissions.
- MCP client — consumir tool servers externos como un `Tool` provider.
- App LiveView de referencia — `examples/dnd_session.exs` demuestra la
  coordinación D&D offline (DM + bot + humano + mundo); una app Phoenix
  completa jugable queda como proyecto dedicado (la integración LiveView ya
  está probada por `chat_app`).

---

## Orden recomendado y dependencias

```
Fase 0 (✅) ──► Fase 1 (Server) ──► Fase 2 (Store) ──► Fase 3 (Session)
                                                            │
                                                            ▼
                                            Fase 4 (Coordination)
                                                            │
                                  Fase 5 (Compaction/Cost/Caching) ── paralelo
                                                            ▼
                                            Fase 6 (Prod: Perms/MCP/PG/LV)
```

Fases 1→3 son el camino crítico para tener el primer "juego jugable" (DM
supervisado + durabilidad + sesión con turnos). 4–6 amplían sin bloquear.

## Criterio de "listo para publicar como 0.2"

- Fases 1–3 completas + tests + ejemplos + docs (ex_doc con grupos por capa).
- README actualizado con la API por capas y el diagrama del módulo.
- `DESIGN.md` y `ROADMAP.md` referenciados desde el README.
