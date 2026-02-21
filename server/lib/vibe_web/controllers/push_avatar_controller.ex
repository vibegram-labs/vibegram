defmodule VibeWeb.PushAvatarController do
  use VibeWeb, :controller

  alias Vibe.Accounts

  @max_avatar_bytes 3_000_000

  def show(conn, %{"user_id" => user_id}) do
    case Accounts.get_user(user_id) do
      nil ->
        send_resp(conn, 404, "")

      user ->
        send_avatar(conn, user.profile_image)
    end
  end

  defp send_avatar(conn, value) when is_binary(value) do
    source = String.trim(value)

    cond do
      source == "" ->
        send_resp(conn, 404, "")

      String.starts_with?(String.downcase(source), ["http://", "https://"]) ->
        conn
        |> put_resp_header("cache-control", "public, max-age=300")
        |> redirect(external: source)

      true ->
        case decode_inline_image(source) do
          {:ok, mime, data} when byte_size(data) <= @max_avatar_bytes ->
            conn
            |> put_resp_content_type(mime)
            |> put_resp_header("cache-control", "public, max-age=300")
            |> send_resp(200, data)

          {:ok, _mime, _data} ->
            send_resp(conn, 413, "")

          :error ->
            send_resp(conn, 404, "")
        end
    end
  end

  defp send_avatar(conn, _), do: send_resp(conn, 404, "")

  defp decode_inline_image(source) when is_binary(source) do
    case Regex.named_captures(~r/^data:(?<mime>image\/[a-zA-Z0-9.+-]+);base64,(?<data>.+)$/i, source) do
      %{"mime" => mime, "data" => encoded} ->
        with {:ok, data} <- decode_base64(encoded) do
          {:ok, String.downcase(mime), data}
        else
          _ -> :error
        end

      _ ->
        with {:ok, data} <- decode_base64(source) do
          {:ok, infer_image_mime(data), data}
        else
          _ -> :error
        end
    end
  end

  defp decode_base64(value) do
    normalized = String.replace(value, ~r/\s+/, "")

    case Base.decode64(normalized) do
      {:ok, data} ->
        {:ok, data}

      :error ->
        case Base.url_decode64(normalized, padding: false) do
          {:ok, data} -> {:ok, data}
          :error -> :error
        end
    end
  end

  defp infer_image_mime(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp infer_image_mime(<<0x89, 0x50, 0x4E, 0x47, _::binary>>), do: "image/png"
  defp infer_image_mime(<<0x47, 0x49, 0x46, 0x38, _::binary>>), do: "image/gif"
  defp infer_image_mime(<<0x52, 0x49, 0x46, 0x46, _::binary-size(4), 0x57, 0x45, 0x42, 0x50, _::binary>>), do: "image/webp"
  defp infer_image_mime(_), do: "image/jpeg"
end
