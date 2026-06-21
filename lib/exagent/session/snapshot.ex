defmodule ExAgent.Session.Snapshot do
  @moduledoc """
  A serializable checkpoint of an `ExAgent.Session`'s coordination state.

  Carries the **serializable** parts of a session: the app-defined
  `shared_state`, the participant roster (ids + kinds — never the live `ref`s),
  the turn-policy module and its state, the current participant, and the status.

  Just like `ExAgent.Server.Snapshot`, it round-trips through **strict JSON** so
  nothing opaque (pids, secrets, closures, the live agent refs) can land in the
  store. The live participant `ref`s come from the app on restart.

  ## The shared_state portability rule

  `shared_state` must be JSON-encodable (plain maps/lists/scalars, or a struct
  with `@derive [Jason.Encoder]` whose fields are themselves JSON-safe — avoid
  tuples, which Jason turns into arrays that don't round-trip). `Jason.encode!`
  raises rather than persisting junk, exactly like `Server.Snapshot` does for
  `metadata`.
  """

  defstruct [
    :session_id,
    :shared_state,
    :participants,
    :policy_mod,
    :policy_state,
    :current,
    :status,
    :seq,
    :metadata,
    :version,
    :saved_at
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          shared_state: term(),
          participants: [%{id: term(), kind: atom()}],
          policy_mod: module(),
          policy_state: term(),
          current: term() | nil,
          status: atom(),
          seq: non_neg_integer(),
          metadata: map(),
          version: pos_integer(),
          saved_at: String.t() | nil
        }

  @version 1

  @doc "Build a snapshot from a `Session.State`, stripping non-serializable refs."
  def new(%ExAgent.Session.State{} = s) do
    %__MODULE__{
      session_id: s.session_id,
      shared_state: s.shared_state,
      participants:
        Enum.map(s.participants, fn {_id, %ExAgent.Session.Participant{id: id, kind: kind}} ->
          %{id: id, kind: kind}
        end),
      policy_mod: s.policy_mod,
      policy_state: s.policy_state,
      current: s.current,
      status: s.status,
      seq: s.seq,
      metadata: s.metadata,
      version: @version
    }
  end

  @doc "Strict JSON encode. Raises on non-encodable values (pids, closures, …)."
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = snap) do
    Jason.encode!(%{
      version: snap.version || @version,
      session_id: snap.session_id,
      shared_state: snap.shared_state,
      participants: snap.participants,
      policy_mod: Atom.to_string(snap.policy_mod),
      policy_state: encode_policy_state(snap.policy_state),
      current: snap.current,
      status: snap.status,
      seq: snap.seq,
      metadata: snap.metadata,
      saved_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @doc "Decode JSON back into a snapshot, reconstructing the policy struct."
  @spec deserialize(binary()) :: {:ok, t()} | {:error, term()}
  def deserialize(binary) do
    with {:ok, %{} = map} <- Jason.decode(binary) do
      {:ok,
       %__MODULE__{
         session_id: map["session_id"],
         shared_state: map["shared_state"],
         participants:
           Enum.map(map["participants"] || [], fn
             %{"id" => id, "kind" => kind} -> %{id: id, kind: atomize(kind)}
             p -> p
           end),
         policy_mod: safe_module(map["policy_mod"]),
         policy_state: decode_policy_state(map["policy_state"]),
         current: map["current"],
         status: atomize(map["status"]),
         seq: map["seq"] || 0,
         metadata: map["metadata"] || %{},
         version: map["version"] || @version,
         saved_at: map["saved_at"]
       }}
    end
  end

  # A policy_state is normally a struct (RoundRobin/Initiative/SupervisorPolicy)
  # with JSON-safe fields. Round-trip it via its __struct__ tag so the turn
  # position (index/current) survives a restart.
  defp encode_policy_state(%{__struct__: mod} = state) do
    fields = state |> Map.from_struct() |> encode_fields()
    Map.put(fields, "__struct__", Atom.to_string(mod))
  end

  defp encode_policy_state(other), do: other

  defp decode_policy_state(%{"__struct__" => mod_str} = map) when is_binary(mod_str) do
    case safe_module(mod_str) do
      nil ->
        nil

      mod ->
        map
        |> Map.delete("__struct__")
        |> Enum.into(%{}, fn {k, v} -> {atomize(k), decode_field(v)} end)
        |> then(&struct(mod, &1))
    end
  end

  defp decode_policy_state(other), do: other

  # struct field values: turn tuple-lists back into tuples (JSON lost them) and
  # leave everything else as decoded. Only do this for known tuple-shaped fields?
  # No — heuristics are fragile. Keep values as decoded; apps with tuples in
  # policy_state must make them JSON-portable (same rule as shared_state).
  defp encode_fields(fields), do: fields
  defp decode_field(v), do: v

  defp atomize(value) when is_binary(value) do
    # Only mint atoms that already exist (the policy modules/status atoms are
    # loaded with the app); avoids atom-table growth from a hostile store.
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> value
    end
  end

  defp atomize(value), do: value

  defp safe_module(mod_str) when is_binary(mod_str) do
    case Code.ensure_loaded(atomize(mod_str)) do
      {:module, mod} -> mod
      _ -> nil
    end
  end

  defp safe_module(mod) when is_atom(mod), do: mod
  defp safe_module(_), do: nil
end
