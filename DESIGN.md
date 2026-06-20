# ExAgent — Design Document

> Documento vivo. Describe la visión, principios, arquitectura y decisiones de
> diseño de ExAgent. Acompáñalo de `ROADMAP.md` para el plan de ejecución.

## 1. Visión

ExAgent aspira a ser uno de los mejores frameworks Hex para construir agentes
LLM, siendo a la vez:

- **Ergonómico como pydanticAI** — tools con schema derivado del tipo, output
  estructurado con changesets, dependencias tipadas, capabilities/hooks.
- **Robusto como alloy / normandy** — supervisión, telemetría, límites de uso,
  agentes como procesos.
- **Con una ventaja que ningún framework Python/TS puede igualar**: el runtime
  multi-agente **nativo del BEAM**. Cada agente es un proceso supervisado con
  mailbox; la coordinación multi-agente es mensajería OTP, no un "agent-as-tool"
  workaround.

ExAgent es **agnóstico**: no asume ningún dominio. El caso motor (una partida
de D&D en Phoenix con DM + bots + humanos en tiempo real) es el banco de
pruebas, pero el diseño sirve para soporte multi-agente, pipelines de
investigación, editores colaborativos, etc.

## 2. Principios

1. **Functional core, layered runtime** (inspirado en Pi). `ExAgent.run/3`
   sigue siendo one-shot y sin procesos propios; cualquier side-effect (eventos)
   es opt-in. Sobre él, capas opcionales y composibles: agente con estado →
   sesión → store. Nada te obliga a usar más capa de la que necesitas.
2. **Process-per-agent** (superpower del BEAM). Un agente ES un GenServer
   supervisado. Multi-agente = procesos mensajándose, con tolerancia a fallos
   real. Python/TS tienen que simular esto llamando agentes como tools.
3. **Ergonomía pydanticAI**. Deps (DI) tipadas vía `RunContext`, `deftool` que
   deriva JSON Schema de anotaciones `::`, output estructurado vía Ecto con
   retry, capabilities como middleware, `UsageLimits`.
4. **Agnóstico y componible**. Session = "interacción con estado coordinada
   entre participantes", no "partida". Store/Provider/Tool/Compaction/PubSub
   son behaviours: implementations intercambiables.
5. **Event-driven para tiempo real**. Cada capa emite eventos tipados (text
   deltas, tool calls, run steps, lifecycle) por PubSub. Cualquier UI
   (LiveView, CLI, channel) se suscribe. Convergencia de Pi + opencode + alloy.
6. **Sin dependencias forzadas**. DB-free por defecto (como hoy). Phoenix,
   Oban, Postgres, Redis son adaptadores opt-in, nunca requeridos.

## 3. De qué nos inspiramos (comparativa)

| Fuente | Qué tomamos de ella |
|---|---|
| **pydanticAI** | Estructura del `Agent` (instructions/tools/output/deps/model/settings/capabilities), `RunContext[deps]`, `UsageLimits`, delegación con usage compartido, taxonomía de los 5 niveles de complejidad, `agent.iter()` (iterar el grafo nodo a nodo). |
| **alloy** | Agente como GenServer supervisado, async dispatch vía PubSub, **context compaction** summary-based, **cost guard** (`max_budget_cents`), **prompt caching**, memory primitive como behaviour, telemetría por capa, `until_tool` para output estructurado. |
| **normandy** | Coordinación multi-agente reactiva (`race`/`all`/`some`), **sesiones distribuidas en tiers**, guardrails (admission control), MCP/A2A, circuit breakers, batch. |
| **Pi Agent** | **Separación de capas** (ai / agent-core / AgentSession / SessionManager / Runtime), `AgentState` explícito, **eventos** (`subscribe`), **árbol de sesiones** con branching/fork/clone, steer/followUp mid-stream, ResourceLoader. |
| **opencode** | **Primary vs subagents**, **permissions** `allow`/`ask`/`deny` con globs (human-in-the-loop), config de agente (mode/steps/task-permissions), **sesiones como árbol** (revert/unrevert), patrón server+SDK+SSE, compaction como agente oculto del sistema. |
| **Anthropic SDK / tool-use** | Loop canónico (tool_use → ejecutas → tool_result → repite; `stop_reason`), `strict:true`, distinción client/server tools. Tu `run/3` ya lo implementa. |

## 4. Mapa de módulos

