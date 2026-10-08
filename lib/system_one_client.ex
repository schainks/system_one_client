defmodule SystemOneClient do
  @moduledoc """
  Client for TypeSafe's System One API (Jev).

  Ask typed questions (`noul`, `choice`, `score`) about arbitrary JSON state and get
  probabilities back. `SystemOneClient.HTTP` talks to the API; `SystemOneClient.Stub`
  returns canned answers for tests. Question maps follow the API shape verbatim; this
  library does not invent its own schema for them.
  """

  alias SystemOneClient.Answer

  @type answers :: %{String.t() => Answer.t()}
  @type meta :: %{model: String.t() | nil, usage: map() | nil, latency_ms: non_neg_integer()}

  @callback evaluate(state :: term(), questions :: map(), opts :: keyword()) ::
              {:ok, answers(), meta()} | {:error, term()}

  @valid_types ~w(noul choice score)

  @doc "Evaluates questions with the configured client (`opts[:client]`, else app env `:client`, else HTTP)."
  @spec evaluate(term(), map(), keyword()) :: {:ok, answers(), meta()} | {:error, term()}
  def evaluate(state, questions, opts \\ []) do
    {client, opts} =
      Keyword.pop(
        opts,
        :client,
        Application.get_env(:system_one_client, :client, SystemOneClient.HTTP)
      )

    client.evaluate(state, questions, opts)
  end

  @doc "Checks every question has a known `type`. Ids may be atoms or strings."
  @spec validate_questions(map()) ::
          :ok | {:error, {:invalid_question, String.t(), :unknown_type | :not_a_map}}
  def validate_questions(questions) when is_map(questions) do
    Enum.reduce_while(questions, :ok, fn {id, q}, :ok ->
      type =
        if is_map(q), do: to_string(Map.get(q, "type") || Map.get(q, :type) || ""), else: nil

      cond do
        not is_map(q) -> {:halt, {:error, {:invalid_question, to_string(id), :not_a_map}}}
        type in @valid_types -> {:cont, :ok}
        true -> {:halt, {:error, {:invalid_question, to_string(id), :unknown_type}}}
      end
    end)
  end
end
