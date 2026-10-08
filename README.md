# SystemOneClient

Elixir client for System One decision models: [TypeSafe Jev](https://docs.typesafe.ai),
[Cloudflare Clef](https://developers.cloudflare.com/workers-ai/models/clef/),
[OpenRouter's decisions endpoint](https://openrouter.ai), and anything self-hosted that
speaks the `/v1/systemone` wire format (for example [CLM](https://github.com/Contrastive-LM/CLM)).

You send a `state` (any JSON) and a map of typed questions; you get back typed answers with
their **full probability distributions**, never collapsed to a single pick. That is what a
router or a gate needs: top-k over a Choice, a threshold on a Noul, a level cut on a Score.

- One behaviour, `SystemOneClient`, with `evaluate(state, questions, opts)`.
- `SystemOneClient.HTTP` for real calls; `SystemOneClient.Stub` for tests, no network.
- Four providers behind one option; `url:` and `model:` override any of them.
- Retries on 429, 529, 502, 503, 504 and transport errors, honouring `Retry-After`.
- Never raises for network conditions; tagged error tuples at the boundary.
- Telemetry without leaking state, questions, or keys.
- Depends on `req`, `jason`, `telemetry` only. Apache 2.0.

## Install

```elixir
def deps do
  [{:system_one_client, "~> 0.1"}]
end
```

## Use

```elixir
questions = %{
  "needs_tool" => %{
    "type" => "noul",
    "instructions" => "Does the next step need one of the actions in `available_actions`?"
  },
  "tool" => %{
    "type" => "choice",
    "instructions" => "Which action should run next to make progress on `request`?",
    "criteria" => %{"add" => "Adds two numbers", "gcd" => "Greatest common divisor", "none" => "No action fits"}
  },
  "depth" => %{
    "type" => "score",
    "instructions" => "How much reasoning does `request` need?",
    "criteria" => ["One direct step", "A few dependent steps", "A long chain or a known trap"]
  }
}

state = %{request: "what is the gcd of 1071 and 462", available_actions: ["add", "gcd"]}

{:ok, answers, meta} = SystemOneClient.evaluate(state, questions)

answers["tool"]
#=> %SystemOneClient.Answer.Choice{choice: "gcd", confidence: 0.97,
#     probabilities: %{"gcd" => 0.97, "add" => 0.02, "none" => 0.01}}
answers["needs_tool"]   #=> %SystemOneClient.Answer.Noul{noul: 0.96}
answers["depth"]        #=> %SystemOneClient.Answer.Score{score: 0.1, probabilities: %{...}, confidence: 0.9, legend: ...}
meta                    #=> %{model: "jev-1.13.0", usage: %{...}, latency_ms: 134, provider: :typesafe}
```

Question maps are the API's wire format verbatim; this library adds no schema of its own.
See TypeSafe's [primitives](https://docs.typesafe.ai/primitives) for `noul`, `choice`
and `score`.

## Providers

| `provider:` | Endpoint | Key | Default model |
| --- | --- | --- | --- |
| `:typesafe` (default) | `https://api.typesafe.ai/v1/systemone` | `api_key:` or `TYPESAFE_API_KEY` | `jev-latest` |
| `:cloudflare` | `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run/@cf/cloudflare/clef` | `api_key:` or `CLOUDFLARE_API_TOKEN`; `account_id:` or `CLOUDFLARE_ACCOUNT_ID` | `clef` (`model: "clef-flash"` for the 9B) |
| `:openrouter` | `https://openrouter.ai/api/alpha/decisions` | `api_key:` or `OPENROUTER_API_KEY` | `typesafe/jev-1.13` |
| `:compatible` | `url:` (required) | optional | none |

```elixir
SystemOneClient.evaluate(state, questions, provider: :cloudflare, model: "clef-flash")
SystemOneClient.evaluate(state, questions, provider: :compatible, url: "http://localhost:8700/v1/systemone")
```

Cloudflare's `result` envelope is unwrapped for you; a failed envelope returns
`{:error, {:provider_error, errors}}`.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `provider` | `:typesafe` | see above |
| `api_key`, `account_id`, `url`, `model` | provider defaults | explicit values always win |
| `receive_timeout` | `2_000` ms | per attempt |
| `max_retries` | `2` | on 429, 529, 502, 503, 504 and transport errors |
| `retry_delay_ms` | `250` | base of the exponential backoff; `Retry-After` / `retry-after-ms` win when present |
| `client` | app env `:client`, else `HTTP` | implementation module (use `SystemOneClient.Stub` in tests) |
| `plug` | none | Req plug, for `Req.Test` in your own tests |
| `env` | `System.get_env()` | replace the environment (tests) |

Errors are tagged tuples:

```elixir
{:error, :missing_api_key | :missing_account_id | :missing_url | {:unknown_provider, p}}
{:error, {:invalid_question, id, reason}}
{:error, {:http, status, body} | {:transport, reason}}
{:error, {:malformed_answers, reason} | {:provider_error, errors}}
```

## Testing your code

```elixir
# config/test.exs
config :system_one_client, client: SystemOneClient.Stub

# in a test
alias SystemOneClient.Answer.{Choice, Noul}

{:ok, answers, _} =
  SystemOneClient.evaluate(state, questions,
    answers: %{
      "needs_tool" => %Noul{noul: 0.9},
      "tool" => %Choice{choice: "gcd", probabilities: %{"gcd" => 0.9, "add" => 0.1}, confidence: 0.9}
    })
```

`answers:` takes a map (structs or raw API maps) or a `fn state, questions -> map | {:error, _} end`.
For HTTP-level tests pass `plug: {Req.Test, MyTest}` and stub with `Req.Test.stub/2`.

## Telemetry

`[:system_one_client, :request, :start | :stop | :exception]` via `:telemetry.span/3`.
Metadata: `provider`, `model`, `question_count`; on `:stop` also `status` (`:ok` | `:error`),
`latency_ms`, and `error` (a kind such as `{:http, 429}` or `:transport`). State, question
text, bodies and keys are never included.

## Origin

Extracted from an experiment that used Jev as a tool and model router inside a
[Jido](https://github.com/agentjido/jido) AI agent; the experiment, its benchmarks and the
transformer that consumes this client live on
[schainks/jido, branch `experiment/jev-tool-routing`](https://github.com/schainks/jido/tree/experiment/jev-tool-routing).

## Running the tests

With Elixir installed: `mix test`. Without: `./run.sh test` runs them in the
`hexpm/elixir:1.20.4` Docker image.