```
ExAgent (lib)
│
├── Núcleo funcional — EXISTE
│   ├── ExAgent.run/3 · run!/2 · run_stream/3        one-shot: model ⇄ tools
│   ├── ExAgent.RunContext[deps]                     DI + usage + messages + tool info
│   ├── ExAgent.Tool · ExAgent.Tools (deftool)       JSON schema derivado del tipo ::
│   ├── ExAgent.Schema · OutputSchema                Ecto → JSON schema + validate + retry
│   ├── ExAgent.Message · Part                       request/response/usage, serializable
│   ├── ExAgent.ModelSettings · UsageLimits          temperature; límites tokens/requests/tool_calls
│   └── ExAgent.Capability · Capabilities            middleware componible (hooks before/after)
│
├── Layer 1 — Agente con estado — NUEVO
│   └── ExAgent.Server          GenServer supervisado
│         · chat/3 · stream/3 · send_message/3 (async → evento)
│         · AgentState: agent + history + usage + model + status + pending
│         · emite eventos (text_delta · tool_call_finished · run_finished)
│         · steer/2 · abort/1   (cancelar o encolar follow-up)
│
├── Layer 2 — Sesión / Coordinación — NUEVO (agnóstico)
│   ├── ExAgent.Session         GenServer
│   │     · lifecycle: new/join/leave/start/turn/pause/resume/close
│   │     · participantes: humanos + pids de ExAgent.Server (vía Registry)
│   │     · turn policy (behaviour): round_robin · initiative · supervisor · custom
│   │     · shared_state: struct app-defined (Ecto) — "el mundo"; tools acceden vía deps
│   │     · broadcasts SessionEvents por PubSub
│   └── ExAgent.Coordination
│         · delegation_tool  (pydanticAI: agent-as-tool, usage compartido)
│         · handoff          (trivial: mensaje entre procesos)
│         · (futuro) race/all/some
│
└── Cross-cutting — behaviours / adaptadores
    ├── ExAgent.Store           behaviour  ·  snapshots · ETS (dev) → Postgres (prod)
    ├── ExAgent.Provider        EXISTE (behaviour)  ·  OpenAI/Anthropic/ZAI/OpenRouter/Test
    ├── ExAgent.PubSub          behaviour  ·  None | Local Registry | Phoenix.PubSub | custom
    ├── ExAgent.Compaction      behaviour  ·  summary-based; se engancha como capability
    ├── ExAgent.Permissions     (futuro)   ·  allow/ask/deny + approval human-in-the-loop
    └── ExAgent.Telemetry       EXISTE     ·  eventos en todas las capas
```

## 5. Los 5 niveles de complejidad (pydanticAI) y cómo los cubre ExAgent

ExAgent debe servir para cada nivel sin que el superior contamine al inferior:

| Nivel | pydanticAI | ExAgent |
|---|---|---|
| 1. Agente único | `Agent.run()` | `ExAgent.run/3` (one-shot, sin procesos) |
| 2. Delegación (agent-as-tool) | tool que llama a otro agent, `usage` compartido | `ExAgent.Coordination.delegation_tool/2` |
| 3. Hand-off programático | código de app encadena agents | app code entre `ExAgent.Server` (procesos) |
| 4. Graph / FSM de control | `pydantic-graph` (lib aparte) | `ExAgent.Session` + `TurnPolicy` (FSM sobre participantes) |
| 5. Deep agents | planning + files + delegation + sandbox + durable | Session + compaction + delegation + approval + Store durable |

La diferencia clave: en Python/TS los niveles 2–5 son "un agente llama a otro
como tool" porque **no hay procesos**. En ExAgent son **procesos que se
mensajean**, supervisados, con estado real y resumible. Más simple, más robusto.

## 6. Modelo de eventos (convergencia Pi + opencode + alloy)

Regla central: **eventos y telemetry no son lo mismo**.

- `ExAgent.Event` es el contrato de UI/runtime. Lo consumen LiveView, CLI,
  Channels, logs de producto, tests de flujos y cualquier proceso interesado.
- `:telemetry` sigue siendo observabilidad técnica. Lo consumen métricas, OTel,
  dashboards y alertas. Puede emitirse en paralelo, pero no sustituye al evento.

Un evento es un envelope versionado y serializable:

```elixir
%ExAgent.Event{
  version: 1,
  id: "evt_...",
  seq: 12,
  type: :tool_call_finished,
  source: :run,
  occurred_at: ~U[...],
  run_id: "run_...",
  request_id: "req_...",
  agent_id: "agent_...",
  session_id: nil,
  participant_id: nil,
  payload: %{},
  metadata: %{}
}
```

Terminología fija:

- **run**: una invocación completa del loop (`ExAgent.run/3`) para un prompt,
  incluyendo retries y tool calls hasta producir output final o error.
- **run step**: una request al modelo + su response + el batch de tools que esa
  response dispare.
- **session turn**: turno de un participante dentro de `ExAgent.Session`. No se
  usa `turn` para pasos internos del loop, para no mezclarlo con D&D/soporte.

Eventos previstos:

```
:run_started · :run_finished · :run_failed
:run_step_started · :run_step_finished
:message_created
:text_delta · :thinking_delta
:tool_call_started · :tool_call_finished
:usage_updated
:server_request_queued · :server_request_cancelled
:approval_requested
:compaction_started · :compaction_finished
:session_started · :participant_joined · :participant_left
:session_turn_changed · :shared_state_updated · :session_closed
```

