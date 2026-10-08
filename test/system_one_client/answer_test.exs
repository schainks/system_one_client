defmodule SystemOneClient.AnswerTest do
  use ExUnit.Case, async: true
  alias SystemOneClient.Answer
  alias SystemOneClient.Answer.{Choice, Noul, Score}

  test "parses a choice answer" do
    assert {:ok,
            %Choice{choice: "add", probabilities: %{"add" => 0.7, "none" => 0.3}, confidence: 0.7}} =
             Answer.parse(%{
               "type" => "choice",
               "choice" => "add",
               "probabilities" => %{"add" => 0.7, "none" => 0.3},
               "confidence" => 0.7
             })
  end

  test "parses a noul answer" do
    assert {:ok, %Noul{noul: 0.93}} = Answer.parse(%{"type" => "noul", "noul" => 0.93})
  end

  test "parses a score answer" do
    assert {:ok,
            %Score{
              score: 1.43,
              confidence: 0.35,
              legend: %{"0" => "a"},
              probabilities: %{"0" => +0.0, "1" => 0.57}
            }} =
             Answer.parse(%{
               "type" => "score",
               "score" => 1.43,
               "confidence" => 0.35,
               "legend" => %{"0" => "a"},
               "probabilities" => %{"0" => 0.0, "1" => 0.57}
             })
  end

  test "rejects unknown types and missing fields" do
    assert {:error, {:unknown_answer_type, "bogus"}} = Answer.parse(%{"type" => "bogus"})
    assert {:error, {:malformed_answer, "choice"}} = Answer.parse(%{"type" => "choice"})
  end

  test "rejects non-numeric probabilities" do
    assert {:error, {:malformed_answer, "choice"}} =
             Answer.parse(%{
               "type" => "choice",
               "choice" => "a",
               "probabilities" => %{"a" => "high"},
               "confidence" => 0.9
             })
  end

  test "parse_all rejects a non-map answers payload" do
    assert {:error, :answers_not_a_map} = Answer.parse_all(nil)
    assert {:error, :answers_not_a_map} = Answer.parse_all([])
  end

  test "parse_all keeps ids and fails on the first bad answer" do
    good = %{"a" => %{"type" => "noul", "noul" => 0.1}, "b" => %{"type" => "noul", "noul" => 0.9}}
    assert {:ok, %{"a" => %Noul{noul: 0.1}, "b" => %Noul{noul: 0.9}}} = Answer.parse_all(good)

    assert {:error, {"b", {:unknown_answer_type, "x"}}} =
             Answer.parse_all(Map.put(good, "b", %{"type" => "x"}))
  end
end
