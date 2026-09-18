defmodule Vibe.AI.VideoEditJobs do
  @moduledoc """
  Async job wrapper for `Vibe.AI.VideoEditor.edit_video/4`.

  Stores per-job state in the `:ai_video_edit_jobs` ETS table so callers can
  poll phase transitions without blocking on the multi-minute pipeline.
  """

  @table :ai_video_edit_jobs

  @spec start(binary(), String.t(), String.t(), keyword()) :: {:ok, String.t()}
  def start(bytes, mime_type, prompt, opts \\ []) do
    job_id = Ecto.UUID.generate()
    owner_id = Keyword.get(opts, :owner_id)

    :ets.insert(@table, {job_id, %{
      phase: "queued",
      started_at: System.monotonic_time(:millisecond),
      owner_id: owner_id,
      result: nil,
      error: nil
    }})

    Task.Supervisor.start_child(Vibe.TaskSupervisor, fn ->
      run(job_id, bytes, mime_type, prompt, opts)
    end)

    {:ok, job_id}
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(job_id) do
    case :ets.lookup(@table, job_id) do
      [{^job_id, state}] ->
        now = System.monotonic_time(:millisecond)
        elapsed_ms = now - state.started_at

        base = %{
          phase: state.phase,
          elapsed_ms: elapsed_ms,
          owner_id: state.owner_id
        }

        response =
          case state.phase do
            "done" ->
              Map.merge(base, state.result || %{})

            "error" ->
              Map.put(base, :error, state.error)

            _ ->
              base
          end

        {:ok, response}

      [] ->
        {:error, :not_found}
    end
  end

  # -- private ----------------------------------------------------------------

  defp run(job_id, bytes, mime_type, prompt, opts) do
    opts = Keyword.put(opts, :on_phase, fn phase -> put_phase(job_id, phase) end)

    case Vibe.AI.VideoEditor.edit_video(bytes, mime_type, prompt, opts) do
      {:ok, %{bytes: video_bytes, mime_type: out_mime, interaction_id: id}} ->
        update_state(job_id, fn state ->
          %{state |
            phase: "done",
            result: %{
              video_b64: Base.encode64(video_bytes),
              mime_type: out_mime,
              interaction_id: id
            }
          }
        end)

      {:error, reason} ->
        update_state(job_id, fn state ->
          %{state | phase: "error", error: safe_to_string(reason)}
        end)
    end
  rescue
    e ->
      update_state(job_id, fn state ->
        %{state | phase: "error", error: Exception.message(e)}
      end)
  catch
    kind, value ->
      update_state(job_id, fn state ->
        %{state | phase: "error", error: inspect({kind, value})}
      end)
  end

  defp put_phase(job_id, phase) do
    update_state(job_id, fn state -> %{state | phase: phase} end)
    :ok
  end

  defp update_state(job_id, fun) do
    case :ets.lookup(@table, job_id) do
      [{^job_id, state}] -> :ets.insert(@table, {job_id, fun.(state)})
      [] -> :ok
    end
  end

  defp safe_to_string(reason) when is_binary(reason), do: reason
  defp safe_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp safe_to_string(reason) do
    String.Chars.impl_for(reason)
    |> case do
      nil -> inspect(reason)
      _ -> to_string(reason)
    end
  end
end
