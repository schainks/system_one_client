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

  test "surfaces malformed answers" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"answers" => %{"q" => %{"type" => "choice"}}})
    end)

    assert {:error, {:malformed_answers, {"q", {:malformed_answer, "choice"}}}} =
             SystemOneClient.HTTP.evaluate("s", @questions, @opts)
  end
end
