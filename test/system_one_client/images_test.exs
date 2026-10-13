defmodule SystemOneClient.ImagesTest do
  use ExUnit.Case, async: true

  alias SystemOneClient.Images

  @png "data:image/png;base64," <> Base.encode64("fake png bytes")
  @gif "data:image/gif;base64," <> Base.encode64("fake gif bytes")

  describe "SystemOneClient.image_data_url/2" do
    test "base64-encodes bytes into a data URL" do
      assert SystemOneClient.image_data_url("abc", "image/png") == "data:image/png;base64,YWJj"
    end

    test "rejects a non-image media type" do
      assert_raise ArgumentError, ~r/image\//, fn ->
        SystemOneClient.image_data_url("x", "text/plain")
      end
    end
  end

  describe "validate/2" do
    test "no images is always fine, for every provider" do
      for provider <- [:typesafe, :openrouter, :compatible, :openai, :cloudflare] do
        assert :ok = Images.validate(nil, provider)
        assert :ok = Images.validate([], provider)
      end
    end

    test "providers without image support are rejected locally" do
      for provider <- [:typesafe, :openrouter, :compatible] do
        assert {:error, {:unsupported_option, :images, ^provider}} =
                 Images.validate([@png], provider)
      end
    end

    test "entries must be base64 image data URLs" do
      assert {:error, {:invalid_image, 1, :not_a_data_url}} =
               Images.validate([@png, "https://example.com/cat.png"], :openai)

      assert {:error, {:invalid_image, 0, :not_a_data_url}} =
               Images.validate([%{"url" => "x"}], :openai)

      assert {:error, {:invalid_image, 0, :invalid_base64}} =
               Images.validate(["data:image/png;base64,***not base64***"], :openai)

      assert {:error, :images_not_a_list} = Images.validate(@png, :openai)
    end

    test "openai accepts any image type" do
      assert :ok = Images.validate([@png, @gif], :openai)
    end

    test "cloudflare enforces Clef's documented limits" do
      assert :ok = Images.validate([@png, @png, @png, @png], :cloudflare)

      assert {:error, {:too_many_images, 5, 4}} =
               Images.validate(List.duplicate(@png, 5), :cloudflare)

      assert {:error, {:invalid_image, 0, {:unsupported_type, "image/gif"}}} =
               Images.validate([@gif], :cloudflare)

      big = "data:image/png;base64," <> Base.encode64(:binary.copy("a", 4 * 1024 * 1024 + 1))
      assert {:error, {:invalid_image, 0, :too_large}} = Images.validate([big], :cloudflare)

      three_mib = "data:image/jpeg;base64," <> Base.encode64(:binary.copy("a", 3 * 1024 * 1024))

      assert {:error, {:images_too_large, _total, 8_388_608}} =
               Images.validate([three_mib, three_mib, three_mib], :cloudflare)
    end
  end
end
