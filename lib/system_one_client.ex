defmodule SystemOneClient do
  @moduledoc """
  Client for System One decision models: TypeSafe Jev, Cloudflare Clef, OpenAI's Decisions
  API, OpenRouter's decisions endpoint, and any self-hosted `/v1/systemone` server such as CLM.

  Ask typed questions (`noul`, `choice`, `score`) about arbitrary JSON state and get
  typed answers back with their full probability distributions. `SystemOneClient.HTTP`
  talks to a provider (see `SystemOneClient.Provider`); `SystemOneClient.Stub` returns
  canned answers for tests. Question maps follow the API wire shape verbatim; this
  library does not invent its own schema for them.

      {:ok, answers, meta} = SystemOneClient.evaluate(state, questions, provider: :cloudflare)
      answers["tool"].probabilities
  """

  alias SystemOneClient.{Answer, Provider}

  @typedoc "A question id. Answers are keyed by its string form."
  @type question_id :: String.t() | atom()

  @typedoc """
  A question in the System One wire format, for example
  `%{"type" => "choice", "instructions" => "...", "criteria" => %{"a" => "...", "b" => "..."}}`.
  Keys may be strings or atoms.
  """
  @type question :: map()

  @type questions :: %{question_id() => question()}
  @type answers :: %{String.t() => Answer.t()}

  @type meta :: %{
          optional(:provider) => Provider.name(),
          model: String.t() | nil,
          usage: map() | nil,
          latency_ms: non_neg_integer()
        }

  @typedoc "Options accepted by `evaluate/3`. See the README for defaults."
  @type option ::
          {:client, module()}
          | {:provider, Provider.name()}
          | {:api_key, String.t() | nil}
          | {:account_id, String.t()}
          | {:url, String.t()}
          | {:model, String.t()}
          | {:receive_timeout, timeout()}
          | {:max_retries, non_neg_integer()}
          | {:retry_delay_ms, non_neg_integer()}
          | {:plug, term()}
          | {:env, %{optional(String.t()) => String.t()}}
          | {:answers, map() | (term(), questions() -> map() | {:error, term()})}
          | {:images, [String.t()]}

  @type options :: [option()]

  @typedoc "Errors returned by `SystemOneClient.HTTP`."
  @type error ::
          :missing_api_key
          | :missing_account_id
          | :missing_url
          | {:unknown_provider, term()}
          | {:invalid_question, String.t(), :unknown_type | :not_a_map | :missing_criteria}
          | {:http, non_neg_integer(), term()}
          | {:transport, term()}
          | {:malformed_answers, term()}
          | {:malformed_envelope, term()}
          | {:provider_error, list()}
          | SystemOneClient.Images.error()

  @callback evaluate(state :: term(), questions :: questions(), opts :: options()) ::
              {:ok, answers(), meta()} | {:error, term()}

  @valid_types ~w(noul choice score)

  @doc "Evaluates questions with the configured client (`opts[:client]`, else app env `:client`, else HTTP)."
  @spec evaluate(term(), questions(), options()) :: {:ok, answers(), meta()} | {:error, term()}
  def evaluate(state, questions, opts \\ []) do
    {client, opts} =
      Keyword.pop(
        opts,
        :client,
        Application.get_env(:system_one_client, :client, SystemOneClient.HTTP)
      )

    client.evaluate(state, questions, opts)
  end

  @doc """
  Builds a base64 data URL for the `images:` option from image bytes.

      iex> SystemOneClient.image_data_url("abc", "image/png")
      "data:image/png;base64,YWJj"

  Raises `ArgumentError` if `media_type` is not an `image/*` type.
  """
  @spec image_data_url(binary(), String.t()) :: String.t()
  def image_data_url(bytes, "image/" <> _ = media_type) when is_binary(bytes),
    do: "data:#{media_type};base64," <> Base.encode64(bytes)

  def image_data_url(_bytes, media_type),
    do: raise(ArgumentError, "expected an image/* media type, got: #{inspect(media_type)}")

  @doc """
  Checks every question has a known `type`. Ids may be atoms or strings.

      iex> SystemOneClient.validate_questions(%{"q" => %{"type" => "noul", "instructions" => "?"}})
      :ok

      iex> SystemOneClient.validate_questions(%{"q" => %{"type" => "guess"}})
      {:error, {:invalid_question, "q", :unknown_type}}
  """
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
