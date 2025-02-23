defmodule GBFS.PageCacheTest do
  # NOTE: this test will be polluted by other controller tests since it touches the same cache.
  # We set async to false to avoid that.
  use GBFS.ConnCase, async: false
  use GBFS.ExternalCase
  import Mox
  import AppConfigHelper
  import ExUnit.CaptureLog

  setup :verify_on_exit!

  setup do
    setup_telemetry_handler()
  end

  def run_query(conn, url) do
    response =
      conn
      |> get(url)

    assert response.status == 200
    assert response.resp_body |> Jason.decode!() |> Map.has_key?("data")

    # NOTE: not using json_response directly because it currently does not catch bogus duplicate "charset"
    assert response |> get_resp_header("content-type") == ["application/json; charset=utf-8"]
  end

  test "caches HTTP 200 output", %{conn: conn} do
    # during most tests, cache is disabled at runtime to avoid polluting results.
    # in the current case though, we want to avoid that & make sure caching is in effect.
    # I can't put that in a "setup" trivially because nested setups are not supported &
    # the whole thing would need a bit more work.
    enable_cache()

    url = "/gbfs/nantes/station_information.json"

    Transport.HTTPoison.Mock |> expect(:get, 1, fn _url -> {:ok, %HTTPoison.Response{status_code: 200, body: "{}"}} end)

    # first call must result in call to third party
    run_query(conn, url)

    # a cache entry must have been created, with proper expiry time
    cache_key = PageCache.build_cache_key(url)
    assert Cachex.get!(:gbfs, cache_key) != nil
    assert_in_delta Cachex.ttl!(:gbfs, cache_key), 30_000, 200

    # second call must not result into call to third party
    Transport.HTTPoison.Mock |> expect(:get, 0, fn _url -> nil end)
    run_query(conn, url)

    # fake time passed, which normally results in expiry
    Cachex.del!(:gbfs, cache_key)

    # last call must again result in call to third party
    Transport.HTTPoison.Mock |> expect(:get, 1, fn _url -> {:ok, %HTTPoison.Response{status_code: 200, body: "{}"}} end)

    run_query(conn, url)
  end

  test "network_name" do
    assert nil == PageCache.network_name("/foo")
    assert nil == PageCache.network_name("/gbfs")
    assert "nantes" == PageCache.network_name("/gbfs/nantes/gbfs.json")
    assert "nantes" == PageCache.network_name("/gbfs/nantes/station_information.json")
    assert "st_helene" == PageCache.network_name("/gbfs/st_helene/station_information.json")
    assert "cergy-pontoise" == PageCache.network_name("/gbfs/cergy-pontoise/station_information.json")
  end

  test "mirrors non-200 status code", %{conn: conn} do
    external_telemetry_event = telemetry_event("toulouse", :external)
    internal_telemetry_event = telemetry_event("toulouse", :internal)
    enable_cache()

    url = "/gbfs/toulouse/station_information.json"

    Transport.HTTPoison.Mock |> expect(:get, 1, fn _url -> {:ok, %HTTPoison.Response{status_code: 500}} end)

    # first call must result in call to third party
    {r, logs} = with_log(fn -> conn |> get(url) end)

    assert_received ^internal_telemetry_event
    assert_received ^external_telemetry_event
    assert logs =~ "impossible to query jcdecaux"

    # an underlying 500 will result of a 502
    assert r.status == 502

    # Even if it's an error, a cache entry must have been created, with proper expiry time
    # The resoning behind this is that we don't want to flood the GBFS productor, even if the system is in error
    cache_key = PageCache.build_cache_key(url)
    assert Cachex.get!(:gbfs, cache_key) != nil
    assert_in_delta Cachex.ttl!(:gbfs, cache_key), 30_000, 200

    # Second call must not result into call to third party
    # This is verified by the Mox/expect definition to
    # be called only once.
    r = conn |> get(url)
    assert_received ^external_telemetry_event
    refute_received ^internal_telemetry_event
    assert r.status == 502
  end

  defp telemetry_event(network_name, request_type) do
    {:telemetry_event, [:gbfs, :request, request_type], %{}, %{target: GBFS.Telemetry.target_for_network(network_name)}}
  end

  defp setup_telemetry_handler do
    events = Transport.Telemetry.gbfs_request_event_names()
    events |> Enum.at(1) |> :telemetry.list_handlers() |> Enum.map(& &1.id) |> Enum.each(&:telemetry.detach/1)
    test_pid = self()
    # inspired by https://github.com/dashbitco/broadway/blob/main/test/broadway_test.exs
    :telemetry.attach_many(
      "test-handler-#{System.unique_integer()}",
      events,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )
  end

  # To be implemented later, but for now the error handling on that (Sentry etc)
  # is not clear (#1378)
  @tag :pending
  test "does not cache anything if we raise an exception"
end
