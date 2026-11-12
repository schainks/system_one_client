defmodule SystemOneClient.DoctestTest do
  use ExUnit.Case, async: true

  doctest SystemOneClient
  doctest SystemOneClient.Answer
  doctest SystemOneClient.Images
  doctest SystemOneClient.Provider
  doctest SystemOneClient.Wire.OpenAIDecisions
  doctest SystemOneClient.Wire.GeminiDecisions
end
