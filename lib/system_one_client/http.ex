defmodule SystemOneClient.HTTP do
  @moduledoc """
  Real `SystemOneClient` implementation over Req.

  Retries 429, 529, 502, 503 and 504 responses and transport errors up to `:max_retries`
  (default 2), waiting for `Retry-After` when the server sends one and otherwise backing
  off exponentially from `:retry_delay_ms` (default 250). `:receive_timeout` defaults to
  2 s. Never raises for network conditions and never puts the key into a returned term or
  a telemetry event.

  Telemetry: `[:system_one_client, :request, :start | :stop | :exception]` with
  `provider`, `model` and `question_count`; `stop` adds `status` (`:ok` | `:error`),
  `latency_ms`, and on error an `error` kind. State, questions and keys are never included.
  """
  @behaviour SystemOneClient

  alias SystemOneClient.{Answer, Provider}

  @retry_statuses [429, 529, 502, 503, 504]

  @impl true
  def evaluate(state, questions, opts \\ []) do
    with :ok <- SystemOneClient.validate_questions(questions),
         {:ok, p} <- Provider.resolve(opts) do
      meta = %{provider: p.provider, model: p.model, question_count: map_size(questions)}

      :telemetry.span([:system_one_client, :request], meta, fn ->
        t0 = System.monotonic_time(:millisecond)
        result = request_with_retries(p, state, questions, opts)
        latency = System.monotonic_time(:millisecond) - t0

        case result do
          {:ok, answers, resp} ->
            model = resp["model"] || p.model

            {{:ok, answers,
              %{model: model, usage: resp["usage"], latency_ms: latency, provider: p.provider}},
             Map.merge(meta, %{status: :ok, model: model, latency_ms: latency})}

          {:error, reason} ->
            {{:error, reason},
             Map.merge(meta, %{status: :error, latency_ms: latency, error: error_kind(reason)})}
        end
      end)
    end
  end

  defp request_with_retries(p, state, questions, opts) do
    max_retries = Keyword.get(opts, :max_retries, 2)
    base = Keyword.get(opts, :retry_delay_ms, 250)

    req =
      Req.new(
        url: p.url,
        json: %{state: state, questions: questions} |> maybe_put(:model, p.model),
        receive_timeout: Keyword.get(opts, :receive_timeout, 2_000),
        retry: false
      )
      |> maybe_auth(p.auth)
      |> maybe_plug(Keyword.get(opts, :plug))

    attempt(req, p, 0, max_retries, base)
  end

  defp attempt(req, p, n, max_retries, base) do
    case Req.post(req) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        with {:ok, inner} <- Provider.unwrap(p.envelope, body),
             {:ok, answers} <- parse_answers(inner) do
          {:ok, answers, inner}
        end

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, {:malformed_answers, {:not_json, body}}}

      {:ok, %Req.Response{status: status} = resp}
      when status in @retry_statuses and n < max_retries ->
        Process.sleep(retry_after_ms(resp) || base * Integer.pow(2, n))
        attempt(req, p, n + 1, max_retries, base)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, %Req.TransportError{}} when n < max_retries ->
        Process.sleep(base * Integer.pow(2, n))
        attempt(req, p, n + 1, max_retries, base)

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, reason}}

      {:error, other} ->
        {:error, {:transport, other}}
    end
  end

  # Retry-After may be seconds (RFC) or, from some providers, retry-after-ms.
  defp retry_after_ms(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "retry-after-ms") do
      [ms | _] ->
        parse_int(ms)

      [] ->
        case Req.Response.get_header(resp, "retry-after") do
          [s | _] -> parse_int(s) && parse_int(s) * 1000
          [] -> nil
        end
    end
  end

  defp parse_int(s) do
    case Integer.parse(String.trim(s)) do
      {i, ""} when i >= 0 -> i
      _ -> nil
    end
  end

  defp parse_answers(%{"answers" => raw}) do
    case Answer.parse_all(raw) do
      {:ok, answers} -> {:ok, answers}
      {:error, reason} -> {:error, {:malformed_answers, reason}}
    end
  end

  defp parse_answers(_), do: {:error, {:malformed_answers, :no_answers}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_auth(req, nil), do: req
  defp maybe_auth(req, auth), do: Req.merge(req, auth: auth)

  defp maybe_plug(req, nil), do: req
  defp maybe_plug(req, plug), do: Req.merge(req, plug: plug)

  defp error_kind({:http, status, _}), do: {:http, status}
  defp error_kind({:transport, _}), do: :transport
  defp error_kind({:malformed_answers, _}), do: :malformed_answers
  defp error_kind({:provider_error, _}), do: :provider_error
  defp error_kind({:malformed_envelope, _}), do: :malformed_envelope
  defp error_kind(other), do: other |> inspect(limit: 3, printable_limit: 40)
end
