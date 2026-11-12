defmodule SystemOneClient.HTTPTest do
  use ExUnit.Case, async: true
  alias SystemOneClient.Answer.Noul

  @questions %{"q" => %{"type" => "noul", "instructions" => "Is it urgent?"}}
  @opts [api_key: "test-key", plug: {Req.Test, __MODULE__}, max_retries: 2, retry_delay_ms: 0]

  test "posts state, model and questions with a bearer key and parses answers" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{"state" => %{"x" => 1}, "model" => "jev-latest", "questions" => %{"q" => _}} =
               Jason.decode!(body)

      Req.Test.json(conn, %{
        "model" => "jev-1.13.0",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 2},
        "answers" => %{"q" => %{"type" => "noul", "noul" => 0.8}}
      })
    end)

    assert {:ok, %{"q" => %Noul{noul: 0.8}}, meta} =
             SystemOneClient.HTTP.evaluate(%{x: 1}, @questions, @opts)

    assert meta.model == "jev-1.13.0"
    assert meta.usage["input_tokens"] == 10
    assert is_integer(meta.latency_ms)
  end

  test "retries 429 twice then errors" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 429, "slow down")
    end)

    assert {:error, {:http, 429, _}} = SystemOneClient.HTTP.evaluate("s", @questions, @opts)
    assert Agent.get(counter, & &1) == 3
  end

  test "returns http error with body on 4xx without retry" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 422, ~s({"error":"bad"}))
    end)

    assert {:error, {:http, 422, _}} = SystemOneClient.HTTP.evaluate("s", @questions, @opts)
    assert Agent.get(counter, & &1) == 1
  end

  test "returns transport error on connection failure" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, {:transport, :timeout}} =
             SystemOneClient.HTTP.evaluate("s", @questions, Keyword.put(@opts, :max_retries, 0))
  end

  test "rejects a question with an unknown type before sending" do
    bad = %{"q" => %{"type" => "guess", "instructions" => "?"}}

    assert {:error, {:invalid_question, "q", :unknown_type}} =
             SystemOneClient.HTTP.evaluate("s", bad, @opts)
  end

  test "returns an error when the key is missing" do
    assert {:error, :missing_api_key} =
             SystemOneClient.HTTP.evaluate("s", @questions,
               plug: {Req.Test, __MODULE__},
               api_key: nil
             )
  end

  test "returns an error, not a crash, when answers is null" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"answers" => nil}) end)

    assert {:error, {:malformed_answers, :answers_not_a_map}} =
             SystemOneClient.HTTP.evaluate("s", @questions, @opts)
  end

  test "retries 529 like 429" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 529, "overloaded")
    end)

    assert {:error, {:http, 529, _}} = SystemOneClient.HTTP.evaluate("s", @questions, @opts)
    assert Agent.get(counter, & &1) == 3
  end

  test "retries 503 and honours Retry-After seconds" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(log, &[System.monotonic_time(:millisecond) | &1])

      if length(Agent.get(log, & &1)) < 2 do
        conn |> Plug.Conn.put_resp_header("retry-after", "1") |> Plug.Conn.send_resp(503, "down")
      else
        Req.Test.json(conn, %{"answers" => %{"q" => %{"type" => "noul", "noul" => 0.5}}})
      end
    end)

    assert {:ok, %{"q" => %Noul{noul: 0.5}}, _} =
             SystemOneClient.HTTP.evaluate("s", @questions, @opts)

    [t2, t1] = Agent.get(log, & &1)
    assert t2 - t1 >= 900, "second attempt should wait for Retry-After (1s)"
  end

  test "uses the cloudflare provider: account url, token, and result envelope" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/client/v4/accounts/acc1/ai/run/@cf/cloudflare/clef-flash"
      assert ["Bearer cftoken"] = Plug.Conn.get_req_header(conn, "authorization")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"model" => "@cf/cloudflare/clef-flash"} = Jason.decode!(body)

      Req.Test.json(conn, %{
        "success" => true,
        "errors" => [],
        "result" => %{
          "model" => "clef-flash",
          "answers" => %{"q" => %{"type" => "noul", "noul" => 0.7}}
        }
      })
    end)

    assert {:ok, %{"q" => %Noul{noul: 0.7}}, %{model: "clef-flash", provider: :cloudflare}} =
             SystemOneClient.HTTP.evaluate("s", @questions,
               provider: :cloudflare,
               account_id: "acc1",
               api_key: "cftoken",
               model: "clef-flash",
               plug: {Req.Test, __MODULE__}
             )
  end

  test "cloudflare envelope errors become provider errors" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "success" => false,
        "errors" => [%{"code" => 10_000, "message" => "auth"}],
        "result" => nil
      })
    end)

    assert {:error, {:provider_error, [%{"code" => 10_000, "message" => "auth"}]}} =
             SystemOneClient.HTTP.evaluate("s", @questions,
               provider: :cloudflare,
               account_id: "a",
               api_key: "k",
               plug: {Req.Test, __MODULE__}
             )
  end

  test "compatible provider posts to the given url with no auth header" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert [] = Plug.Conn.get_req_header(conn, "authorization")
      assert conn.request_path == "/v1/systemone"
      Req.Test.json(conn, %{"answers" => %{"q" => %{"type" => "noul", "noul" => 0.1}}})
    end)

    assert {:ok, %{"q" => %Noul{noul: 0.1}}, _} =
             SystemOneClient.HTTP.evaluate("s", @questions,
               provider: :compatible,
               url: "http://clm.local:8700/v1/systemone",
               env: %{},
               plug: {Req.Test, __MODULE__}
             )
  end

  test "emits telemetry start and stop without leaking state, questions or keys" do
    ref = make_ref()
    parent = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [[:system_one_client, :request, :start], [:system_one_client, :request, :stop]],
      fn event, measurements, metadata, _ ->
        send(parent, {ref, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "model" => "jev-1.13.0",
        "answers" => %{"q" => %{"type" => "noul", "noul" => 0.2}}
      })
    end)

    assert {:ok, _, _} = SystemOneClient.HTTP.evaluate(%{secret: "s3"}, @questions, @opts)

    assert_receive {^ref, [:system_one_client, :request, :start], %{system_time: _}, start_meta}
    assert start_meta.provider == :typesafe and start_meta.question_count == 1
    assert_receive {^ref, [:system_one_client, :request, :stop], %{duration: _}, stop_meta}
    assert stop_meta.status == :ok and stop_meta.model == "jev-1.13.0"

    refute inspect(start_meta) =~ "s3" or inspect(stop_meta) =~ "s3" or
             inspect(stop_meta) =~ "test-key"
  end

  test "openai provider: translates the request and the response end to end" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/decisions"
      assert ["Bearer sk-test"] = Plug.Conn.get_req_header(conn, "authorization")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      assert req["model"] == "gpt-6-luna"
      assert req["input"] == "I was charged twice for my order."

      assert [%{"type" => "choice", "name" => "department", "choices" => [_ | _]}] =
               req["questions"]

      refute Map.has_key?(req, "state")

      Req.Test.json(conn, %{
        "model" => "gpt-6-luna",
        "answers" => [
          %{
            "type" => "choice",
            "name" => "department",
            "choice" => "billing",
            "probabilities" => [
              %{"value" => "billing", "probability" => 0.95},
              %{"value" => "technical", "probability" => 0.05}
            ],
            "confidence" => 0.93
          }
        ]
      })
    end)

    questions = %{
      "department" => %{
        "type" => "choice",
        "instructions" => "Which department should handle this complaint?",
        "criteria" => %{"billing" => "Payments", "technical" => "Product problems"}
      }
    }

    assert {:ok,
            %{
              "department" =>
                %SystemOneClient.Answer.Choice{choice: "billing", confidence: 0.93} = c
            }, %{provider: :openai, model: "gpt-6-luna"}} =
             SystemOneClient.HTTP.evaluate("I was charged twice for my order.", questions,
               provider: :openai,
               api_key: "sk-test",
               plug: {Req.Test, __MODULE__}
             )

    assert c.probabilities == %{"billing" => 0.95, "technical" => 0.05}
  end

  test "openai provider: a refused question comes back as a Refusal next to the other answers" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "answers" => [
          %{"type" => "predicate", "name" => "q", "probability" => 0.3},
          %{"type" => "refusal", "name" => "r"}
        ]
      })
    end)

    questions = %{
      "q" => %{"type" => "noul", "instructions" => "?"},
      "r" => %{"type" => "noul", "instructions" => "?"}
    }

    assert {:ok, %{"q" => %Noul{noul: 0.3}, "r" => %SystemOneClient.Answer.Refusal{}}, _} =
             SystemOneClient.HTTP.evaluate("s", questions,
               provider: :openai,
               api_key: "k",
               plug: {Req.Test, __MODULE__}
             )
  end

  test "openai provider: score answers carry the caller's level text as the legend" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "answers" => [
          %{
            "type" => "score",
            "name" => "sev",
            "score" => 1.0,
            "probabilities" => [
              %{"value" => 0, "label" => "Level 0", "probability" => 0.0},
              %{"value" => 1, "label" => "Level 1", "probability" => 1.0}
            ],
            "confidence" => 1.0
          }
        ]
      })
    end)

    questions = %{
      "sev" => %{"type" => "score", "instructions" => "?", "criteria" => ["Minor", "Major"]}
    }

    assert {:ok,
            %{"sev" => %SystemOneClient.Answer.Score{legend: %{"0" => "Minor", "1" => "Major"}}},
            _} =
             SystemOneClient.HTTP.evaluate("s", questions,
               provider: :openai,
               api_key: "k",
               plug: {Req.Test, __MODULE__}
             )
  end

  test "openai provider: invalid questions are rejected before any request" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("must not send") end)

    assert {:error, {:invalid_question, "d", :missing_criteria}} =
             SystemOneClient.HTTP.evaluate(
               "s",
               %{"d" => %{"type" => "choice", "instructions" => "?"}},
               provider: :openai,
               api_key: "k",
               plug: {Req.Test, __MODULE__}
             )
  end

  @png "data:image/png;base64,YWJj"

  test "cloudflare: images go in the top-level images array next to state" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      assert req["images"] == [@png]
      assert req["state"] == "a product photo"

      Req.Test.json(conn, %{
        "success" => true,
        "errors" => [],
        "result" => %{"answers" => %{"q" => %{"type" => "noul", "noul" => 0.4}}}
      })
    end)

    assert {:ok, %{"q" => %Noul{noul: 0.4}}, _} =
             SystemOneClient.HTTP.evaluate("a product photo", @questions,
               provider: :cloudflare,
               account_id: "a",
               api_key: "k",
               images: [@png],
               plug: {Req.Test, __MODULE__}
             )
  end

  test "openai: images become input_image parts before the state text" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      assert [
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "input_image", "image_url" => @png},
                   %{"type" => "input_text"}
                 ]
               }
             ] =
               req["input"]

      Req.Test.json(conn, %{
        "answers" => [%{"type" => "predicate", "name" => "q", "probability" => 0.9}]
      })
    end)

    assert {:ok, %{"q" => %Noul{noul: 0.9}}, _} =
             SystemOneClient.HTTP.evaluate("s", @questions,
               provider: :openai,
               api_key: "k",
               images: [@png],
               plug: {Req.Test, __MODULE__}
             )
  end

  test "gemini provider: x-goog-api-key auth, translated request, answers parsed as is" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1beta/decisions"
      assert ["g-test"] = Plug.Conn.get_req_header(conn, "x-goog-api-key")
      assert [] = Plug.Conn.get_req_header(conn, "authorization")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      assert req["model"] == "gemini-decision-1"
      assert req["input"] == ~s({"text":"I was charged twice."})
      refute Map.has_key?(req, "state")

      assert req["questions"]["damaged"] == %{
               "type" => "noul",
               "instructions" => "Did the item arrive damaged?",
               "criteria" => %{"true_description" => "Broken", "false_description" => "Fine"}
             }

      assert req["questions"]["dept"]["criteria"] == %{"billing" => "Payments", "other" => ""}
      assert req["questions"]["sev"]["criteria"] == ["Minor", "Major"]

      Req.Test.json(conn, %{
        "answers" => %{
          "damaged" => %{"type" => "noul", "noul" => 0.03, "confidence" => 0.97},
          "dept" => %{
            "type" => "choice",
            "choice" => "billing",
            "probabilities" => %{"billing" => 0.99, "other" => 0.01},
            "confidence" => 0.99
          },
          "sev" => %{
            "type" => "score",
            "score" => 0.85,
            "legend" => %{"0" => "Minor", "1" => "Major"},
            "probabilities" => %{"0" => 0.15, "1" => 0.85},
            "confidence" => 0.85
          }
        },
        "usage" => %{
          "total_input_tokens" => 324,
          "input_tokens_by_modality" => [%{"modality" => "text", "tokens" => 324}],
          "total_output_tokens" => 0,
          "total_tokens" => 324
        }
      })
    end)

    questions = %{
      "dept" => %{
        "type" => "choice",
        "instructions" => "Which department?",
        "criteria" => %{"billing" => "Payments", "other" => nil}
      },
      "sev" => %{
        "type" => "score",
        "instructions" => "How bad?",
        "criteria" => ["Minor", "Major"]
      },
      damaged: %{
        type: "noul",
        instructions: "Did the item arrive damaged?",
        criteria: %{true => "Broken", false => "Fine"}
      }
    }

    assert {:ok, answers, meta} =
             SystemOneClient.HTTP.evaluate(%{text: "I was charged twice."}, questions,
               provider: :gemini,
               api_key: "g-test",
               plug: {Req.Test, __MODULE__}
             )

    assert %Noul{noul: 0.03} = answers["damaged"]

    assert %SystemOneClient.Answer.Choice{choice: "billing", confidence: 0.99} = answers["dept"]

    assert %SystemOneClient.Answer.Score{score: 0.85, legend: %{"1" => "Major"}} = answers["sev"]
    assert meta.provider == :gemini
    assert meta.model == "gemini-decision-1"
    assert meta.usage["total_input_tokens"] == 324
  end

  test "gemini: images become image blocks before the state text" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      "data:image/png;base64," <> data = @png

      assert [
               %{"type" => "image", "data" => ^data, "mime_type" => "image/png"},
               %{"type" => "text", "text" => "s"}
             ] = Jason.decode!(body)["input"]

      Req.Test.json(conn, %{"answers" => %{"q" => %{"type" => "noul", "noul" => 0.9}}})
    end)

    assert {:ok, %{"q" => %Noul{noul: 0.9}}, _} =
             SystemOneClient.HTTP.evaluate("s", @questions,
               provider: :gemini,
               api_key: "k",
               images: [@png],
               plug: {Req.Test, __MODULE__}
             )
  end

  test "gemini: a safety block is an http 400 with the error body, and is not retried" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => %{"code" => "safety", "message" => "blocked"}})
    end)

    assert {:error, {:http, 400, %{"error" => %{"code" => "safety"}}}} =
             SystemOneClient.HTTP.evaluate("s", @questions,
               provider: :gemini,
               api_key: "k",
               plug: {Req.Test, __MODULE__}
             )

    assert Agent.get(counter, & &1) == 1
  end

  test "gemini: a choice or score without criteria is rejected before any request" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("must not send") end)

    assert {:error, {:invalid_question, "c", :missing_criteria}} =
             SystemOneClient.HTTP.evaluate(
               "s",
               %{"c" => %{"type" => "choice", "instructions" => "?"}},
               provider: :gemini,
               api_key: "k",
               plug: {Req.Test, __MODULE__}
             )
  end

  test "images are rejected before any request for providers without image support" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("must not send") end)

    assert {:error, {:unsupported_option, :images, :typesafe}} =
             SystemOneClient.HTTP.evaluate("s", @questions, Keyword.put(@opts, :images, [@png]))

    assert {:error, {:invalid_image, 0, :not_a_data_url}} =
             SystemOneClient.HTTP.evaluate("s", @questions,
               provider: :openai,
               api_key: "k",
               images: ["https://example.com/a.png"],
               plug: {Req.Test, __MODULE__}
             )
  end

  test "telemetry reports the image count, never image data" do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:system_one_client, :request, :start],
      fn _e, _m, md, _ -> send(parent, {ref, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "answers" => [%{"type" => "predicate", "name" => "q", "probability" => 0.9}]
      })
    end)

    SystemOneClient.HTTP.evaluate("s", @questions,
      provider: :openai,
      api_key: "k",
      images: [@png, @png],
      plug: {Req.Test, __MODULE__}
    )

    assert_receive {^ref, %{image_count: 2} = md}
    refute inspect(md) =~ "base64"
  end

  test "surfaces malformed answers" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"answers" => %{"q" => %{"type" => "choice"}}})
    end)

    assert {:error, {:malformed_answers, {"q", {:malformed_answer, "choice"}}}} =
             SystemOneClient.HTTP.evaluate("s", @questions, @opts)
  end
end
