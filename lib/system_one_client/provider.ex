defmodule SystemOneClient.Provider do
  @moduledoc """
  Resolves where a request goes and how its response is shaped.

  | provider | endpoint | auth | default model | envelope |
  | --- | --- | --- | --- | --- |
  | `:typesafe` (default) | `https://api.typesafe.ai/v1/systemone` | `TYPESAFE_API_KEY` | `jev-latest` | top level |
  | `:cloudflare` | `.../accounts/{account_id}/ai/run/@cf/cloudflare/clef` | `CLOUDFLARE_API_TOKEN` | `@cf/cloudflare/clef` | `result` |
  | `:openrouter` | `https://openrouter.ai/api/alpha/decisions` | `OPENROUTER_API_KEY` | `typesafe/jev-1.13` | top level |
  | `:compatible` | `url:` (required) | optional | none | top level |

  `url:` and `model:` options always win over provider defaults. Keys come from `api_key:`
  or the provider's environment variable; `env:` can replace the environment in tests.
  """

  @type envelope :: :top_level | :cloudflare_result
  @type t :: %{
          provider: atom(),
          url: String.t(),
          auth: {:bearer, String.t()} | nil,
          model: String.t() | nil,
          envelope: envelope()
        }

  @typesafe_url "https://api.typesafe.ai/v1/systemone"
  @openrouter_url "https://openrouter.ai/api/alpha/decisions"
  @cloudflare_base "https://api.cloudflare.com/client/v4/accounts"

  @spec resolve(keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(opts) do
    env = Keyword.get(opts, :env) || System.get_env()
    provider = Keyword.get(opts, :provider, :typesafe)
    key = Keyword.get(opts, :api_key)

    case provider do
      :typesafe ->
        with {:ok, k} <- require_key(key, env["TYPESAFE_API_KEY"]) do
          {:ok, build(opts, :typesafe, @typesafe_url, {:bearer, k}, "jev-latest", :top_level)}
        end

      :openrouter ->
        with {:ok, k} <- require_key(key, env["OPENROUTER_API_KEY"]) do
          {:ok,
           build(
             opts,
             :openrouter,
             @openrouter_url,
             {:bearer, k},
             "typesafe/jev-1.13",
             :top_level
           )}
        end

      :cloudflare ->
        account = Keyword.get(opts, :account_id) || env["CLOUDFLARE_ACCOUNT_ID"]
        model = cloudflare_model(Keyword.get(opts, :model, "clef"))

        with {:ok, k} <- require_key(key, env["CLOUDFLARE_API_TOKEN"]),
             {:ok, acc} <- required(account, :missing_account_id) do
          url = "#{@cloudflare_base}/#{acc}/ai/run/#{model}"

          {:ok,
           build(
             Keyword.delete(opts, :model),
             :cloudflare,
             url,
             {:bearer, k},
             model,
             :cloudflare_result
           )}
        end

      :compatible ->
        with {:ok, url} <- required(Keyword.get(opts, :url), :missing_url) do
          auth = if is_binary(key) and key != "", do: {:bearer, key}, else: nil
          {:ok, build(opts, :compatible, url, auth, Keyword.get(opts, :model), :top_level)}
        end

      other ->
        {:error, {:unknown_provider, other}}
    end
  end

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
      envelope: envelope
    }
  end

  defp cloudflare_model("@cf/" <> _ = full), do: full
  defp cloudflare_model(short) when is_binary(short), do: "@cf/cloudflare/#{short}"

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
