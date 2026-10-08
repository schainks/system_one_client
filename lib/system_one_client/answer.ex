defmodule SystemOneClient.Answer do
  @moduledoc "Typed answers returned by TypeSafe System One questions."

  defmodule Choice do
    @moduledoc "One option from a defined set, with the full probability distribution."
    @enforce_keys [:choice, :probabilities, :confidence]
    defstruct [:choice, :probabilities, :confidence]

    @type t :: %__MODULE__{
            choice: String.t(),
            probabilities: %{String.t() => float()},
            confidence: float()
          }
  end

  defmodule Noul do
    @moduledoc "Probability that a condition holds."
    @enforce_keys [:noul]
    defstruct [:noul]
    @type t :: %__MODULE__{noul: float()}
  end

  defmodule Score do
    @moduledoc "Probability-weighted position on ordered levels."
    @enforce_keys [:score, :probabilities, :confidence]
    defstruct [:score, :legend, :probabilities, :confidence]

    @type t :: %__MODULE__{
            score: float(),
            legend: map() | nil,
            probabilities: %{String.t() => float()},
            confidence: float()
          }
  end

  @type t :: Choice.t() | Noul.t() | Score.t()

  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%{"type" => "choice", "choice" => c, "probabilities" => p, "confidence" => conf})
      when is_binary(c) and is_map(p) and is_number(conf) do
    if numeric_map?(p),
      do: {:ok, %Choice{choice: c, probabilities: p, confidence: conf / 1}},
      else: {:error, {:malformed_answer, "choice"}}
  end

  def parse(%{"type" => "noul", "noul" => n}) when is_number(n),
    do: {:ok, %Noul{noul: n / 1}}

  def parse(%{"type" => "score", "score" => s, "probabilities" => p, "confidence" => conf} = a)
      when is_number(s) and is_map(p) and is_number(conf) do
    if numeric_map?(p),
      do:
        {:ok,
         %Score{
           score: s / 1,
           legend: Map.get(a, "legend"),
           probabilities: p,
           confidence: conf / 1
         }},
      else: {:error, {:malformed_answer, "score"}}
  end

  def parse(%{"type" => type}) when type in ["choice", "noul", "score"],
    do: {:error, {:malformed_answer, type}}

  def parse(%{"type" => type}), do: {:error, {:unknown_answer_type, type}}
  def parse(_), do: {:error, :malformed_answer}

  defp numeric_map?(p), do: Enum.all?(p, fn {_, v} -> is_number(v) end)

  @spec parse_all(%{String.t() => map()}) ::
          {:ok, %{String.t() => t()}} | {:error, {String.t(), term()} | :answers_not_a_map}
  def parse_all(answers) when not is_map(answers), do: {:error, :answers_not_a_map}

  def parse_all(answers) when is_map(answers) do
    Enum.reduce_while(answers, {:ok, %{}}, fn {id, raw}, {:ok, acc} ->
      case parse(raw) do
        {:ok, a} -> {:cont, {:ok, Map.put(acc, id, a)}}
        {:error, reason} -> {:halt, {:error, {id, reason}}}
      end
    end)
  end
end
