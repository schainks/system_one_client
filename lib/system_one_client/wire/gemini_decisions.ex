defmodule SystemOneClient.Wire.GeminiDecisions do
  @moduledoc """
  Request translation for Google's Gemini Decisions API (`POST /v1beta/decisions`).

  Gemini's format is close to System One: questions are a map of id to `noul` / `choice`
  / `score`, and answers come back as a map under the same ids with probabilities as
  maps. The response needs no translation, so only the request is mapped:

  | System One | Gemini Decisions |
  | --- | --- |
  | `state` (any JSON) | `input` (text; non-string state is JSON-encoded) |
  | `images:` option | `image` blocks (`data`, `mime_type`), then the state as a `text` block |
  | `noul` criteria `true` / `false` | `criteria: %{true_description, false_description}` |
  | `choice` `criteria: %{value => description}` | the same; a missing description is `""` |
  | `score` `criteria: [description]` | the same |

  Non-string instructions and descriptions (System One allows objects and arrays) are
  JSON-encoded, since Gemini expects text.
  """

  @doc """
  Builds the `/v1beta/decisions` request body.

      iex> {:ok, body} =
      ...>   SystemOneClient.Wire.GeminiDecisions.encode_request(
      ...>     "I was charged twice.",
      ...>     %{"urgent" => %{"type" => "noul", "instructions" => "Is this urgent?"}},
      ...>     "gemini-decision-1"
      ...>   )
      iex> body
      %{
        model: "gemini-decision-1",
        input: "I was charged twice.",
        questions: %{"urgent" => %{type: "noul", instructions: "Is this urgent?"}}
      }
  """
  @spec encode_request(term(), map(), String.t() | nil, [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def encode_request(state, questions, model, images \\ []) do
    questions
    |> Enum.reduce_while({:ok, %{}}, fn {id, q}, {:ok, acc} ->
      id = to_string(id)

      case encode_question(id, q) do
        {:ok, encoded} -> {:cont, {:ok, Map.put(acc, id, encoded)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} ->
        body = %{input: encode_input(state, images), questions: encoded}
        {:ok, if(model, do: Map.put(body, :model, model), else: body)}

      error ->
        error
    end
  end

  defp encode_question(id, q) when is_map(q) do
    type = q |> get(:type) |> to_string()
    base = %{type: type, instructions: text(get(q, :instructions) || "")}

    case criteria(type, get(q, :criteria)) do
      {:ok, nil} -> {:ok, base}
      {:ok, criteria} -> {:ok, Map.put(base, :criteria, criteria)}
      {:error, reason} -> {:error, {:invalid_question, id, reason}}
    end
  end

  defp encode_question(id, _q), do: {:error, {:invalid_question, id, :not_a_map}}

  defp criteria("noul", criteria) when is_map(criteria) do
    described =
      %{
        true_description: get(criteria, true) || get(criteria, :true_description),
        false_description: get(criteria, false) || get(criteria, :false_description)
      }
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
      |> Map.new(fn {k, v} -> {k, text(v)} end)

    {:ok, if(described == %{}, do: nil, else: described)}
  end

  defp criteria("noul", _criteria), do: {:ok, nil}

  defp criteria("choice", criteria) when is_map(criteria) and map_size(criteria) > 0,
    do: {:ok, Map.new(criteria, fn {value, d} -> {to_string(value), description(d)} end)}

  defp criteria("choice", [_ | _] = criteria),
    do: {:ok, Map.new(criteria, &{to_string(&1), ""})}

  defp criteria("score", [_ | _] = criteria), do: {:ok, Enum.map(criteria, &text/1)}

  defp criteria(type, _criteria) when type in ["choice", "score"], do: {:error, :missing_criteria}
  defp criteria(_type, _criteria), do: {:error, :unknown_type}

  defp description(nil), do: ""
  defp description(value), do: text(value)

  defp encode_input(state, images) when images in [nil, []], do: text(state)

  # Images first, then the state as text: the same order OpenAI and Clef get.
  defp encode_input(state, images) do
    blocks = Enum.map(images, &image_block/1)
    if state in [nil, ""], do: blocks, else: blocks ++ [%{type: "text", text: text(state)}]
  end

  # `SystemOneClient.Images.validate/2` has already checked these are base64 data URLs.
  defp image_block("data:" <> rest) do
    [mime_type, data] = String.split(rest, ";base64,", parts: 2)
    %{type: "image", data: data, mime_type: String.downcase(mime_type)}
  end

  defp text(value) when is_binary(value), do: value
  defp text(value), do: Jason.encode!(value)

  # Question maps may use string or atom keys ("type" / :type, "true" / :true).
  defp get(map, key) when is_atom(key), do: Map.get(map, Atom.to_string(key), Map.get(map, key))
end
