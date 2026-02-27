defmodule Vibe.Chat.AgentMessageCrypto do
  @moduledoc """
  Encrypt/decrypt agent plaintext for at-rest database storage.
  """

  require Logger

  @prefix "agm1"

  def encrypt_for_storage(plaintext) when is_binary(plaintext) do
    key = encryption_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        plaintext,
        "",
        16,
        true
      )

    [
      @prefix,
      Base.url_encode64(iv, padding: false),
      Base.url_encode64(ciphertext, padding: false),
      Base.url_encode64(tag, padding: false)
    ]
    |> Enum.join(".")
  rescue
    error ->
      Logger.error("[AgentMessageCrypto] encrypt_for_storage failed: #{inspect(error)}")
      plaintext
  end

  def encrypt_for_storage(other), do: to_string(other || "")

  def decrypt_from_storage(ciphertext) when is_binary(ciphertext) do
    case String.split(ciphertext, ".", parts: 4) do
      [@prefix, iv_b64, cipher_b64, tag_b64] ->
        with {:ok, iv} <- decode(iv_b64),
             {:ok, encrypted} <- decode(cipher_b64),
             {:ok, tag} <- decode(tag_b64) do
          case :crypto.crypto_one_time_aead(
                 :aes_256_gcm,
                 encryption_key(),
                 iv,
                 encrypted,
                 "",
                 tag,
                 false
               ) do
            :error -> ciphertext
            plaintext when is_binary(plaintext) -> plaintext
            _ -> ciphertext
          end
        else
          _ -> ciphertext
        end

      _ ->
        ciphertext
    end
  rescue
    _ -> ciphertext
  end

  def decrypt_from_storage(other), do: to_string(other || "")

  def encrypted_storage_format?(ciphertext) when is_binary(ciphertext) do
    String.starts_with?(ciphertext, @prefix <> ".")
  end

  def encrypted_storage_format?(_), do: false

  defp decode(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_base64}
    end
  end

  defp encryption_key do
    seed =
      System.get_env("AGENT_MESSAGE_ENCRYPTION_KEY")
      || System.get_env("SECRET_KEY_BASE")
      || "vibe-agent-dev-default-key"

    :crypto.hash(:sha256, seed)
  end
end

