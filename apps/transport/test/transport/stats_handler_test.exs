defmodule Transport.StatsHandlerTest do
  use ExUnit.Case, async: true
  import DB.Factory
  import Ecto.Query
  import Transport.StatsHandler

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(DB.Repo)
  end

  test "compute_stats" do
    assert is_map(compute_stats())
  end

  test "count_feed_types_gtfs_rt" do
    resource = insert(:resource, format: "gtfs-rt")
    # should not be used as this is too old
    insert(:resource_metadata,
      features: ["foo"],
      resource_id: resource.id,
      inserted_at: Transport.Jobs.GTFSRTMetadataJob.datetime_limit() |> DateTime.add(-5)
    )

    # Empty cases, should not crash
    insert(:resource_metadata, features: [], resource_id: resource.id)
    insert(:resource_metadata, features: nil, resource_id: resource.id)

    # recent metadata for the resource
    insert(:resource_metadata, features: ["vehicle_positions", "entity"], resource_id: resource.id)
    insert(:resource_metadata, features: ["vehicle_positions", "trip_updates"], resource_id: resource.id)

    # another resource linked to a single metadata
    insert(:resource_metadata,
      features: ["vehicle_positions", "service_alerts"],
      resource: insert(:resource, format: "gtfs-rt")
    )

    assert %{"service_alerts" => 1, "trip_updates" => 1, "vehicle_positions" => 2, "entity" => 1} ==
             count_feed_types_gtfs_rt()
  end

  test "climate_resilience_bill_count" do
    aom = insert(:aom, population_totale: 1_000)
    insert(:dataset, aom: aom, is_active: false, custom_tags: ["loi-climat-resilience"], type: "public-transit")
    insert(:dataset, aom: aom, is_active: true, custom_tags: ["loi-climat-resilience"], type: "public-transit")
    insert(:dataset, aom: aom, is_active: true, custom_tags: ["loi-climat-resilience"], type: "public-transit")

    insert(:dataset,
      aom: aom,
      is_active: true,
      custom_tags: ["loi-climat-resilience", "foo"],
      type: "low-emission-zones"
    )

    assert %{
             climate_resilience_bill_count: %{
               "low-emission-zones" => 1,
               "public-transit" => 2
             }
           } = compute_stats()

    # Stored as expected in the database
    store_stats()

    decimal_1 = Decimal.new(1)
    decimal_2 = Decimal.new(2)

    assert [
             %DB.StatsHistory{metric: "climate_resilience_bill_count::low-emission-zones", value: ^decimal_1},
             %DB.StatsHistory{metric: "climate_resilience_bill_count::public-transit", value: ^decimal_2}
           ] =
             DB.StatsHistory
             |> where([s], like(s.metric, "climate_resilience_bill_count%"))
             |> order_by([s], s.metric)
             |> DB.Repo.all()
  end

  test "store_stats" do
    resource = insert(:resource, format: "gtfs-rt")
    insert(:resource_metadata, features: ["vehicle_positions"], resource_id: resource.id)
    insert(:resource_metadata, features: ["trip_updates"], resource_id: resource.id)

    insert(:resource_metadata, features: ["vehicle_positions"], resource: insert(:resource, format: "gtfs-rt"))

    stats = compute_stats()
    store_stats()
    assert DB.Repo.aggregate(DB.StatsHistory, :count, :id) >= Enum.count(stats)

    all_metrics = DB.StatsHistory |> select([s], s.metric) |> DB.Repo.all()

    stats_metrics =
      stats
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&String.starts_with?(&1, ["gtfs_rt_types", "climate_resilience_bill_count"]))

    assert MapSet.subset?(MapSet.new(stats_metrics), MapSet.new(all_metrics))
    assert Enum.member?(all_metrics, "gtfs_rt_types::vehicle_positions")
    assert Enum.member?(all_metrics, "gtfs_rt_types::trip_updates")

    expected = Decimal.new("2")
    assert %{value: ^expected} = DB.Repo.get_by!(DB.StatsHistory, metric: "gtfs_rt_types::vehicle_positions")
  end

  test "count dataset per format" do
    inactive_dataset = insert(:dataset, is_active: false)
    insert(:resource, dataset_id: inactive_dataset.id, format: format = "xxx")

    active_dataset = insert(:dataset, is_active: true)
    insert(:resource, dataset_id: active_dataset.id, format: format)

    count_resources = count_dataset_with_format(format)

    assert count_resources == 1
  end

  test "compute aom max severity" do
    aom_1 = insert(:aom)
    %{dataset: dataset} = insert_up_to_date_resource_and_friends(max_error: "Error", aom: aom_1)
    insert_up_to_date_resource_and_friends(dataset: dataset, max_error: "Warning")
    insert_outdated_resource_and_friends(dataset: dataset, max_error: "Fatal")

    aoms = compute_aom_gtfs_max_severity()

    assert %{"Error" => 1} == aoms
  end

  test "compute aom max severity bis" do
    aom_1 = insert(:aom)
    insert_up_to_date_resource_and_friends(max_error: "Fatal", aom: aom_1)

    aom_2 = insert(:aom)
    insert_up_to_date_resource_and_friends(max_error: "Fatal", aom: aom_2)

    aom_3 = insert(:aom)
    insert_up_to_date_resource_and_friends(max_error: "Warning", aom: aom_3)

    aom_4 = insert(:aom)
    %{dataset: dataset} = insert_up_to_date_resource_and_friends(max_error: "Information", aom: aom_4)
    insert_outdated_resource_and_friends(dataset: dataset, max_error: "Fatal")

    aoms = compute_aom_gtfs_max_severity()

    assert %{"Fatal" => 2, "Warning" => 1, "Information" => 1} == aoms
  end

  test "uses legal owners to assign datasets to AOMs" do
    aom1 = insert(:aom, population_totale: 1_000_000)
    aom2 = insert(:aom, population_totale: 1_000_000)
    insert(:aom, population_totale: 1_000_000)
    insert(:dataset, type: "public-transit", is_active: true, legal_owners_aom: [aom2], aom: aom1)

    assert %{nb_aoms_with_data: 2, nb_aoms: 3, population_couverte: 2, population_totale: 3} = compute_stats()
  end
end
