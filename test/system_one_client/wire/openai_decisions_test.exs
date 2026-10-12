defmodule SystemOneClient.Wire.OpenAIDecisionsTest do
  use ExUnit.Case, async: true

  alias SystemOneClient.Wire.OpenAIDecisions, as: Wire

  describe "encode_request/3" do
    test "translates a choice question into OpenAI's choices array" do
      questions = %{
        "department" => %{
          "type" => "choice",
          "instructions" => "Which department should handle this complaint?",
          "criteria" => %{
            "billing" => "Payments, invoices, and refunds.",
            "technical" => "Problems using the product."
          }
        }
      }

      assert {:ok, body} =
               Wire.encode_request("I was charged twice for my order.", questions, "gpt-6-luna")

      assert body.model == "gpt-6-luna"
      assert body.input == "I was charged twice for my order."

      assert [
               %{
                 type: "choice",
                 name: "department",
                 instructions: "Which department should handle this complaint?",
                 choices: choices
               }
             ] = body.questions

      assert Enum.sort_by(choices, & &1.value) == [
               %{value: "billing", description: "Payments, invoices, and refunds."},
               %{value: "technical", description: "Problems using the product."}
             ]
    end

    test "translates noul into a predicate and folds its true/false criteria into the instructions" do
      questions = %{
        "urgent" => %{
          "type" => "noul",
          "instructions" => "Is this urgent?",
          "criteria" => %{
            "true" => "Explicitly time-sensitive",
            "false" => "No urgency expressed"
          }
        },
        "plain" => %{"type" => "noul", "instructions" => "Is it about billing?"}
      }

      assert {:ok, body} = Wire.encode_request("text", questions, "gpt-6-luna")
      by_name = Map.new(body.questions, &{&1.name, &1})

      assert %{type: "predicate", instructions: instructions} = by_name["urgent"]
      assert instructions =~ "Is this urgent?"
      assert instructions =~ "True when: Explicitly time-sensitive"
      assert instructions =~ "False when: No urgency expressed"
      refute Map.has_key?(by_name["urgent"], :criteria)

      assert by_name["plain"] == %{
               type: "predicate",
               name: "plain",
               instructions: "Is it about billing?"
             }
    end

    test "translates score levels into labelled levels in order" do
      questions = %{
        "severity" => %{
          "type" => "score",
          "instructions" => "How severe is this issue?",
          "criteria" => ["Cosmetic", "Workaround available", "Fully blocked"]
        }
      }

      assert {:ok, %{questions: [q]}} = Wire.encode_request("x", questions, "gpt-6-luna")

      assert q.levels == [
               %{label: "Level 0", description: "Cosmetic"},
               %{label: "Level 1", description: "Workaround available"},
               %{label: "Level 2", description: "Fully blocked"}
             ]
    end

    test "JSON-encodes non-string state, instructions and descriptions" do
      questions = %{
        "team" => %{
          "type" => "choice",
          "instructions" => %{"ask" => "Which team?", "note" => "prefer specific teams"},
          "criteria" => %{
            "returns" => %{"what" => "Exchanges", "examples" => ["Wrong size"]},
            "other" => nil
          }
        }
      }

      assert {:ok, body} = Wire.encode_request(%{ticket: %{id: 7}}, questions, "gpt-6-luna")
      assert Jason.decode!(body.input) == %{"ticket" => %{"id" => 7}}
      [q] = body.questions

      assert Jason.decode!(q.instructions) == %{
               "ask" => "Which team?",
               "note" => "prefer specific teams"
             }

      by_value = Map.new(q.choices, &{&1.value, &1})

      assert Jason.decode!(by_value["returns"].description) == %{
               "what" => "Exchanges",
               "examples" => ["Wrong size"]
             }

      assert by_value["other"] == %{value: "other"}
    end

    test "accepts atom question ids and atom keys" do
      questions = %{urgent: %{type: :noul, instructions: "Urgent?"}}

      assert {:ok, %{questions: [%{type: "predicate", name: "urgent", instructions: "Urgent?"}]}} =
               Wire.encode_request("x", questions, "gpt-6-luna")
    end

    test "rejects choice and score questions without criteria" do
      assert {:error, {:invalid_question, "dept", :missing_criteria}} =
               Wire.encode_request(
                 "x",
                 %{"dept" => %{"type" => "choice", "instructions" => "?"}},
                 "gpt-6-luna"
               )

      assert {:error, {:invalid_question, "sev", :missing_criteria}} =
               Wire.encode_request(
                 "x",
                 %{"sev" => %{"type" => "score", "instructions" => "?", "criteria" => []}},
                 "m"
               )
    end

    test "omits model when nil" do
      assert {:ok, body} =
               Wire.encode_request("x", %{"a" => %{"type" => "noul", "instructions" => "?"}}, nil)

      refute Map.has_key?(body, :model)
    end
  end

  describe "decode_response/1" do
    test "turns OpenAI's answers array into System One answers keyed by question id" do
      body = %{
        "model" => "gpt-6-luna",
        "usage" => %{"input_tokens" => 120},
        "answers" => [
          %{"type" => "predicate", "name" => "visible_damage", "probability" => 0.92},
          %{
            "type" => "choice",
            "name" => "department",
            "choice" => "billing",
            "probabilities" => [
              %{"value" => "billing", "probability" => 0.95},
              %{"value" => "technical", "probability" => 0.02},
              %{"value" => "shipping", "probability" => 0.01},
              %{"value" => "other", "probability" => 0.02}
            ],
            "confidence" => 0.93
          },
          %{
            "type" => "score",
            "name" => "severity",
            "score" => 1.1,
            "probabilities" => [
              %{"value" => 0, "label" => "Cosmetic", "probability" => 0.1},
              %{"value" => 1, "label" => "Workaround available", "probability" => 0.7},
              %{"value" => 2, "label" => "Fully blocked", "probability" => 0.2}
            ],
            "confidence" => 0.55
          },
          %{"type" => "refusal", "name" => "sensitive"}
        ]
      }

      assert {:ok, decoded} = Wire.decode_response(body)
      assert decoded["model"] == "gpt-6-luna"
      assert decoded["usage"] == %{"input_tokens" => 120}
      answers = decoded["answers"]

      assert answers["visible_damage"] == %{"type" => "noul", "noul" => 0.92}

      assert answers["department"] == %{
               "type" => "choice",
               "choice" => "billing",
               "probabilities" => %{
                 "billing" => 0.95,
                 "technical" => 0.02,
                 "shipping" => 0.01,
                 "other" => 0.02
               },
               "confidence" => 0.93
             }

      assert answers["severity"] == %{
               "type" => "score",
               "score" => 1.1,
               "probabilities" => %{"0" => 0.1, "1" => 0.7, "2" => 0.2},
               "legend" => %{
                 "0" => "Cosmetic",
                 "1" => "Workaround available",
                 "2" => "Fully blocked"
               },
               "confidence" => 0.55
             }

      assert answers["sensitive"] == %{"type" => "refusal"}
    end

    test "rebuilds the score legend from the original level text when given the questions" do
      questions = %{
        "severity" => %{
          "type" => "score",
          "instructions" => "?",
          "criteria" => ["Cosmetic", "Blocked"]
        }
      }

      body = %{
        "answers" => [
          %{
            "type" => "score",
            "name" => "severity",
            "score" => 0.9,
            "probabilities" => [
              %{"value" => 0, "label" => "Level 0", "probability" => 0.1},
              %{"value" => 1, "label" => "Level 1", "probability" => 0.9}
            ],
            "confidence" => 0.8
          }
        ]
      }

      assert {:ok,
              %{
                "answers" => %{
                  "severity" => %{"legend" => %{"0" => "Cosmetic", "1" => "Blocked"}}
                }
              }} =
               Wire.decode_response(body, questions)
    end

    test "stringifies non-string choice values" do
      body = %{
        "answers" => [
          %{
            "type" => "choice",
            "name" => "n",
            "choice" => 2,
            "probabilities" => [
              %{"value" => 2, "probability" => 0.8},
              %{"value" => 5, "probability" => 0.2}
            ],
            "confidence" => 0.7
          }
        ]
      }

      assert {:ok,
              %{
                "answers" => %{
                  "n" => %{"choice" => "2", "probabilities" => %{"2" => 0.8, "5" => 0.2}}
                }
              }} =
               Wire.decode_response(body)
    end

    test "passes unknown answer types through for the parser to reject" do
      assert {:ok, %{"answers" => %{"x" => %{"type" => "verdict"}}}} =
               Wire.decode_response(%{"answers" => [%{"type" => "verdict", "name" => "x"}]})
    end

    test "rejects bodies without an answers array or with unnamed answers" do
      assert {:error, :no_answers} = Wire.decode_response(%{"error" => "nope"})
      assert {:error, :no_answers} = Wire.decode_response(%{"answers" => %{}})

      assert {:error, {:unnamed_answer, _}} =
               Wire.decode_response(%{
                 "answers" => [%{"type" => "predicate", "probability" => 0.5}]
               })
    end
  end
end
