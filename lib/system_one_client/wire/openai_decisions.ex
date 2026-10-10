defmodule SystemOneClient.Wire.OpenAIDecisions do
  @moduledoc """
  Translation between the System One wire format and OpenAI's Decisions API
  (`POST /v1/decisions`).

  Callers keep writing System One questions (a map of id to `noul` / `choice` /
  `score`) and get System One answers back; this module maps both directions:

  | System One | OpenAI Decisions |
  | --- | --- |
  | `state` (any JSON) | `input` (text; non-string state is JSON-encoded) |
  | `%{id => question}` | `[%{name: id, ...}]` |
  | `noul` with optional `true` / `false` criteria | `predicate`, with the criteria folded into `instructions` |
  | `choice` `criteria: %{value => description}` | `choices: [%{value, description}]` |
  | `score` `criteria: [description]` | `levels: [%{label: "Level N", description}]` |
  | answers keyed by id, probabilities as maps | answers array keyed by `name`, probabilities as arrays |
  | none | `refusal`, decoded to `%{"type" => "refusal"}` |

  Non-string instructions and descriptions (System One allows objects and arrays) are
  JSON-encoded, since OpenAI expects text.
  """

  @doc "Builds the `/v1/decisions` request body."
  @spec encode_request(term(), map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def encode_request(state, questions, model) do
    questions
    |> Enum.sort_by(fn {id, _} -> to_string(id) end)
    |> Enum.reduce_while({:ok, []}, fn {id, q}, {:ok, acc} ->
      case encode_question(to_string(id), q) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} ->
        body = %{input: encode_input(state), questions: Enum.reverse(encoded)}
        {:ok, if(model, do: Map.put(body, :model, model), else: body)}

      error ->
        error
    end
  end

  @doc """
  Converts a `/v1/decisions` response into the System One shape:
  `%{"answers" => %{id => raw_answer}, "model" => _, "usage" => _}`, ready for
  `SystemOneClient.Answer.parse_all/1`.
  """
  @spec decode_response(map()) :: {:ok, map()} | {:error, term()}
  def decode_response(%{"answers" => answers} = body) when is_list(answers) do
    Enum.reduce_while(answers, {:ok, %{}}, fn
      %{"name" => name} = answer, {:ok, acc} when is_binary(name) ->
        {:cont, {:ok, Map.put(acc, name, decode_answer(answer))}}

      answer, _acc ->
        {:halt, {:error, {:unnamed_answer, answer}}}
    end)
    |> case do
      {:ok, decoded} ->
        {:ok, %{"answers" => decoded, "model" => body["model"], "usage" => body["usage"]}}

      error ->
        error
    end
  end

  def decode_response(_body), do: {:error, :no_answers}

  # -- request ----------------------------------------------------------------

  defp encode_question(name, q) when is_map(q) do
    type = q |> get(:type) |> to_string()
    instructions = text(get(q, :instructions) || "")
    criteria = get(q, :criteria)

    case type do
      "noul" ->
        {:ok,
         %{
           type: "predicate",
           name: name,
           instructions: predicate_instructions(instructions, criteria)
         }}

      "choice" ->
        case choices(criteria) do
          [] ->
            {:error, {:invalid_question, name, :missing_criteria}}

          choices ->
            {:ok, %{type: "choice", name: name, instructions: instructions, choices: choices}}
        end

      "score" ->
        case levels(criteria) do
          [] ->
            {:error, {:invalid_question, name, :missing_criteria}}

          levels ->
            {:ok, %{type: "score", name: name, instructions: instructions, levels: levels}}
        end

      _ ->
        {:error, {:invalid_question, name, :unknown_type}}
    end
  end

  defp encode_question(name, _q), do: {:error, {:invalid_question, name, :not_a_map}}

  defp predicate_instructions(instructions, criteria) when is_map(criteria) do
    true_when = get(criteria, true)
    false_when = get(criteria, false)

    [
      instructions,
      true_when && "True when: " <> text(true_when),
      false_when && "False when: " <> text(false_when)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp predicate_instructions(instructions, _criteria), do: instructions

  defp choices(criteria) when is_map(criteria) do
    criteria
    |> Enum.sort_by(fn {value, _} -> to_string(value) end)
    |> Enum.map(fn
      {value, nil} -> %{value: to_string(value)}
      {value, description} -> %{value: to_string(value), description: text(description)}
    end)
  end

  defp choices(criteria) when is_list(criteria), do: Enum.map(criteria, &%{value: to_string(&1)})
  defp choices(_), do: []

  defp levels(criteria) when is_list(criteria) do
    criteria
    |> Enum.with_index()
    |> Enum.map(fn {description, i} -> %{label: "Level #{i}", description: text(description)} end)
  end

  defp levels(_), do: []

  defp encode_input(state) when is_binary(state), do: state
  defp encode_input(state), do: Jason.encode!(state)

  defp text(value) when is_binary(value), do: value
  defp text(value), do: Jason.encode!(value)

  # Question maps may use string or atom keys ("type" / :type, "true" / :true).
  defp get(map, key) when is_atom(key), do: Map.get(map, Atom.to_string(key), Map.get(map, key))

  # -- response ---------------------------------------------------------------

  defp decode_answer(%{"type" => "predicate", "probability" => p}),
    do: %{"type" => "noul", "noul" => p}

  defp decode_answer(%{"type" => "choice"} = a) do
    %{
      "type" => "choice",
      "choice" => stringify(a["choice"]),
      "probabilities" => probability_map(a["probabilities"]),
      "confidence" => a["confidence"]
    }
  end

  defp decode_answer(%{"type" => "score"} = a) do
    rows = List.wrap(a["probabilities"])

    %{
      "type" => "score",
      "score" => a["score"],
      "probabilities" => probability_map(rows),
      "legend" => Map.new(rows, fn row -> {stringify(row["value"]), row["label"]} end),
      "confidence" => a["confidence"]
    }
  end

  defp decode_answer(%{"type" => "refusal"}), do: %{"type" => "refusal"}
  defp decode_answer(answer), do: Map.delete(answer, "name")

  defp probability_map(rows) when is_list(rows),
    do: Map.new(rows, fn row -> {stringify(row["value"]), row["probability"]} end)

  defp probability_map(_), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
