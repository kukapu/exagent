defmodule ExAgent.Providers.SSE do
  @moduledoc """
  Turn a Req asynchronous response into a lazy `Stream` of Server-Sent-Events.

  Req streams the body into the calling process mailbox when `into: :self` is
  used; this module wraps that into an idiomatic Elixir stream. Each emitted
  item is either:

    * a decoded JSON `map` (the payload of a `data:` frame),
    * `{:error, reason}`, or
    * `:done` — emitted once as the very last item, signalling end-of-stream.

  Used by the OpenAI and Anthropic adapters' `request_stream/4`.
  """

  @default_timeout 60_000

  @spec stream(Req.Response.t(), keyword()) :: Enumerable.t()
  def stream(resp, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Stream.resource(
      fn -> {resp, <<>>, timeout} end,
      &next/1,
      fn
        {:done, resp, _} -> Req.cancel_async_response(resp)
        {resp, _, _} -> Req.cancel_async_response(resp)
        {resp, _} -> Req.cancel_async_response(resp)
      end
    )
  end

  # terminal state: just halt
  defp next({:done, resp, timeout}), do: {:halt, {:done, resp, timeout}}

  defp next({resp, buffer, timeout}) do
    receive do
      msg ->
        case Req.parse_message(resp, msg) do
          {:ok, chunks} ->
            {data, done?} = fold_chunks(chunks)
            buffer = buffer <> data
            {frames, rest} = pop_frames(buffer)
            events = Enum.flat_map(frames, &frame_payloads/1)

            if done? do
              # flush any trailing partial frame too, then emit :done sentinel
              trailing = if rest == <<>>, do: [], else: frame_payloads(rest)
              {events ++ trailing ++ [:done], {:done, resp, timeout}}
            else
              {events, {resp, rest, timeout}}
            end

          {:error, reason} ->
            {[{:error, reason}], {:done, resp, timeout}}

          :unknown ->
            next({resp, buffer, timeout})
        end
    after
      timeout ->
        {[{:error, :timeout}], {:done, resp, timeout}}
    end
  end

  defp fold_chunks(chunks) do
    Enum.reduce(chunks, {<<>>, false}, fn
      {:data, bin}, {acc, done?} -> {acc <> bin, done?}
      :done, {acc, _} -> {acc, true}
      _anything, acc -> acc
    end)
  end

  # Split complete frames (separated by a blank line); keep the trailing
  # incomplete chunk as the buffer.
  defp pop_frames(buffer) do
    case :binary.split(buffer, "\n\n", [:global]) do
      [_single] ->
        {[], buffer}

      parts ->
        {frames, [rest]} = Enum.split(parts, -1)
        {frames, rest}
    end
  end

  # Decode the `data:` payload(s) of a single SSE frame to a JSON map.
  defp frame_payloads(frame) do
    data_lines =
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(fn line ->
        line |> String.trim_leading("data:") |> String.trim()
      end)

    case data_lines do
      [] ->
        []

      lines ->
        case Enum.join(lines, "\n") do
          "[DONE]" ->
            []

          data ->
            case Jason.decode(data) do
              {:ok, map} when is_map(map) -> [map]
              _ -> []
            end
        end
    end
  end
end
