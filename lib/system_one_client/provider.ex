defmodule SystemOneClient.Provider do
  @moduledoc """
  Resolves where a request goes and how its response is shaped.

  | provider | endpoint | auth | default model | envelope |
  | --- | --- | --- | --- | --- |
  | `:typesafe` (default) | `https://api.typesafe.ai/v1/systemone` | `TYPESAFE_API_KEY` | `jev-latest` | top level |
  | `:cloudflare` | `.../accounts/{account_id}/ai/run/@cf/cloudflare/clef` | `CLOUDFLARE_API_TOKEN` | `@cf/cloudflare/clef` | `result` |
  | `:openrouter` | `https://openrouter.ai/api/alpha/decisions` | `OPENROUTER_API_KEY` | `typesafe/jev-1.13` | top level |
  | `:openai` | `https://api.openai.com/v1/decisions` | `OPENAI_API_KEY` | `gpt-6-luna` | translated (see `SystemOneClient.Wire.OpenAIDecisions`) |
  | `:gemini` | `https://generativelanguage.googleapis.com/v1beta/decisions` | `GEMINI_API_KEY`, sent as `x-goog-api-key` | `gemini-decision-1` | top level (request translated, see `SystemOneClient.Wire.GeminiDecisions`) |
  | `:flide` | `http://localhost:8000/v1/systemone` | optional | none (the server's own) | top level |
  | `:compatible` | `url:` (required) | optional | none | top level |

  `url:` and `model:` options always win over provider defaults. Keys come from `api_key:`
  or the provider's environment variable; `env:` can replace the environment in tests.
  """

  @type name :: :typesafe | :cloudflare | :openai | :openrouter | :gemini | :flide | :compatible
  @type envelope :: :top_level | :cloudflare_result
  @type wire :: :system_one | :openai_decisions | :gemini_decisions
  @type auth :: {:bearer, String.t()} | {:header, String.t(), String.t()}
  @type t :: %{
          provider: name(),
          url: String.t(),
          auth: auth() | nil,
          model: String.t() | nil,
          envelope: envelope(),
          wire: wire()
        }

  @typesafe_url "https://api.typesafe.ai/v1/systemone"
  @openrouter_url "https://openrouter.ai/api/alpha/decisions"
  @openai_url "https://api.openai.com/v1/decisions"
  @gemini_url "https://generativelanguage.googleapis.com/v1beta/decisions"
  @flide_url "http://localhost:8000/v1/systemone"
  @cloudflare_base "https://api.cloudflare.com/client/v4/accounts"

  # Hosted providers that differ only in endpoint, key variable, default model and wire.
  @hosted %{
    typesafe: %{
      url: @typesafe_url,
      key_env: "TYPESAFE_API_KEY",
      model: "jev-latest",
      wire: :system_one
    },
    openrouter: %{
      url: @openrouter_url,
      key_env: "OPENROUTER_API_KEY",
      model: "typesafe/jev-1.13",
      wire: :system_one
    },
    openai: %{
      url: @openai_url,
      key_env: "OPENAI_API_KEY",
      model: "gpt-6-luna",
      wire: :openai_decisions
    },
    gemini: %{
      url: @gemini_url,
      key_env: "GEMINI_API_KEY",
      model: "gemini-decision-1",
      wire: :gemini_decisions,
      auth_header: "x-goog-api-key"
    }
  }

  @doc """
  Resolves the endpoint, auth, default model, envelope and wire format for a request.

      iex> {:ok, p} = SystemOneClient.Provider.resolve(provider: :openai, api_key: "sk-test")
      iex> {p.url, p.model, p.wire}
      {"https://api.openai.com/v1/decisions", "gpt-6-luna", :openai_decisions}

      iex> SystemOneClient.Provider.resolve(provider: :typesafe, env: %{})
      {:error, :missing_api_key}

      iex> {:ok, p} = SystemOneClient.Provider.resolve(provider: :gemini, api_key: "g-test")
      iex> {p.model, p.wire, p.auth}
      {"gemini-decision-1", :gemini_decisions, {:header, "x-goog-api-key", "g-test"}}
  """
  @spec resolve(SystemOneClient.options()) ::
          {:ok, t()}
          | {:error,
             :missing_api_key | :missing_account_id | :missing_url | {:unknown_provider, term()}}
  def resolve(opts) do
    env = Keyword.get(opts, :env) || System.get_env()
    resolve(Keyword.get(opts, :provider, :typesafe), opts, env, Keyword.get(opts, :api_key))
  end

  defp resolve(provider, opts, env, key) when is_map_key(@hosted, provider) do
    spec = Map.fetch!(@hosted, provider)

    with {:ok, k} <- require_key(key, env[spec.key_env]) do
      auth = if header = spec[:auth_header], do: {:header, header, k}, else: {:bearer, k}

      {:ok,
       opts
       |> build(provider, spec.url, auth, spec.model, :top_level)
       |> Map.put(:wire, spec.wire)}
    end
  end

  defp resolve(:cloudflare, opts, env, key) do
    account = Keyword.get(opts, :account_id) || env["CLOUDFLARE_ACCOUNT_ID"]
    model = cloudflare_model(Keyword.get(opts, :model, "clef"))

    with {:ok, k} <- require_key(key, env["CLOUDFLARE_API_TOKEN"]),
         {:ok, acc} <- required(account, :missing_account_id) do
      url = "#{@cloudflare_base}/#{acc}/ai/run/#{model}"
      opts = Keyword.delete(opts, :model)
      {:ok, build(opts, :cloudflare, url, {:bearer, k}, model, :cloudflare_result)}
    end
  end

  # A Flide server has no auth of its own and serves one model, so both are optional.
  defp resolve(:flide, opts, _env, key),
    do: {:ok, build(opts, :flide, @flide_url, optional_bearer(key), nil, :top_level)}

  defp resolve(:compatible, opts, _env, key) do
    with {:ok, url} <- required(Keyword.get(opts, :url), :missing_url) do
      {:ok, build(opts, :compatible, url, optional_bearer(key), nil, :top_level)}
    end
  end

  defp resolve(other, _opts, _env, _key), do: {:error, {:unknown_provider, other}}

  @doc "Extracts the System One body from a provider's response envelope."
  @spec unwrap(envelope(), map()) :: {:ok, map()} | {:error, term()}
  def unwrap(:top_level, body) when is_map(body), do: {:ok, body}

  def unwrap(:cloudflare_result, %{"success" => true, "result" => result}) when is_map(result),
    do: {:ok, result}

  def unwrap(:cloudflare_result, %{"errors" => errors}) when is_list(errors) and errors != [],
    do: {:error, {:provider_error, errors}}

  def unwrap(:cloudflare_result, body), do: {:error, {:malformed_envelope, body}}

  defp build(opts, provider, url, auth, model, envelope) do
    %{
      provider: provider,
      url: Keyword.get(opts, :url, url),
      auth: auth,
      model: Keyword.get(opts, :model, model),
      envelope: envelope,
      wire: :system_one
    }
  end

  defp cloudflare_model("@cf/" <> _ = full), do: full
  defp cloudflare_model(short) when is_binary(short), do: "@cf/cloudflare/#{short}"

  defp optional_bearer(key) when is_binary(key) and key != "", do: {:bearer, key}
  defp optional_bearer(_key), do: nil

  defp require_key(explicit, from_env) do
    case explicit || from_env do
      k when is_binary(k) and k != "" -> {:ok, k}
      _ -> {:error, :missing_api_key}
    end
  end

  defp required(value, error) do
    case value do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, error}
    end
  end
end
