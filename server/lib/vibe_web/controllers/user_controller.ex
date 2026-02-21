defmodule VibeWeb.UserController do
  use VibeWeb, :controller
  alias Vibe.Accounts
  require Logger
  @max_contact_match_numbers 500

  def show(conn, %{"id" => id}) do
    case Accounts.get_user(id) do
      nil -> conn |> put_status(404) |> json(%{error: "User not found"})
      user -> render_user(conn, user, conn.assigns.current_user)
    end
  end

  def show_by_name(conn, %{"username" => username}) do
    case Accounts.get_user_by_username(username) do
      nil -> conn |> put_status(404) |> json(%{error: "User not found"})
      user -> render_user(conn, user, conn.assigns.current_user)
    end
  end

  def show_by_phone(conn, %{"phone" => phone}) do
    case Accounts.get_user_by_phone(phone) do
      nil -> conn |> put_status(404) |> json(%{error: "User not found"})
      user -> render_user(conn, user, conn.assigns.current_user)
    end
  end

  def match_contacts(conn, %{"phoneNumbers" => phone_numbers}) when is_list(phone_numbers) do
    cond do
      phone_numbers == [] ->
        json(conn, %{matches: [], total: 0})

      length(phone_numbers) > @max_contact_match_numbers ->
        conn
        |> put_status(400)
        |> json(%{error: "Too many phone numbers. Max #{@max_contact_match_numbers} per request."})

      true ->
        current_user = conn.assigns.current_user

        matches =
          phone_numbers
          |> Accounts.list_users_by_phone_numbers(exclude_id: current_user.id, limit: @max_contact_match_numbers)
          |> Enum.reject(fn candidate ->
            Accounts.blocked?(current_user.id, candidate.id) or Accounts.blocked?(candidate.id, current_user.id)
          end)
          |> Enum.map(&render_contact_match(&1, current_user))

        json(conn, %{matches: matches, total: length(matches)})
    end
  end

  def match_contacts(conn, _params) do
    conn |> put_status(400) |> json(%{error: "phoneNumbers must be an array"})
  end

  def update_profile(conn, params) do
    id = params["userId"] || conn.assigns.current_user.id
    current_id = conn.assigns.current_user.id

    if id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      with {:ok, phone_attrs} <- normalize_phone_update(params) do
        # Filter allowed params
        update_attrs =
          %{}
          |> Map.merge(if params["profileImage"], do: %{profile_image: params["profileImage"]}, else: %{})
          |> Map.merge(
            if Map.has_key?(params, "pushToken"),
              do: %{push_token: params["pushToken"]},
              else: %{}
          )
          |> Map.merge(
            if Map.has_key?(params, "push_token"),
              do: %{push_token: params["push_token"]},
              else: %{}
          )
          |> Map.merge(phone_attrs)
          |> Map.merge(if params["name"], do: %{name: params["name"]}, else: %{})
          |> Map.merge(if params["username"], do: %{username: params["username"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "showLastSeen"), do: %{show_last_seen: params["showLastSeen"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "showOnlineStatus"), do: %{show_online_status: params["showOnlineStatus"]}, else: %{})
          |> Map.merge(if params["bio"], do: %{bio: params["bio"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "autoDeleteTimer"), do: %{auto_delete_timer: params["autoDeleteTimer"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyForward"), do: %{privacy_forward: params["privacyForward"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyCalls"), do: %{privacy_calls: params["privacyCalls"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyPhoneNumber"), do: %{privacy_phone_number: params["privacyPhoneNumber"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyProfilePhotos"), do: %{privacy_profile_photos: params["privacyProfilePhotos"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyBio"), do: %{privacy_bio: params["privacyBio"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyGifts"), do: %{privacy_gifts: params["privacyGifts"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacyBirthday"), do: %{privacy_birthday: params["privacyBirthday"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "privacySavedMusic"), do: %{privacy_saved_music: params["privacySavedMusic"]}, else: %{})
          |> Map.merge(if Map.has_key?(params, "dateOfBirth"), do: %{date_of_birth: params["dateOfBirth"]}, else: %{})

        with user when not is_nil(user) <- Accounts.get_user(id),
             {:ok, updated_user} <- Accounts.update_user(user, update_attrs) do
          if Map.has_key?(update_attrs, :push_token) do
            Logger.info(
              "[UserController] push_token updated user_id=#{updated_user.id} token_present=#{is_binary(updated_user.push_token) and String.trim(updated_user.push_token) != ""}"
            )
          end

          json(conn, %{
            success: true,
            userId: updated_user.id,
            username: updated_user.username,
            name: updated_user.name,
            profileImage: updated_user.profile_image,
            pushToken: updated_user.push_token,
            phoneNumber: updated_user.phone_number,
            showLastSeen: updated_user.show_last_seen,
            showOnlineStatus: updated_user.show_online_status,
            bio: updated_user.bio,
            autoDeleteTimer: updated_user.auto_delete_timer,
            privacyForward: updated_user.privacy_forward,
            privacyCalls: updated_user.privacy_calls,
            privacyPhoneNumber: updated_user.privacy_phone_number,
            privacyProfilePhotos: updated_user.privacy_profile_photos,
            privacyBio: updated_user.privacy_bio,
            privacyGifts: updated_user.privacy_gifts,
            privacyBirthday: updated_user.privacy_birthday,
            privacySavedMusic: updated_user.privacy_saved_music,
            dateOfBirth: updated_user.date_of_birth
          })
        else
          nil -> conn |> put_status(404) |> json(%{error: "User not found"})
          {:error, _changeset} -> conn |> put_status(400) |> json(%{error: "Invalid data"})
        end
      else
        {:error, msg} ->
          conn |> put_status(400) |> json(%{error: msg})
      end
    end
  end

  def delete(conn, _params) do
    id = conn.assigns.current_user.id

    case Accounts.get_user(id) do
      nil -> conn |> put_status(404) |> json(%{error: "User not found"})
      user ->
        case Accounts.delete_user(user) do
          {:ok, _} -> json(conn, %{success: true})
          {:error, _} -> conn |> put_status(400) |> json(%{error: "Failed to delete user"})
        end
    end
  end

  def block(conn, %{"blocked_user_id" => blocked_user_id}) do
    user_id = conn.assigns.current_user.id

    case Accounts.block_user(user_id, blocked_user_id) do
      {:ok, _} -> json(conn, %{success: true})
      {:error, _} -> conn |> put_status(400) |> json(%{error: "Failed to block user"})
    end
  end

  def unblock(conn, %{"blocked_user_id" => blocked_user_id}) do
    user_id = conn.assigns.current_user.id

    case Accounts.unblock_user(user_id, blocked_user_id) do
      {:ok, _} -> json(conn, %{success: true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Block not found"})
      {:error, _} -> conn |> put_status(400) |> json(%{error: "Failed to unblock user"})
    end
  end

  def list_blocks(conn, %{"id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      blocked_users = Accounts.list_blocked_users(current_id)
      json(conn, Enum.map(blocked_users, fn user ->
        %{
          userId: user.id,
          username: user.username,
          name: user.name,
          profileImage: user.profile_image
        }
      end))
    end
  end

  defp render_user(conn, user, viewer) do
    is_self = viewer && viewer.id == user.id

    phone_number =
      cond do
        is_self -> user.phone_number
        user.privacy_phone_number == "everybody" -> user.phone_number
        true -> nil
      end

    json(conn, %{
      userId: user.id,
      username: user.username,
      name: user.name,
      phoneNumber: phone_number,
      publicKey: user.public_key,
      identityKey: user.identity_key,
      profileImage: user.profile_image,
      online: if(user.show_online_status, do: user.is_online, else: false),
      lastSeen: if(user.show_last_seen, do: user.last_seen, else: nil),
      showLastSeen: user.show_last_seen,
      showOnlineStatus: user.show_online_status,
      bio: user.bio,
      autoDeleteTimer: user.auto_delete_timer,
      privacyForward: user.privacy_forward,
      privacyCalls: user.privacy_calls,
      privacyPhoneNumber: user.privacy_phone_number,
      privacyProfilePhotos: user.privacy_profile_photos,
      privacyBio: user.privacy_bio,
      privacyGifts: user.privacy_gifts,
      privacyBirthday: user.privacy_birthday,
      privacySavedMusic: user.privacy_saved_music,
      dateOfBirth: user.date_of_birth
    })
  end

  defp render_contact_match(user, _viewer) do
    %{
      userId: user.id,
      username: user.username,
      name: user.name,
      phoneNumber: if(user.privacy_phone_number == "everybody", do: user.phone_number, else: nil),
      publicKey: user.public_key,
      identityKey: user.identity_key,
      profileImage: user.profile_image
    }
  end

  defp normalize_phone_update(params) do
    if Map.has_key?(params, "phoneNumber") do
      case params["phoneNumber"] do
        nil ->
          {:ok, %{phone_number: nil}}

        phone when is_binary(phone) ->
          if String.trim(phone) == "" do
            {:ok, %{phone_number: nil}}
          else
            case Accounts.normalize_phone_number(phone) do
              nil -> {:error, "Invalid phone number format"}
              normalized_phone -> {:ok, %{phone_number: normalized_phone}}
            end
          end

        _ ->
          {:error, "Invalid phone number format"}
      end
    else
      {:ok, %{}}
    end
  end
end