Transporte: `ExAgent.PubSub` es un behaviour pequeño, no una dependencia.

- `:none` / `ExAgent.PubSub.None`: default sin side-effects.
- `ExAgent.PubSub.Local`: PubSub local con `Registry` de claves duplicadas.
- `ExAgent.PubSub.Phoenix`: adaptador opcional que llama a `Phoenix.PubSub`
  dinámicamente si la app lo tiene instalado.
- `custom`: cualquier módulo que implemente `broadcast/3` y, si aplica,
  `subscribe/2`.

Los mensajes publicados usan la forma `{:exagent_event, %ExAgent.Event{}}`.
Topics recomendados: `"exagent:agent:<agent_id>"` y
`"exagent:session:<session_id>"`.

## 7. Cómo encajan dominios concretos (demuestra agnosticidad)

- **D&D (caso motor).** DM = `ExAgent.Server` con tools de DM; bots = `Server`
  con tools de jugador; la partida = `Session` (initiative order = TurnPolicy,
  mundo = `shared_state` Ecto). La `Session` es el único writer del mundo; los
  tools reciben en `deps` un servicio/ref de sesión y piden cambios mediante la
  API de la Session. Humanos = LiveView publicando acciones a la Session; tiempo
  real vía PubSub.
- **Soporte multi-agente.** Supervisor = `Session` con TurnPolicy
  supervisor-driven; especialistas = `Server`; handoff = delegación; guardrails
  = capabilities.
- **Pipeline de investigación.** `Session` lineal/ramificada; cada paso un
  `Server`; compaction entre pasos; resultado estructurado (Ecto).
- **Chat asistido simple.** Solo nivel 1: `ExAgent.run/3` + tu propio store.
  No pagas la complejidad de Session.

## 8. Decisiones de diseño clave (con rationale)

- **Alloy/Normandy son referencias, no dependencias runtime por defecto.** Se
  toman sus técnicas (event envelopes, backpressure, compaction, stores por
  tiers, circuit breakers), pero ExAgent no debe wrappear otro framework salvo
  que un adaptador opt-in lo justifique.
- **DB-free, behaviours everywhere.** El framework no posee DB ni cola. Store,
  PubSub, Compaction son behaviours. Evita acoplar a Postgres/Oban/Phoenix
  (lección de alloy y del README actual).
- **Server = conversación con estado; Session = coordinación.** `ExAgent.Server`
  conserva history/usage/model y ejecuta runs. No decide turnos entre
  participantes ni conoce `shared_state`. Eso pertenece a `ExAgent.Session`.
- **Session = FSM sobre participantes.** No es "una partida"; es una máquina de
  estados genérica coordinando N participantes con una política de turnos. Un
  `TurnPolicy` behaviour permite round-robin, initiative, supervisor, o custom.
- **Session es single-writer del `shared_state`.** Los tools nunca mutan el
  mundo directamente. Reciben deps de dominio que llaman a la Session, que
  serializa la actualización, emite `:shared_state_updated` y mantiene invariantes.
- **Multi-agent = mensajería, no tool-calls.** La coordinación usa mensajes
  entre procesos (Registry localiza agentes). La delegación *está disponible*
  como tool para compatibilidad con el patrón pydanticAI, pero no es el
  mecanismo principal.
- **Eventos como contrato de UI.** Phoenix no es requerido: el contrato son
  eventos tipados sobre PubSub. LiveView es un adaptador más.
- **Store persiste snapshots, no procesos vivos.** Nunca se persisten pids,
  closures/captures de tools ni credenciales. Se persisten ids, history
  serializada, usage, metadata y referencias/templates rehidratables por la app.
  Esto evita bloquear el futuro Postgres/multi-nodo desde la Fase 2.
- **Backpressure antes que magia.** `send_message/3` debe devolver `:busy` o
  `:queue_full` de forma explícita. Las colas infinitas son un bug de producto.
- **Sin motor de graphs genérico al inicio.** La Session + TurnPolicy cubre el
  caso de uso sin la complejidad de un `pydantic-graph` completo. Se evaluará
  si un dominio lo justifica.
- **`strict: true` por defecto** en schemas de tools cuando el provider lo
  soporte (mejor conformidad; lección de Anthropic).

## 9. Estado actual y no-goals

**Hecho (núcleo funcional):** loop, providers (OpenAI/Anthropic/ZAI/OpenRouter/Test),
deftool, output estructurado Ecto, streaming lazy, capabilities, UsageLimits,
telemetría, serialización de history.

**No-goals explícitos (al inicio):**
- No motor de graphs/FSM genérico tipo pydantic-graph.
- No MCP server propio (sí client en fases tardías).
- No A2A entre nodos distribuidos hasta que Store Postgres lo habilite.
- No RAG/embeddings/vectores dentro del core (vivirá como capability opcional).
- No persistir credenciales, pids, refs ni captures de funciones en Store.

Ver `ROADMAP.md` para el plan de ejecución por fases.
