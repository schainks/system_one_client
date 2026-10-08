# Changelog

## 0.1.0 (unreleased)

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
