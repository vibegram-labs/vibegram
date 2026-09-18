defmodule VibeWeb.VideoEditChannelTest.Serializer do
  @moduledoc false
  def encode!(msg), do: msg
  def fastlane!(msg), do: msg
end

defmodule VibeWeb.VideoEditChannelTest do
  @moduledoc "Join auth, self-polling progress pushes, and terminal-phase stop."

  use ExUnit.Case, async: false

  alias Vibe.AI.VideoEditJobs
  alias VibeWeb.VideoEditChannel

  @table :ai_video_edit_jobs

  setup do
    # Ensure the ETS table exists (the app normally creates it at boot).
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public])
    end

    owner_id = Ecto.UUID.generate()
    job_id = Ecto.UUID.generate()

    :ets.insert(@table, {job_id, %{
      phase: "processing",
      started_at: System.monotonic_time(:millisecond),
      owner_id: owner_id,
      result: nil,
      error: nil
    }})

    on_exit(fn -> :ets.delete_all_objects(@table) end)

    %{owner_id: owner_id, job_id: job_id}
  end

  test "joining with a non-existent job_id returns not_found" do
    assert {:error, %{reason: "not_found"}} =
             VideoEditChannel.join("video_edit:bogus", %{}, socket_for(Ecto.UUID.generate()))
  end

  test "joining with the wrong user returns not_found (same as non-existent)", %{job_id: job_id} do
    stranger_id = Ecto.UUID.generate()

    assert {:error, %{reason: "not_found"}} =
             VideoEditChannel.join("video_edit:#{job_id}", %{}, socket_for(stranger_id))
  end

  test "wrong user and unknown job_id produce the identical error shape", %{job_id: job_id} do
    stranger = Ecto.UUID.generate()
    unknown = Ecto.UUID.generate()

    wrong_user = VideoEditChannel.join("video_edit:#{job_id}", %{}, socket_for(stranger))
    unknown_job = VideoEditChannel.join("video_edit:#{unknown}", %{}, socket_for(stranger))

    assert wrong_user == unknown_job
  end

  test "the owner joins successfully", %{job_id: job_id, owner_id: owner_id} do
    assert {:ok, socket} =
             VideoEditChannel.join("video_edit:#{job_id}", %{}, socket_for(owner_id))

    assert socket.assigns.job_id == job_id
  end

  test "the first poll pushes a progress event with the correct shape", %{job_id: job_id, owner_id: owner_id} do
    {:ok, socket} = VideoEditChannel.join("video_edit:#{job_id}", %{}, socket_for(owner_id))
    assert {:noreply, _socket} = VideoEditChannel.handle_info(:poll, socket)

    assert_receive %Phoenix.Socket.Message{event: "progress", payload: payload}
    assert payload[:success] == true
    assert payload[:phase] == "processing"
    assert is_integer(payload[:elapsed_ms])
    refute Map.has_key?(payload, :owner_id)
  end

  test "no push when the payload has not changed", %{job_id: job_id, owner_id: owner_id} do
    {:ok, socket} = VideoEditChannel.join("video_edit:#{job_id}", %{}, socket_for(owner_id))
    {:noreply, socket} = VideoEditChannel.handle_info(:poll, socket)
    assert_receive %Phoenix.Socket.Message{event: "progress"}

    {:noreply, _socket} = VideoEditChannel.handle_info(:poll, socket)
    refute_receive %Phoenix.Socket.Message{event: "progress"}, 50
  end

  test "a done phase pushes once more then stops rescheduling", %{job_id: job_id, owner_id: owner_id} do
    {:ok, socket} = VideoEditChannel.join("video_edit:#{job_id}", %{}, socket_for(owner_id))

    # Transition to done
    :ets.insert(@table, {job_id, %{
      phase: "done",
      started_at: System.monotonic_time(:millisecond),
      owner_id: owner_id,
      result: %{video_b64: "AAAA", mime_type: "video/mp4", interaction_id: "int-1"},
      error: nil
    }})

    {:noreply, _socket} = VideoEditChannel.handle_info(:poll, socket)

    assert_receive %Phoenix.Socket.Message{event: "progress", payload: payload}
    assert payload[:phase] == "done"
    assert payload[:success] == true
    refute Map.has_key?(payload, :owner_id)

    # No further :poll should be scheduled (we can't directly check the mailbox
    # for process messages, but the channel should not have rescheduled).
    refute_receive :poll, 100
  end

  test "an error phase pushes once more then stops rescheduling", %{job_id: job_id, owner_id: owner_id} do
    {:ok, socket} = VideoEditChannel.join("video_edit:#{job_id}", %{}, socket_for(owner_id))

    :ets.insert(@table, {job_id, %{
      phase: "error",
      started_at: System.monotonic_time(:millisecond),
      owner_id: owner_id,
      result: nil,
      error: "something broke"
    }})

    {:noreply, _socket} = VideoEditChannel.handle_info(:poll, socket)

    assert_receive %Phoenix.Socket.Message{event: "progress", payload: payload}
    assert payload[:phase] == "error"
    assert payload[:success] == true
    assert payload[:error] == "something broke"
    refute Map.has_key?(payload, :owner_id)
  end

  test "terminate returns :ok", %{job_id: job_id, owner_id: owner_id} do
    {:ok, socket} = VideoEditChannel.join("video_edit:#{job_id}", %{}, socket_for(owner_id))
    assert :ok = VideoEditChannel.terminate(:normal, socket)
  end

  defp socket_for(user_id) do
    %Phoenix.Socket{
      assigns: %{user_id: user_id},
      topic: "video_edit:test",
      transport_pid: self(),
      serializer: VibeWeb.VideoEditChannelTest.Serializer,
      joined: true
    }
  end
end
