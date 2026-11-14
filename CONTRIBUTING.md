# Contributing to SystemOneClient

Thanks for your interest in contributing. SystemOneClient is a small Elixir client for
System One decision models, and most contributions are one of three things: a bug fix, a
new provider, or better docs. This guide covers how to set up, what the code expects, and
how a change gets merged and released.

## Getting started

### Development environment

SystemOneClient needs Elixir `~> 1.18`. CI runs Elixir 1.18 on OTP 27 and Elixir 1.20 on
OTP 28 and 29, so code has to work on all three.

```bash
git clone https://github.com/schainks/system_one_client.git
cd system_one_client

mix deps.get
mix test
```

No API keys are needed. The test suite never touches the network.

If you do not have Elixir installed, `scripts/run.sh` runs any Mix task inside the
`hexpm/elixir` Docker image. It calls `sudo -n docker`, so it needs passwordless `sudo`
for Docker.

```bash
scripts/run.sh test
scripts/run.sh credo --strict
```

### Quality checks

CI runs the checks below on every pull request. Run them before you push:

```bash
mix format --check-formatted
mix deps.unlock --check-unused
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test
mix docs --warnings-as-errors
```

The first `mix dialyzer` run builds its PLT files in `priv/plts` and takes a few minutes.
Later runs are fast.

## Code organization

```
.
├── lib/
│   ├── system_one_client.ex          # Behaviour, dispatcher, validate_questions/1
│   └── system_one_client/
│       ├── answer.ex                 # Choice, Noul, Score and Refusal structs, parsing
│       ├── http.ex                   # Req client: retries, auth, telemetry
│       ├── images.ex                 # Image validation and per-provider limits
│       ├── provider.ex               # URL, key, model and wire format per provider
│       ├── stub.ex                   # Offline implementation for tests
│       └── wire/                     # Request and response translation
│           ├── gemini_decisions.ex
│           └── openai_decisions.ex
├── test/                             # Mirrors lib/
├── scripts/run.sh                    # Mix in Docker
└── mix.exs
```

How a request flows:

- **`SystemOneClient`** picks the implementation (`SystemOneClient.HTTP` by default,
  `SystemOneClient.Stub` in tests) and validates the questions.
- **`SystemOneClient.Provider`** turns `provider:` and the other options into a URL, an
  auth header, a default model and a wire format.
- **`SystemOneClient.Wire.*`** modules reshape the request, and the response if needed,
  for APIs that do not speak the System One format directly. Providers that do speak it
  need no wire module.
- **`SystemOneClient.Answer`** parses the response into typed structs.

## Development guidelines

### Code style

- Run `mix format` before you commit.
- Every module has a `@moduledoc`, and every public function has a `@doc` and a `@spec`.
  Dialyzer checks the specs in CI.
- Use doctests for short examples. A new module with doctests has to be listed in
  `test/system_one_client/doctest_test.exs`, or its examples never run.

### Error handling

- Return `{:ok, result}` or `{:error, reason}`. Reasons are tagged tuples a caller can
  match on, such as `{:http, 429, body}` or `{:invalid_question, id, :missing_criteria}`.
- Never raise for something the network or the provider did. Timeouts, bad status codes
  and malformed bodies all come back as `{:error, _}`.
- Validate before sending. A request that cannot succeed should fail locally without an
  HTTP call.
- A new error reason belongs in the `SystemOneClient.error/0` type and the README.

### Testing

- Tests mirror `lib/` and use `async: true`.
- No test makes a real network call. HTTP behaviour is tested with `Req.Test`: pass
  `plug: {Req.Test, __MODULE__}` and stub the response with `Req.Test.stub/2`. See
  `test/system_one_client/http_test.exs` for examples.
- Cover the error paths as well as the success path: bad input, non-2xx responses,
  transport errors and malformed bodies.
- To assert that nothing was sent, stub with `fn _conn -> flunk("must not send") end`.

### Privacy

Telemetry events and log lines never include the state, question text, request or
response bodies, or API keys. Keep it that way when you add metadata. Counts and provider
names are fine; content is not.

### Dependencies

The runtime dependencies are `req`, `jason` and `telemetry`. Open an issue before adding
another one.

## Adding a provider

Open an issue first with a link to the provider's API documentation, so the shape of the
change can be agreed before you write it. A provider pull request usually contains:

1. An entry in `SystemOneClient.Provider`: URL, environment variable for the key, default
   model, auth header and wire format. Explicit options always win over environment
   variables.
2. A `SystemOneClient.Wire.*` module, only if the API's request or response differs from
   the System One format. Questions and answer structs stay the same for every provider.
3. Image support in `SystemOneClient.Images`, if the provider accepts images: the allowed
   types and size limits, or `{:unsupported_option, :images, provider}` if it does not.
4. Tests for provider resolution, the wire format and the HTTP round trip.
5. A README section, a changelog entry, and in `mix.exs` the provider's name in the
   package description and any new module in the docs groups.
6. A note in the pull request saying whether the change was tested against the real
   service, with which model, and what was not covered. Unit tests prove the code matches
   our reading of the docs; only a live call proves the docs match the service.

Never commit an API key, and do not paste one into an issue or pull request. Remove keys
and account ids from any output you share.

## Commits

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>[optional scope]: <description>
```

| Type | Use for |
| --- | --- |
| `feat` | A new feature |
| `fix` | A bug fix |
| `docs` | Documentation only |
| `refactor` | A code change that neither fixes a bug nor adds a feature |
| `test` | Adding or correcting tests |
| `chore` | Build, dependencies, releases |
| `ci` | CI configuration |

```bash
git commit -m "feat(flide): read FLIDE_URL and FLIDE_API_KEY"
git commit -m "fix: rebuild OpenAI score legends from the caller's level text"
```

Nothing enforces this with a hook. It is a convention, and reviewers will ask for it.

## Pull requests

1. Branch from `main`.
2. Keep the change focused. One provider, one fix or one refactor per pull request.
3. Add tests for new behaviour, and update the README and moduledocs when behaviour
   changes.
4. Add a changelog entry (see below).
5. Run the quality checks.
6. Fill in the pull request template. It has three sections:
   - **Why**: the problem or motivation, with a link to the issue.
   - **What**: what changed, the decisions worth a reviewer's attention, and anything
     left out on purpose.
   - **Testing**: what you ran and the result, what was not tested, and how a reviewer
     can check the change by hand.

Pull requests are merged with a merge commit once CI is green and a maintainer has
reviewed them.

## Changelog and releases

`CHANGELOG.md` is written by hand, so do edit it. Add your entry under the topmost
version if its heading says `(unreleased)`. If the topmost version already has a date,
start a new section above it with the next version and `(unreleased)`, and set the same
version in `mix.exs`. While the library is below 1.0, a new feature bumps the minor
version and a fix bumps the patch version.

Write entries for someone who uses the library: what they can now do, or what changed
for them.

Maintainers cut releases. A release is a `chore: release X.Y.Z` pull request that dates
the changelog heading, followed by a `vX.Y.Z` tag, `mix hex.publish` and a GitHub release.

## Security

Do not open a public issue for a security problem. Report it privately through
[GitHub's vulnerability reporting](https://github.com/schainks/system_one_client/security/advisories/new).

## License

SystemOneClient is licensed under Apache-2.0. By contributing, you agree that your
contributions are licensed under the same terms.

## Questions

- [GitHub Issues](https://github.com/schainks/system_one_client/issues) for bugs,
  questions and proposals
- [Hex documentation](https://hexdocs.pm/system_one_client)

Thank you for contributing.
