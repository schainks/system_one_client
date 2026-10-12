# Changelog

## 0.2.0 (unreleased)

- `provider: :openai` for OpenAI's Decisions API (`POST /v1/decisions`, default model
  `gpt-6-luna`, `OPENAI_API_KEY`). Requests and responses are translated to and from the
  System One shape by `SystemOneClient.Wire.OpenAIDecisions`, so questions and answer
  structs are the same as for every other provider.
- `SystemOneClient.Answer.Refusal` for questions the model declines to answer.
- `SystemOneClient.Provider` results carry a `wire` field (`:system_one` or
  `:openai_decisions`).
- Typespecs for the public API, including `t:SystemOneClient.option/0`,
  `t:SystemOneClient.options/0`, `t:SystemOneClient.error/0` and
  `t:SystemOneClient.Provider.name/0`; checked with Dialyzer in CI.
- Doctests on `validate_questions/1`, `Answer.parse/1`, `Provider.resolve/1` and the
  OpenAI request encoder, and grouped modules in the docs.

## 0.1.0 (2026-10-08)

- `SystemOneClient` behaviour with `evaluate/3`, `validate_questions/1`, and a dispatcher
  that picks the implementation from `opts[:client]` or app env.
- `SystemOneClient.HTTP`: Req-based client with retries on 429/529/502/503/504 and transport
  errors, `Retry-After` and `retry-after-ms` support, 2 s default receive timeout.
- `SystemOneClient.Provider`: `:typesafe`, `:cloudflare` (Clef and Clef-flash, `result`
  envelope), `:openrouter`, `:compatible` (any `/v1/systemone` URL, e.g. CLM).
- `SystemOneClient.Answer.{Choice, Noul, Score}` with full probability distributions and
  validation of non-numeric probabilities and non-map answer payloads.
- `SystemOneClient.Stub` for offline tests.
- Telemetry `[:system_one_client, :request, *]` without state, questions, or keys.
