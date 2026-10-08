defmodule SystemOneClient.StubTest do
  use ExUnit.Case, async: false
  alias SystemOneClient.Answer.{Noul, Choice}

  @q %{"a" => %{"type" => "noul", "instructions" => "?"}}

  test "returns canned struct answers" do
    assert {:ok, %{"a" => %Noul{noul: 0.2}}, %{latency_ms: 0}} =
             SystemOneClient.Stub.evaluate("s", @q, answers: %{"a" => %Noul{noul: 0.2}})
  end

  test "parses canned raw answers" do
    assert {:ok, %{"a" => %Choice{choice: "x"}}, _} =
             SystemOneClient.Stub.evaluate("s", @q,
               answers: %{
                 "a" => %{
                   "type" => "choice",
                   "choice" => "x",
                   "probabilities" => %{"x" => 1.0},
                   "confidence" => 1.0
                 }
               }
             )
  end

  test "calls a function with state and questions, and passes errors through" do
    fun = fn state, questions ->
      if state == :boom,
        do: {:error, :down},
        else: %{"a" => %Noul{noul: map_size(questions) / 1}}
    end

    assert {:ok, %{"a" => %Noul{noul: 1.0}}, _} =
             SystemOneClient.Stub.evaluate(:ok, @q, answers: fun)

    assert {:error, :down} = SystemOneClient.Stub.evaluate(:boom, @q, answers: fun)
  end

  test "dispatcher uses opts[:client] then app env" do
    assert {:ok, %{"a" => %Noul{noul: 0.5}}, _} =
             SystemOneClient.evaluate("s", @q,
               client: SystemOneClient.Stub,
               answers: %{"a" => %Noul{noul: 0.5}}
             )

    Application.put_env(:system_one_client, :client, SystemOneClient.Stub)
    on_exit(fn -> Application.delete_env(:system_one_client, :client) end)
    assert {:ok, _, _} = SystemOneClient.evaluate("s", @q, answers: %{"a" => %Noul{noul: 0.5}})
  end
end
