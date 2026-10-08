defmodule SystemOneClient.Stub do
  @moduledoc "Test implementation of `SystemOneClient`: returns canned answers from `opts[:answers]`."
  @behaviour SystemOneClient
  alias SystemOneClient.Answer

  @impl true
  def evaluate(state, questions, opts) do
    case Keyword.fetch!(opts, :answers) do
      fun when is_function(fun, 2) -> fun.(state, questions) |> normalize()
      map when is_map(map) -> normalize(map)
    end
  end

  defp normalize({:error, reason}), do: {:error, reason}

  defp normalize(map) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn
      {id, %_{} = struct}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, id, struct)}}

      {id, raw}, {:ok, acc} ->
        case Answer.parse(raw) do
          {:ok, a} -> {:cont, {:ok, Map.put(acc, id, a)}}
          {:error, r} -> {:halt, {:error, {:malformed_answers, {id, r}}}}
        end
    end)
    |> case do
      {:ok, answers} -> {:ok, answers, %{model: "stub", usage: nil, latency_ms: 0}}
      err -> err
    end
  end
end
