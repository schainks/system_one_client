defmodule SystemOneClient.Images do
  @moduledoc """
  Validation for the `images:` option.

  Images are base64 data URLs (`data:image/png;base64,...`); build one from bytes with
  `SystemOneClient.image_data_url/2`. Only providers whose APIs accept images can take
  them, and they are checked before any request is sent:

  | Provider | Accepted | Limits checked locally |
  | --- | --- | --- |
  | `:openai` | any `image/*` data URL | none documented |
  | `:cloudflare` | PNG, JPEG, WebP | at most 4 images, 4 MiB each and 8 MiB in total, decoded |
  | others | no | returns `{:error, {:unsupported_option, :images, provider}}` |

  Remote `http(s)` image URLs are rejected for every provider because neither API
  accepts them.
  """

  @data_url ~r/\Adata:(image\/[a-zA-Z0-9.+-]+);base64,(.*)\z/s
  @clef_types ~w(image/png image/jpeg image/webp)
  @clef_max_images 4
  @clef_max_bytes 4 * 1024 * 1024
  @clef_max_total 8 * 1024 * 1024

  @type error ::
          :images_not_a_list
          | {:unsupported_option, :images, atom()}
          | {:invalid_image, non_neg_integer(),
             :not_a_data_url | :invalid_base64 | :too_large | {:unsupported_type, String.t()}}
          | {:too_many_images, pos_integer(), pos_integer()}
          | {:images_too_large, non_neg_integer(), pos_integer()}

  @doc """
  Checks `images` for `provider`.

      iex> SystemOneClient.Images.validate(["data:image/png;base64,YWJj"], :openai)
      :ok

      iex> SystemOneClient.Images.validate(["https://example.com/a.png"], :openai)
      {:error, {:invalid_image, 0, :not_a_data_url}}
  """
  @spec validate(term(), atom()) :: :ok | {:error, error()}
  def validate(nil, _provider), do: :ok
  def validate([], _provider), do: :ok
  def validate(images, _provider) when not is_list(images), do: {:error, :images_not_a_list}

  def validate(images, provider) when provider in [:openai, :cloudflare] do
    with {:ok, parsed} <- parse_all(images) do
      limits(provider, parsed)
    end
  end

  def validate(_images, provider), do: {:error, {:unsupported_option, :images, provider}}

  defp parse_all(images) do
    images
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {image, i}, {:ok, acc} ->
      case parse(image) do
        {:ok, type, bytes} -> {:cont, {:ok, [{i, type, bytes} | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_image, i, reason}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse(image) when is_binary(image) do
    case Regex.run(@data_url, image, capture: :all_but_first) do
      [type, payload] ->
        case Base.decode64(payload, ignore: :whitespace) do
          {:ok, bytes} -> {:ok, String.downcase(type), byte_size(bytes)}
          :error -> {:error, :invalid_base64}
        end

      nil ->
        {:error, :not_a_data_url}
    end
  end

  defp parse(_image), do: {:error, :not_a_data_url}

  defp limits(:openai, _parsed), do: :ok

  defp limits(:cloudflare, parsed) do
    total = parsed |> Enum.map(fn {_i, _type, size} -> size end) |> Enum.sum()

    cond do
      length(parsed) > @clef_max_images ->
        {:error, {:too_many_images, length(parsed), @clef_max_images}}

      bad = Enum.find(parsed, fn {_i, type, _} -> type not in @clef_types end) ->
        {i, type, _} = bad
        {:error, {:invalid_image, i, {:unsupported_type, type}}}

      big = Enum.find(parsed, fn {_i, _type, size} -> size > @clef_max_bytes end) ->
        {:error, {:invalid_image, elem(big, 0), :too_large}}

      total > @clef_max_total ->
        {:error, {:images_too_large, total, @clef_max_total}}

      true ->
        :ok
    end
  end
end
