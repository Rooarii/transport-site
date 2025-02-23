defmodule Transport.Jobs.ResourceHistoryAndValidationDispatcherJob do
  @moduledoc """
  Job in charge of dispatching multiple `ResourceHistoryJob`
  """
  use Oban.Worker, unique: [period: 60 * 60 * 5], tags: ["history"], max_attempts: 5
  require Logger
  import Ecto.Query
  alias DB.{Dataset, Repo, Resource}

  @impl Oban.Worker
  def perform(_job) do
    resource_ids = Enum.map(resources_to_historise(), & &1.id)

    Logger.debug("Dispatching #{Enum.count(resource_ids)} ResourceHistoryJob jobs")

    resource_ids
    |> Enum.map(fn resource_id ->
      %{resource_id: resource_id} |> Transport.Jobs.ResourceHistoryJob.historize_and_validate_job()
    end)
    |> Oban.insert_all()

    :ok
  end

  def resources_to_historise(resource_id \\ nil) do
    base_query =
      Resource.base_query()
      |> join(:inner, [resource: r], d in DB.Dataset, on: d.id == r.dataset_id and d.is_active, as: :dataset)
      |> where([resource: r], not is_nil(r.url) and not is_nil(r.title))
      |> where([resource: r], not r.is_community_resource)
      |> where([resource: r], like(r.url, "http%"))
      |> preload(:dataset)

    query = if is_nil(resource_id), do: base_query, else: where(base_query, [resource: r], r.id == ^resource_id)

    query
    |> Repo.all()
    |> Enum.reject(
      &(Resource.is_real_time?(&1) or Resource.is_documentation?(&1) or Dataset.should_skip_history?(&1.dataset))
    )
  end
end

