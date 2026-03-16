defmodule Vibe.Accounts do
  import Ecto.Query, warn: false
  import Plug.Crypto, only: [secure_compare: 2]
  alias Vibe.Repo
  alias Vibe.Accounts.User
  alias Vibe.Accounts.UserBlock

  defmacrop normalized_phone_expr(phone_field) do
    quote do
      fragment("regexp_replace(COALESCE(?, ''), '[^0-9]', '', 'g')", unquote(phone_field))
    end
  end

  # SECURITY: PBKDF2 iteration count - must match auth_controller.ex
  @pbkdf2_iterations 600_000
  @legacy_pbkdf2_iterations 1_000
  @phone_min_digits 7
  @phone_max_digits 15
  @reserved_usernames ["vibeagent"]

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_token(token) do
    case Repo.get_by(User, login_token: token) do
      nil ->
        {:error, :not_found}
      %User{is_agent: true} ->
        {:error, :not_found}
      user ->
        # SECURITY: Check token expiration
        if token_valid?(user) do
          {:ok, user}
        else
          {:error, :token_expired}
        end
    end
  end

  @doc """
  Check if token is still valid (not expired).
  Returns true if token_expires_at is in the future or not set (legacy users).
  """
  def token_valid?(%User{token_expires_at: nil}), do: true
  def token_valid?(%User{token_expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  def get_user_by_username(username) do
    lower_username = String.downcase(username)
    Repo.one(from u in User, where: fragment("LOWER(?)", u.username) == ^lower_username)
  end

  def get_user_by_phone(phone_number) do
    case normalize_phone_number(phone_number) do
      nil ->
        nil

      normalized_phone ->
        Repo.one(
          from u in User,
            where: normalized_phone_expr(u.phone_number) == ^normalized_phone,
            limit: 1
        )
    end
  end

  def list_users_by_phone_numbers(phone_numbers, opts \\ []) when is_list(phone_numbers) do
    normalized_phones =
      phone_numbers
      |> Enum.map(&normalize_phone_number/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if normalized_phones == [] do
      []
    else
      exclude_id = Keyword.get(opts, :exclude_id)
      limit = Keyword.get(opts, :limit, 500)

      query =
        from u in User,
          where: normalized_phone_expr(u.phone_number) in ^normalized_phones and u.is_agent == false,
          limit: ^limit

      query =
        if exclude_id do
          from u in query, where: u.id != ^exclude_id
        else
          query
        end

      Repo.all(query)
    end
  end

  def normalize_phone_number(phone_number) when is_binary(phone_number) do
    normalized =
      phone_number
      |> String.trim()
      |> String.replace(~r/[^0-9]/, "")

    if normalized == "" or String.length(normalized) < @phone_min_digits or
         String.length(normalized) > @phone_max_digits do
      nil
    else
      normalized
    end
  end

  def normalize_phone_number(_), do: nil

  def username_exists?(username) do
    Repo.exists?(from u in User, where: fragment("LOWER(?)", u.username) == ^String.downcase(username))
  end

  def reserved_username?(username) when is_binary(username) do
    String.downcase(String.trim(username)) in @reserved_usernames
  end

  def reserved_username?(_), do: false

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  @doc """
  Verify password against stored hash using PBKDF2.
  Supports both old (1000 iterations) and new (600,000 iterations) hashes.
  """
  def verify_password(password, stored_hash) do
    match?({:ok, _}, verify_password_with_info(password, stored_hash))
  end

  @doc """
  Verify password and return whether the hash uses current or legacy iterations.
  """
  def verify_password_with_info(password, stored_hash) do
    with {:ok, salt_bin, expected_hash_bin} <- parse_password_hash(stored_hash) do
      cond do
        verify_with_iterations(password, salt_bin, expected_hash_bin, @pbkdf2_iterations) ->
          {:ok, :current}

        verify_with_iterations(password, salt_bin, expected_hash_bin, @legacy_pbkdf2_iterations) ->
          {:ok, :legacy}

        true ->
          :error
      end
    else
      _ ->
        :error
    end
  end

  defp parse_password_hash(stored_hash) when is_binary(stored_hash) do
    with [salt_hex, hash_hex] <- String.split(stored_hash, ":", parts: 2),
         {:ok, salt_bin} <- Base.decode16(salt_hex, case: :mixed),
         {:ok, hash_bin} <- Base.decode16(hash_hex, case: :mixed) do
      {:ok, salt_bin, hash_bin}
    else
      _ -> :error
    end
  end

  defp parse_password_hash(_), do: :error

  defp verify_with_iterations(password, salt_bin, expected_hash_bin, iterations)
       when is_binary(expected_hash_bin) and byte_size(expected_hash_bin) > 0 do
    derived_bin = :crypto.pbkdf2_hmac(:sha512, password, salt_bin, iterations, byte_size(expected_hash_bin))
    secure_compare(derived_bin, expected_hash_bin)
  end

  defp verify_with_iterations(_password, _salt_bin, _expected_hash_bin, _iterations), do: false

  @doc """
  Migrate a user's password hash to the new iteration count.
  Call this after successful login with old hash.
  """
  def upgrade_password_hash(%User{} = user, password) do
    salt = :crypto.strong_rand_bytes(16)
    derived_bin = :crypto.pbkdf2_hmac(:sha512, password, salt, @pbkdf2_iterations, 64)
    new_hash = Base.encode16(salt, case: :lower) <> ":" <> Base.encode16(derived_bin, case: :lower)

    update_user(user, %{"password_hash" => new_hash})
  end

  def block_user(user_id, blocked_user_id) do
    %UserBlock{}
    |> UserBlock.changeset(%{user_id: user_id, blocked_user_id: blocked_user_id})
    |> Repo.insert()
  end

  def unblock_user(user_id, blocked_user_id) do
    query = from ub in UserBlock,
      where: ub.user_id == ^user_id and ub.blocked_user_id == ^blocked_user_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      block -> Repo.delete(block)
    end
  end

  def list_blocked_users(user_id) do
    query = from ub in UserBlock,
      join: u in User, on: u.id == ub.blocked_user_id,
      where: ub.user_id == ^user_id,
      select: u

    Repo.all(query)
  end

  def blocked?(user_id, target_id) do
    query = from ub in UserBlock,
      where: ub.user_id == ^user_id and ub.blocked_user_id == ^target_id

    Repo.exists?(query)
  end


end
