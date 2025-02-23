defmodule TransportWeb.DatasetController do
  use TransportWeb, :controller
  alias Datagouvfr.Authentication
  alias Datagouvfr.Client.Datasets
  alias DB.{AOM, Commune, Dataset, DatasetGeographicView, Region, Repo}
  alias Transport.ClimateResilienceBill
  import Ecto.Query

  import TransportWeb.DatasetView,
    only: [availability_number_days: 0, days_notifications_sent: 0, max_nb_history_resources: 0]

  import Phoenix.HTML
  require Logger

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(%Plug.Conn{} = conn, params), do: list_datasets(conn, params, true)

  @spec list_datasets(Plug.Conn.t(), map(), boolean) :: Plug.Conn.t()
  def list_datasets(%Plug.Conn{} = conn, %{} = params, count_by_region \\ false) do
    conn =
      case count_by_region do
        true -> assign(conn, :regions, get_regions(params))
        false -> conn
      end

    conn
    |> assign(:datasets, get_datasets(params))
    |> assign(:types, get_types(params))
    |> assign(:licences, get_licences(params))
    |> assign(:number_realtime_datasets, get_realtime_count(params))
    |> assign(:number_climate_resilience_bill_datasets, climate_resilience_bill_count(params))
    |> assign(:order_by, params["order_by"])
    |> assign(:q, Map.get(params, "q"))
    |> put_empty_message(params)
    |> put_category_custom_message(params)
    |> put_climate_resilience_bill_message(params)
    |> put_page_title(params)
    |> render("index.html")
  end

  @spec details(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def details(%Plug.Conn{} = conn, %{"slug" => slug_or_id}) do
    with {:ok, dataset} <- Dataset.get_by_slug(slug_or_id),
         {:ok, territory} <- Dataset.get_territory(dataset) do
      conn
      |> assign(:dataset, dataset)
      |> assign(:resources_related_files, DB.Dataset.get_resources_related_files(dataset))
      |> assign(:territory, territory)
      |> assign(:site, Application.get_env(:oauth2, Authentication)[:site])
      |> assign(:is_subscribed, Datasets.current_user_subscribed?(conn, dataset.datagouv_id))
      |> assign(:other_datasets, Dataset.get_other_datasets(dataset))
      |> assign(:resources_infos, resources_infos(dataset))
      |> assign(
        :history_resources,
        Transport.History.Fetcher.history_resources(dataset,
          max_records: max_nb_history_resources(),
          preload_validations: true
        )
      )
      |> assign(:latest_resources_history_infos, DB.ResourceHistory.latest_dataset_resources_history_infos(dataset.id))
      |> assign(:notifications_sent, DB.Notification.recent_reasons_binned(dataset, days_notifications_sent()))
      |> assign(:dataset_scores, DB.DatasetScore.get_latest_scores(dataset, Ecto.Enum.values(DB.DatasetScore, :topic)))
      |> assign(:scores_chart, scores_chart(dataset))
      |> put_status(if dataset.is_active, do: :ok, else: :not_found)
      |> render("details.html")
    else
      {:error, msg} ->
        Logger.error("Could not fetch dataset details: #{msg}")
        redirect_to_slug_or_404(conn, slug_or_id)

      nil ->
        redirect_to_slug_or_404(conn, slug_or_id)
    end
  end

  def scores_chart(%DB.Dataset{} = dataset) do
    data = DB.DatasetScore.scores_over_last_days(dataset, 30 * 3)

    # See https://hexdocs.pm/vega_lite/
    # and https://vega.github.io/vega-lite/docs/
    [width: "container", height: 250]
    |> VegaLite.new()
    |> VegaLite.data_from_values(
      data
      |> Enum.reject(&match?(%DB.DatasetScore{score: nil}, &1))
      |> Enum.map(fn %DB.DatasetScore{topic: topic, timestamp: timestamp} = ds ->
        %{"topic" => topic, "score" => DB.DatasetScore.score_for_humans(ds), "date" => timestamp |> DateTime.to_date()}
      end)
    )
    |> VegaLite.mark(:line, interpolate: "step-before", tooltip: true, strokeWidth: 3)
    |> VegaLite.encode_field(:x, "date", type: :temporal)
    |> VegaLite.encode_field(:y, "score", type: :quantitative)
    |> VegaLite.encode_field(:color, "topic", type: :nominal)
    |> VegaLite.config(axis: [grid: false])
    |> VegaLite.to_spec()
  end

  def validators_to_use,
    do: [
      Transport.Validators.GTFSTransport,
      Transport.Validators.GTFSRT,
      Transport.Validators.TableSchema,
      Transport.Validators.EXJSONSchema,
      Transport.Validators.GBFSValidator
    ]

  def resources_infos(dataset) do
    %{
      unavailabilities: unavailabilities(dataset),
      resources_updated_at: DB.Dataset.resources_content_updated_at(dataset),
      validations: DB.MultiValidation.dataset_latest_validation(dataset.id, validators_to_use()),
      gtfs_rt_entities: gtfs_rt_entities(dataset)
    }
  end

  @spec gtfs_rt_entities(Dataset.t()) :: map()
  def gtfs_rt_entities(%Dataset{id: dataset_id, type: "public-transit"}) do
    recent_limit = Transport.Jobs.GTFSRTMetadataJob.datetime_limit()

    DB.Resource.base_query()
    |> join(:inner, [resource: r], rm in DB.ResourceMetadata, on: r.id == rm.resource_id, as: :metadata)
    |> where(
      [resource: r, metadata: rm],
      r.dataset_id == ^dataset_id and r.format == "gtfs-rt" and rm.inserted_at > ^recent_limit
    )
    |> select([metadata: rm], %{resource_id: rm.resource_id, feed_type: fragment("UNNEST(?)", rm.features)})
    |> distinct(true)
    |> DB.Repo.all()
    |> Enum.reduce(%{}, fn %{resource_id: resource_id, feed_type: feed_type}, acc ->
      # See https://hexdocs.pm/elixir/Map.html#update/4
      # > If key is not present in map, default is inserted as the value of key.
      # The default value **will not be passed through the update function**.
      Map.update(acc, resource_id, MapSet.new([feed_type]), fn old_val -> MapSet.put(old_val, feed_type) end)
    end)
  end

  def gtfs_rt_entities(%Dataset{}), do: %{}

  @spec by_aom(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def by_aom(%Plug.Conn{} = conn, %{"aom" => id} = params) do
    error_msg = dgettext("errors", "AOM %{id} does not exist", id: id)
    by_territory(conn, AOM |> where([a], a.id == ^id), params, error_msg)
  end

  @spec by_region(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def by_region(%Plug.Conn{} = conn, %{"region" => id} = params) do
    error_msg = dgettext("errors", "Region %{id} does not exist", id: id)
    by_territory(conn, Region |> where([r], r.id == ^id), params, error_msg, true)
  end

  @spec by_commune_insee(Plug.Conn.t(), map) :: Plug.Conn.t()
  def by_commune_insee(%Plug.Conn{} = conn, %{"insee_commune" => insee} = params) do
    error_msg =
      dgettext(
        "errors",
        "Impossible to find a city with the insee code %{insee}",
        insee: insee
      )

    by_territory(conn, Commune |> where([c], c.insee == ^insee), params, error_msg)
  end

  defp unavailabilities(%Dataset{id: id, resources: resources}) do
    Transport.Cache.API.fetch("unavailabilities_dataset_#{id}", fn ->
      resources
      |> Enum.into(%{}, fn resource ->
        {resource.id,
         DB.ResourceUnavailability.availability_over_last_days(
           resource,
           availability_number_days()
         )}
      end)
    end)
  end

  defp by_territory(conn, territory, params, error_msg, count_by_region \\ false) do
    territory
    |> Repo.one()
    |> case do
      nil ->
        error_page(conn, error_msg)

      territory ->
        conn
        |> assign(:territory, territory)
        |> list_datasets(params, count_by_region)
    end
  rescue
    Ecto.Query.CastError -> error_page(conn, error_msg)
  end

  @spec error_page(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  defp error_page(conn, msg) do
    conn
    |> put_status(:not_found)
    |> put_view(ErrorView)
    |> assign(:custom_message, msg)
    |> render("404.html")
  end

  @spec get_datasets(map()) :: Scrivener.Page.t()
  def get_datasets(params) do
    config = make_pagination_config(params)

    params
    |> Dataset.list_datasets()
    |> preload([:aom, :region])
    |> Repo.paginate(page: config.page_number)
  end

  @spec clean_datasets_query(map(), String.t()) :: Ecto.Query.t()
  defp clean_datasets_query(params, key_to_delete),
    do: params |> Map.delete(key_to_delete) |> Dataset.list_datasets() |> exclude(:preload)

  @spec get_regions(map()) :: [Region.t()]
  def get_regions(params) do
    sub =
      params
      |> clean_datasets_query("region")
      |> exclude(:order_by)
      |> join(:left, [dataset: d], d_geo in DatasetGeographicView, on: d.id == d_geo.dataset_id, as: :geo_view)
      |> select([dataset: d, geo_view: d_geo], %{id: d.id, region_id: d_geo.region_id})

    Region
    |> join(:left, [r], d in subquery(sub), on: d.region_id == r.id)
    |> group_by([r], [r.id, r.nom])
    |> select([r, d], %{nom: r.nom, id: r.id, count: count(d.id, :distinct)})
    |> order_by([r], r.nom)
    |> Repo.all()
  end

  @spec get_licences(map()) :: [%{licence: binary(), count: non_neg_integer()}]
  def get_licences(params) do
    params
    |> clean_datasets_query("licence")
    |> exclude(:order_by)
    |> group_by([d], fragment("cleaned_licence"))
    |> select([d], %{
      licence:
        fragment("case when licence in ('fr-lo', 'lov2') then 'licence-ouverte' else licence end as cleaned_licence"),
      count: count(d.id)
    })
    |> Repo.all()
    # Licence ouverte should be first
    |> Enum.sort_by(&Map.get(%{"licence-ouverte" => 1}, &1.licence, 0), &>=/2)
  end

  @spec get_types(map()) :: [%{type: binary(), msg: binary(), count: non_neg_integer()}]
  def get_types(params) do
    params
    |> clean_datasets_query("type")
    |> exclude(:order_by)
    |> group_by([d], [d.type])
    |> select([d], %{type: d.type, count: count(d.id, :distinct)})
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn res ->
      %{type: res.type, count: res.count, msg: Dataset.type_to_str(res.type)}
    end)
    |> add_current_type(params["type"])
    |> Enum.reject(fn t -> is_nil(t.msg) end)
  end

  defp add_current_type(results, type) do
    case Enum.any?(results, &(&1.type == type)) do
      true -> results
      false -> results ++ [%{type: type, count: 0, msg: Dataset.type_to_str(type)}]
    end
  end

  @spec climate_resilience_bill_count(map()) :: %{all: non_neg_integer(), true: non_neg_integer()}
  defp climate_resilience_bill_count(params) do
    result =
      params
      |> clean_datasets_query("loi-climat-resilience")
      |> exclude(:order_by)
      |> group_by([d], fragment("'loi-climat-resilience' = any(coalesce(?, '{}'))", d.custom_tags))
      |> select([d], %{
        has_climat_resilience_bill_tag: fragment("'loi-climat-resilience' = any(coalesce(?, '{}'))", d.custom_tags),
        count: count(d.id, :distinct)
      })
      |> Repo.all()

    %{
      all: Enum.reduce(result, 0, fn x, acc -> x.count + acc end),
      true: Enum.find_value(result, 0, fn r -> if r.has_climat_resilience_bill_tag, do: r.count end)
    }
  end

  @spec get_realtime_count(map()) :: %{all: non_neg_integer(), true: non_neg_integer()}
  defp get_realtime_count(params) do
    result =
      params
      |> clean_datasets_query("filter")
      |> exclude(:order_by)
      |> group_by([d], d.has_realtime)
      |> select([d], %{has_realtime: d.has_realtime, count: count(d.id, :distinct)})
      |> Repo.all()
      |> Enum.reduce(%{}, fn r, acc -> Map.put(acc, r.has_realtime, r.count) end)

    # return the total number of datasets (all) and the number of real time datasets (true)
    %{all: Map.get(result, true, 0) + Map.get(result, false, 0), true: Map.get(result, true, 0)}
  end

  @spec redirect_to_slug_or_404(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  defp redirect_to_slug_or_404(conn, slug_or_id) do
    case Integer.parse(slug_or_id) do
      {_id, ""} ->
        redirect_to_dataset(conn, Repo.get_by(Dataset, id: slug_or_id))

      _ ->
        case Repo.get_by(Dataset, datagouv_id: slug_or_id) do
          %Dataset{} = dataset -> redirect_to_dataset(conn, dataset)
          nil -> find_dataset_from_slug(conn, slug_or_id)
        end
    end
  end

  defp find_dataset_from_slug(%Plug.Conn{} = conn, slug) do
    case DB.DatasetHistory.from_old_dataset_slug(slug) do
      %DB.DatasetHistory{dataset_id: dataset_id} ->
        redirect_to_dataset(conn, Repo.get_by(Dataset, id: dataset_id))

      nil ->
        find_dataset_from_datagouv(conn, slug)
    end
  rescue
    Ecto.MultipleResultsError -> redirect_to_dataset(conn, nil)
  end

  defp find_dataset_from_datagouv(%Plug.Conn{} = conn, slug) do
    case Datagouvfr.Client.Datasets.get(slug) do
      {:ok, %{"id" => datagouv_id}} ->
        redirect_to_dataset(conn, Repo.get_by(Dataset, datagouv_id: datagouv_id))

      _ ->
        redirect_to_dataset(conn, nil)
    end
  end

  @spec redirect_to_dataset(Plug.Conn.t(), Dataset.t() | nil) :: Plug.Conn.t()
  defp redirect_to_dataset(conn, nil) do
    conn
    |> put_status(:not_found)
    |> put_view(ErrorView)
    |> render("404.html")
  end

  defp redirect_to_dataset(conn, %Dataset{} = dataset) do
    redirect(conn, to: dataset_path(conn, :details, dataset.slug))
  end

  @spec get_name(Ecto.Queryable.t(), binary()) :: binary()
  defp get_name(territory, id) do
    territory
    |> Repo.get(id)
    |> case do
      nil -> id
      t -> t.nom
    end
  end

  @spec empty_message_by_territory(map()) :: binary()
  defp empty_message_by_territory(%{"aom" => id}) do
    dgettext("page-shortlist", "AOM %{name} has not yet published any datasets", name: get_name(AOM, id))
  end

  defp empty_message_by_territory(%{"region" => id}) do
    dgettext("page-shortlist", "There is no data for region %{name}", name: get_name(Region, id))
  end

  defp empty_message_by_territory(%{"insee_commune" => insee}) do
    name =
      case Repo.get_by(Commune, insee: insee) do
        nil -> insee
        a -> a.nom
      end

    dgettext("page-shortlist", "There is no data for city %{name}", name: name)
  end

  defp empty_message_by_territory(_params), do: dgettext("page-shortlist", "No dataset found")

  @spec put_empty_message(Plug.Conn.t(), map()) :: Plug.Conn.t()
  defp put_empty_message(%Plug.Conn{:assigns => %{:datasets => %{:entries => []}}} = conn, params) do
    case map_size(conn.query_params) do
      0 ->
        message = empty_message_by_territory(params)
        assign(conn, :empty_message, raw(message))

      _ ->
        conn
    end
  end

  defp put_empty_message(conn, _params), do: conn

  @spec put_category_custom_message(Plug.Conn.t(), map()) :: Plug.Conn.t()
  defp put_category_custom_message(conn, params) do
    locale = get_session(conn, :locale)

    case Transport.CustomSearchMessage.get_message(params, locale) do
      nil -> conn
      msg -> assign(conn, :category_custom_message, msg)
    end
  end

  defp put_climate_resilience_bill_message(%Plug.Conn{} = conn, %{} = params) do
    if ClimateResilienceBill.display_data_reuse_panel?(params) do
      conn
      |> assign(:climate_resilience_bill_message, ClimateResilienceBill.data_reuse_message(params, Date.utc_today()))
    else
      conn
    end
  end

  defp put_page_title(conn, %{"region" => id}),
    do:
      assign(
        conn,
        :page_title,
        %{type: dgettext("page-shortlist", "region"), name: get_name(Region, id)}
      )

  defp put_page_title(conn, %{"insee_commune" => insee}) do
    name = Repo.get_by!(Commune, insee: insee).nom

    assign(
      conn,
      :page_title,
      %{type: dgettext("page-shortlist", "city"), name: name}
    )
  end

  defp put_page_title(conn, %{"aom" => id}),
    do:
      assign(
        conn,
        :page_title,
        %{type: "AOM", name: get_name(AOM, id)}
      )

  defp put_page_title(conn, %{"type" => t} = f) when map_size(f) == 1,
    do:
      assign(
        conn,
        :page_title,
        %{type: dgettext("page-shortlist", "category"), name: Dataset.type_to_str(t)}
      )

  defp put_page_title(conn, _), do: conn
end
