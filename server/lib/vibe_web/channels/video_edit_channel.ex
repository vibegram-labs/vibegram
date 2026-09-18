defmodule VibeWeb.VideoEditChannel do
  @moduledoc """
  Real-time push for AI video-edit job progress.
  Self-polls `Vibe.AI.VideoEditJobs.status/1` on an interval and pushes
  `"progress"` events when the payload changes — same shape as the HTTP
  poll endpoint (`edit_video_status/2`), minus `:owner_id`, plus `:success`.
  """

  use Phoenix.Channel

  alias Vibe.AI.VideoEditJobs

  @poll_interval_ms 750

  @impl true
  def join("video_edit:" <> job_id, _params, socket) do
    user_id = socket.assigns[:user_id]

    case VideoEditJobs.status(job_id) do
      {:ok, %{owner_id: ^user_id}} ->
        socket =
          socket
          |> assign(:job_id, job_id)
          |> assign(:last_payload, nil)

        schedule_poll()
        {:ok, socket}

      {:ok, %{owner_id: _other}} ->
        {:error, %{reason: "not_found"}}

      {:error, :not_found} ->
        {:error, %{reason: "not_found"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "not_found"}}

  @impl true
  def handle_info(:poll, socket) do
    case VideoEditJobs.status(socket.assigns.job_id) do
      {:ok, status_map} ->
        payload = status_map |> Map.delete(:owner_id) |> Map.put(:success, true)

        socket =
          if payload != socket.assigns.last_payload do
            push(socket, "progress", payload)
            assign(socket, :last_payload, payload)
          else
            socket
          end

        terminal? = status_map.phase in ["done", "error"]

        if terminal? do
          {:noreply, socket}
        else
          schedule_poll()
          {:noreply, socket}
        end

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket), do: :ok

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
