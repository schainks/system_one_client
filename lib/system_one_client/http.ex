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
  alias SystemOneClient.Wire.OpenAIDecisions

  @retry_statuses [429, 529, 502, 503, 504]

  @impl true
  def evaluate(state, questions, opts \\ []) do
    with :ok <- SystemOneClient.validate_questions(questions),
         {:ok, p} <- Provider.resolve(opts) do
      meta = %{provider: p.provider, model: p.model, question_count: map_size(questions)}

      :telemetry.span([:system_one_client, :request], meta, fn ->
        t0 = System.monotonic_time(:millisecond)
        result = request_with_retries(p, state, questions, opts)
        span_result(result, p, meta, System.monotonic_time(:millisecond) - t0)
      end)
    end
  end

  defp span_result({:ok, answers, resp}, p, meta, latency) do
    model = resp["model"] || p.model
    out = %{model: model, usage: resp["usage"], latency_ms: latency, provider: p.provider}
    {{:ok, answers, out}, Map.merge(meta, %{status: :ok, model: model, latency_ms: latency})}
  end

  defp span_result({:error, reason}, _p, meta, latency) do
    stop = %{status: :error, latency_ms: latency, error: error_kind(reason)}
    {{:error, reason}, Map.merge(meta, stop)}
  end

  defp request_with_retries(p, state, questions, opts) do
    case encode(p, state, questions) do
      {:ok, request_body} -> do_request(p, request_body, questions, opts)
      {:error, _} = error -> error
    end
  end

  defp encode(%{wire: :openai_decisions, model: model}, state, questions),
    do: OpenAIDecisions.encode_request(state, questions, model)

  defp encode(p, state, questions),
    do: {:ok, %{state: state, questions: questions} |> maybe_put(:model, p.model)}

  defp do_request(p, request_body, questions, opts) do
    max_retries = Keyword.get(opts, :max_retries, 2)
    base = Keyword.get(opts, :retry_delay_ms, 250)

    req =
      Req.new(
        url: p.url,
        json: request_body,
        receive_timeout: Keyword.get(opts, :receive_timeout, 2_000),
        retry: false
      )
      |> maybe_auth(p.auth)
      |> maybe_plug(Keyword.get(opts, :plug))

    attempt(req, p, questions, 0, max_retries, base)
  end

  defp attempt(req, p, questions, n, max_retries, base) do
    case classify(Req.post(req), p, questions) do
      {:retry, delay, _error} when n < max_retries ->
        Process.sleep(delay || base * Integer.pow(2, n))
        attempt(req, p, questions, n + 1, max_retries, base)

      {:retry, _delay, error} ->
        error

      {:done, result} ->
        result
    end
  end

  # {:done, result} or {:retry, retry_after_ms | nil, error_if_out_of_retries}
  defp classify({:ok, %Req.Response{status: 200, body: body}}, p, questions) when is_map(body),
    do: {:done, handle_success(body, p, questions)}

  defp classify({:ok, %Req.Response{status: 200, body: body}}, _p, _q),
    do: {:done, {:error, {:malformed_answers, {:not_json, body}}}}

  defp classify({:ok, %Req.Response{status: status, body: body} = resp}, _p, _q)
       when status in @retry_statuses,
       do: {:retry, retry_after_ms(resp), {:error, {:http, status, body}}}

  defp classify({:ok, %Req.Response{status: status, body: body}}, _p, _q),
    do: {:done, {:error, {:http, status, body}}}

  defp classify({:error, %Req.TransportError{reason: reason}}, _p, _q),
    do: {:retry, nil, {:error, {:transport, reason}}}

  defp classify({:error, other}, _p, _q), do: {:done, {:error, {:transport, other}}}

  defp handle_success(body, p, questions) do
    with {:ok, inner} <- Provider.unwrap(p.envelope, body),
         {:ok, inner} <- decode(p, inner, questions),
         {:ok, answers} <- parse_answers(inner) do
      {:ok, answers, inner}
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

  defp decode(%{wire: :openai_decisions}, body, questions) do
    case OpenAIDecisions.decode_response(body, questions) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:malformed_answers, reason}}
    end
  end

  defp decode(_p, body, _questions), do: {:ok, body}

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