defmodule Transport.Jobs.ResourceHistoryJob do
  @moduledoc """
  Job historicising a single resource
  """
  use Oban.Worker, unique: [period: 60 * 60 * 5, fields: [:args, :queue, :worker]], tags: ["history"], max_attempts: 5
  require Logger
  import Ecto.Query
  alias Transport.Shared.Schemas.Wrapper, as: Schemas
  alias DB.{Resource, ResourceHistory}
  import Transport.Jobs.Workflow.Notifier, only: [notify_workflow: 2]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"resource_id" => resource_id}} = job) do
    Logger.info("Running ResourceHistoryJob for resource##{resource_id}")

    resource_id
    |> Transport.Jobs.ResourceHistoryAndValidationDispatcherJob.resources_to_historise()
    |> handle_history(job)
  end

  defp handle_history([], %Oban.Job{} = job) do
    reason = "Resource should not be historicised"
    notify_workflow(job, %{"success" => false, "job_id" => job.id, "reason" => reason})
    {:cancel, reason}
  end

  defp handle_history([%Resource{} = resource], %Oban.Job{} = job) do
    path = download_path(resource)

    notification =
      try do
        %{resource_history_id: resource_history_id} = resource |> download_resource(path) |> process_download(resource)
        %{"success" => true, "job_id" => job.id, "output" => %{resource_history_id: resource_history_id}}
      rescue
        e -> %{"success" => false, "job_id" => job.id, "reason" => inspect(e)}
      after
        remove_file(path)
      end

    notify_workflow(job, notification)
    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  defp process_download({:error, message}, %Resource{id: resource_id}) do
    # Good opportunity to add a :telemetry event
    # Consider storing in our database that the resource
    # was not available.
    Logger.debug("Got an error while downloading resource##{resource_id}: #{message}")
  end

  defp process_download({:ok, resource_path, headers, body}, %Resource{} = resource) do
    download_datetime = DateTime.utc_now()

    hash = resource_hash(resource, resource_path)

    case should_store_resource?(resource, hash) do
      true ->
        filename = upload_filename(resource, download_datetime)

        base = %{
          download_datetime: download_datetime,
          uuid: Ecto.UUID.generate(),
          http_headers: headers,
          filename: filename,
          permanent_url: Transport.S3.permanent_url(:history, filename),
          resource_url: resource.url,
          resource_latest_url: resource.latest_url,
          title: resource.title,
          format: resource.format,
          dataset_id: resource.dataset_id,
          schema_name: resource.schema_name,
          schema_version: resource.schema_version,
          latest_schema_version_to_date: latest_schema_version_to_date(resource)
        }

        data =
          case is_zip?(resource) do
            true ->
              total_compressed_size = hash |> Enum.map(& &1.compressed_size) |> Enum.sum()

              Map.merge(base, %{
                zip_metadata: hash,
                filenames: hash |> Enum.map(& &1.file_name),
                total_uncompressed_size: hash |> Enum.map(& &1.uncompressed_size) |> Enum.sum(),
                total_compressed_size: total_compressed_size,
                filesize: total_compressed_size
              })

            false ->
              %{size: size} = File.stat!(resource_path)
              Map.merge(base, %{content_hash: hash, filesize: size})
          end

        Transport.S3.upload_to_s3!(:history, body, filename)
        %{id: resource_history_id} = store_resource_history!(resource, data)

        %{resource_history_id: resource_history_id}

      {false, history} ->
        # Good opportunity to add a :telemetry event
        Logger.debug("skipping historization for resource##{resource.id} because resource did not change")
        touch_resource_history!(history)
        %{resource_history_id: history.id}

      false ->
        Logger.debug("Failed historization for resource##{resource.id}")
        {:error, "historization failed"}
    end
  end

  @doc """
  Determine if we would historicise a payload now.

  We should historicise a resource if:
  - we never historicised it
  - the latest ResourceHistory payload is different than the current state
  """
  def should_store_resource?(_, []), do: false
  def should_store_resource?(_, nil), do: false

  def should_store_resource?(%Resource{id: resource_id}, resource_hash) do
    history =
      ResourceHistory
      |> where([r], r.resource_id == ^resource_id)
      |> order_by(desc: :inserted_at)
      |> limit(1)
      |> DB.Repo.one()

    case {history, is_same_resource?(history, resource_hash)} do
      {nil, _} -> true
      {_history, false} -> true
      {history, true} -> {false, history}
    end
  end

  @doc """
  Determines if a ZIP metadata payload is the same that was stored in
  the latest resource_history's row in the database by comparing sha256
  hashes for all files in the ZIP.
  """
  def is_same_resource?(%ResourceHistory{payload: %{"zip_metadata" => rh_zip_metadata}}, zip_metadata) do
    MapSet.equal?(set_of_sha256(rh_zip_metadata), set_of_sha256(zip_metadata))
  end

  def is_same_resource?(%ResourceHistory{payload: %{"content_hash" => rh_content_hash}}, content_hash) do
    rh_content_hash == content_hash
  end

  def is_same_resource?(nil, _), do: false

  def set_of_sha256(items) do
    items |> Enum.map(&{map_get(&1, :file_name), map_get(&1, :sha256)}) |> MapSet.new()
  end

  defp resource_hash(%Resource{} = resource, resource_path) do
    case is_zip?(resource) do
      true ->
        try do
          Transport.ZipMetaDataExtractor.extract!(resource_path)
        rescue
          _ ->
            Logger.debug("Cannot compute ZIP metadata for resource##{resource.id}")
            nil
        end

      false ->
        Hasher.get_file_hash(resource_path)
    end
  end

  def map_get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp is_zip?(%Resource{format: format}), do: format in ["NeTEx", "GTFS"]

  defp store_resource_history!(%Resource{datagouv_id: datagouv_id, id: resource_id}, payload) do
    Logger.debug("Saving ResourceHistory for resource##{resource_id}")

    %ResourceHistory{
      datagouv_id: datagouv_id,
      resource_id: resource_id,
      payload: payload,
      last_up_to_date_at: DateTime.utc_now()
    }
    |> DB.Repo.insert!()
  end

  defp touch_resource_history!(%ResourceHistory{id: id, resource_id: resource_id} = history) do
    Logger.debug("Touching unchanged ResourceHistory #{id} for resource##{resource_id}")

    history |> Ecto.Changeset.change(%{last_up_to_date_at: DateTime.utc_now()}) |> DB.Repo.update!()
  end

  defp download_path(%Resource{id: resource_id}) do
    System.tmp_dir!() |> Path.join("resource_#{resource_id}_download")
  end

  defp download_resource(%Resource{id: resource_id, url: url}, file_path) do
    case http_client().get(url, [], follow_redirect: true, recv_timeout: 180_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body} = r} ->
        Logger.debug("Saving resource##{resource_id} to #{file_path}")
        File.write!(file_path, body)
        {:ok, file_path, relevant_http_headers(r), body}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, "Got a non 200 status: #{status}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Got an error: #{reason}"}
    end
  end

  def http_client, do: Transport.Shared.Wrapper.HTTPoison.impl()

  def remove_file(path), do: File.rm(path)

  def upload_filename(%Resource{id: resource_id} = resource, %DateTime{} = dt) do
    time = Calendar.strftime(dt, "%Y%m%d.%H%M%S.%f")

    "#{resource_id}/#{resource_id}.#{time}#{file_extension(resource)}"
  end

  @doc """
  Guess an appropriate file extension according to a format

    iex> file_extension(%DB.Resource{format: "GTFS"})
    ".zip"

    iex> file_extension(%DB.Resource{format: ".csv"})
    ".csv"

    iex> file_extension(%DB.Resource{format: "HTML"})
    ".html"

    iex> file_extension(%DB.Resource{format: ".csv.zip"})
    ".csv.zip"
  """
  def file_extension(%Resource{format: format} = resource) do
    case is_zip?(resource) do
      true ->
        ".zip"

      false ->
        "." <> (format |> String.downcase() |> String.replace_prefix(".", ""))
    end
  end

  def relevant_http_headers(%HTTPoison.Response{headers: headers}) do
    headers_to_keep = [
      "content-disposition",
      "content-encoding",
      "content-length",
      "content-type",
      "etag",
      "expires",
      "if-modified-since",
      "last-modified"
    ]

    headers |> Enum.into(%{}, fn {h, v} -> {String.downcase(h), v} end) |> Map.take(headers_to_keep)
  end

  defp latest_schema_version_to_date(%Resource{schema_name: nil}), do: nil

  defp latest_schema_version_to_date(%Resource{schema_name: schema_name}) do
    Schemas.latest_version(schema_name)
  end

  def historize_and_validate_job(%{resource_id: resource_id}, options \\ []) do
    history_options = options |> Keyword.get(:history_options, []) |> Transport.Jobs.Workflow.kw_to_map()
    validation_custom_args = options |> Keyword.get(:validation_custom_args, %{})

    # jobs is a list of jobs that will be enqueued as a workflow.
    # if ResourceHistoryJob is a success, ResourceHistoryValidationJob will be enqueued.
    jobs = [
      [Transport.Jobs.ResourceHistoryJob, %{}, history_options],
      [Transport.Jobs.ResourceHistoryValidationJob, validation_custom_args, %{}]
    ]

    Transport.Jobs.Workflow.new(%{jobs: jobs, first_job_args: %{resource_id: resource_id}})
  end
end
