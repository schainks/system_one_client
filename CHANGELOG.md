# Changelog

## 0.3.0 (unreleased)

### Added

- `images:` option for image inputs with `provider: :openai` and `provider: :cloudflare`.
  Images are base64 data URLs; `SystemOneClient.image_data_url/2` builds one from bytes.
  OpenAI receives them as `input_image` parts before the state text; Clef receives its
  top-level `images` array. Both see the images before the state.
- `SystemOneClient.Images` validates images before any request: data URLs only (no remote
  URLs), plus Clef's limits of 4 PNG, JPEG or WebP images, 4 MiB each and 8 MiB in total.
  Other providers return `{:error, {:unsupported_option, :images, provider}}`.
- Telemetry metadata includes `image_count`.

## 0.2.0 (2026-10-12)

### Added

- `provider: :openai` for OpenAI's Decisions API (`POST /v1/decisions`, default model
  `gpt-6-luna`, `OPENAI_API_KEY`). Requests and responses are translated to and from the
  System One shape by `SystemOneClient.Wire.OpenAIDecisions`, so questions and answer
  structs are the same as for every other provider. Score legends carry your own level
  text, as with TypeSafe.
- `SystemOneClient.Answer.Refusal` for a question the model declines to answer; the other
  answers in the request are still returned.
- Typespecs for the public API, including `t:SystemOneClient.option/0`,
  `t:SystemOneClient.options/0`, `t:SystemOneClient.error/0` and
  `t:SystemOneClient.Provider.name/0`; checked with Dialyzer in CI.
- Doctests on `validate_questions/1`, `Answer.parse/1`, `Provider.resolve/1` and the
  OpenAI request encoder, and grouped modules in the docs.

### Changed

- `SystemOneClient.Provider` results carry a `wire` field (`:system_one` or
  `:openai_decisions`).
- The Hex package links to this changelog.

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
