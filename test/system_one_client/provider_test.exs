defmodule SystemOneClient.ProviderTest do
  use ExUnit.Case, async: true
  alias SystemOneClient.Provider

  describe "resolve/1" do
    test "typesafe is the default: api.typesafe.ai, jev-latest, bearer from opts or env" do
      assert {:ok, p} = Provider.resolve(api_key: "k")
      assert p.provider == :typesafe
      assert p.url == "https://api.typesafe.ai/v1/systemone"
      assert p.model == "jev-latest"
      assert p.auth == {:bearer, "k"}
      assert p.envelope == :top_level
    end

    test "typesafe without a key is an error" do
      assert {:error, :missing_api_key} =
               Provider.resolve(provider: :typesafe, api_key: nil, env: %{})
    end

    test "cloudflare builds the account-scoped Workers AI url and unwraps result" do
      assert {:ok, p} =
               Provider.resolve(provider: :cloudflare, account_id: "acc123", api_key: "cf")

      assert p.url ==
               "https://api.cloudflare.com/client/v4/accounts/acc123/ai/run/@cf/cloudflare/clef"

      assert p.model == "@cf/cloudflare/clef"
      assert p.auth == {:bearer, "cf"}
      assert p.envelope == :cloudflare_result
    end

    test "cloudflare clef-flash via model option, and account id from env" do
      env = %{"CLOUDFLARE_ACCOUNT_ID" => "envacc", "CLOUDFLARE_API_TOKEN" => "envtok"}

      assert {:ok, p} = Provider.resolve(provider: :cloudflare, model: "clef-flash", env: env)

      assert p.url =~ "/accounts/envacc/ai/run/@cf/cloudflare/clef-flash"
      assert p.auth == {:bearer, "envtok"}
    end

    test "cloudflare without an account id is an error" do
      assert {:error, :missing_account_id} =
               Provider.resolve(provider: :cloudflare, api_key: "cf", env: %{})
    end

    test "openrouter decisions endpoint with its default model" do
      assert {:ok, p} = Provider.resolve(provider: :openrouter, api_key: "or")
      assert p.url == "https://openrouter.ai/api/alpha/decisions"
      assert p.model == "typesafe/jev-1.13"
      assert p.envelope == :top_level
    end

    test "compatible requires a url and accepts no key (self-hosted)" do
      assert {:ok, p} =
               Provider.resolve(
                 provider: :compatible,
                 url: "http://localhost:8700/v1/systemone",
                 env: %{}
               )

      assert p.auth == nil
      assert p.model == nil
      assert {:error, :missing_url} = Provider.resolve(provider: :compatible, env: %{})
    end

    test "explicit url and model always win" do
      assert {:ok, p} =
               Provider.resolve(
                 api_key: "k",
                 url: "https://proxy.example/s1",
                 model: "jev-2026-09"
               )

      assert p.url == "https://proxy.example/s1" and p.model == "jev-2026-09"
    end

    test "unknown provider is an error" do
      assert {:error, {:unknown_provider, :nope}} = Provider.resolve(provider: :nope)
    end
  end

  describe "unwrap/2" do
    test "top_level returns the body as is" do
      assert {:ok, %{"answers" => %{}}} = Provider.unwrap(:top_level, %{"answers" => %{}})
    end

    test "cloudflare_result unwraps a successful envelope and surfaces errors" do
      body = %{
        "success" => true,
        "errors" => [],
        "result" => %{"answers" => %{"q" => %{}}, "model" => "clef"}
      }

      assert {:ok, %{"answers" => %{"q" => %{}}, "model" => "clef"}} =
               Provider.unwrap(:cloudflare_result, body)

      failed = %{
        "success" => false,
        "errors" => [%{"code" => 7000, "message" => "No route"}],
        "result" => nil
      }

      assert {:error, {:provider_error, [%{"code" => 7000, "message" => "No route"}]}} =
               Provider.unwrap(:cloudflare_result, failed)
    end
  end
end
