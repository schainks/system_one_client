defmodule SystemOneClient.HTTP do
  @moduledoc "Real `SystemOneClient` implementation over Req. Never logs the key."
  @behaviour SystemOneClient

  alias SystemOneClient.Answer

  @url "https://api.typesafe.ai/v1/systemone"
  @default_model "jev-latest"

  @impl true
  def evaluate(state, questions, opts \\ []) do
    with :ok <- SystemOneClient.validate_questions(questions),
         {:ok, key} <- api_key(opts) do
      body = %{
        state: state,
        model: Keyword.get(opts, :model, @default_model),
        questions: questions
      }

      max_retries = Keyword.get(opts, :max_retries, 2)
      delay = Keyword.get(opts, :retry_delay_ms, 250)

      req =
        Req.new(
          url: Keyword.get(opts, :url, @url),
          auth: {:bearer, key},
          json: body,
          receive_timeout: Keyword.get(opts, :receive_timeout, 2_000),
          retry: &retry?/2,
          max_retries: max_retries,
          retry_delay: fn n -> delay * Integer.pow(2, n) end,
          retry_log_level: false
        )
        |> maybe_plug(Keyword.get(opts, :plug))

      t0 = System.monotonic_time(:millisecond)

      case Req.post(req) do
        {:ok, %Req.Response{status: 200, body: %{"answers" => raw} = resp}} ->
          case Answer.parse_all(raw) do
            {:ok, answers} ->
              {:ok, answers,
               %{
                 model: resp["model"],
                 usage: resp["usage"],
                 latency_ms: System.monotonic_time(:millisecond) - t0
               }}

            {:error, reason} ->
              {:error, {:malformed_answers, reason}}
          end

        {:ok, %Req.Response{status: 200}} ->
          {:error, {:malformed_answers, :no_answers}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, %Req.TransportError{reason: reason}} ->
          {:error, {:transport, reason}}

        {:error, other} ->
          {:error, {:transport, other}}
      end
    end
  end

  defp retry?(_req, %Req.Response{status: s}) when s in [429, 529], do: true
  defp retry?(_req, %Req.TransportError{}), do: true
  defp retry?(_req, _), do: false

  defp maybe_plug(req, nil), do: req
  defp maybe_plug(req, plug), do: Req.merge(req, plug: plug)

  defp api_key(opts) do
    case Keyword.get(opts, :api_key, System.get_env("TYPESAFE_API_KEY")) do
      k when is_binary(k) and k != "" -> {:ok, k}
      _ -> {:error, :missing_api_key}
    end
  end
end
