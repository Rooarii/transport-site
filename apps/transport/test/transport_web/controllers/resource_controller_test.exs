defmodule TransportWeb.ResourceControllerTest do
  use TransportWeb.ConnCase, async: false
  use TransportWeb.DatabaseCase, cleanup: [:datasets], async: false
  alias DB.{AOM, Dataset, Resource}
  import Plug.Test
  import Mox
  import DB.Factory
  import ExUnit.CaptureLog

  setup :verify_on_exit!

  @service_alerts_file "#{__DIR__}/../../fixture/files/bibus-brest-gtfs-rt-alerts.pb"

  setup do
    Mox.stub_with(Transport.DataVisualization.Mock, Transport.DataVisualization.Impl)
    Mox.stub_with(Transport.ValidatorsSelection.Mock, Transport.ValidatorsSelection.Impl)

    {:ok, _} =
      %Dataset{
        created_at: DateTime.utc_now(),
        last_update: DateTime.utc_now(),
        slug: "slug-1",
        resources: [
          %Resource{
            last_update: DateTime.utc_now() |> DateTime.add(-6, :hour),
            last_import: DateTime.utc_now() |> DateTime.add(-1, :hour),
            url: "https://link.to/angers.zip",
            datagouv_id: "1",
            format: "GTFS",
            title: "GTFS",
            description: "Une _très_ belle ressource"
          },
          %Resource{
            last_update: DateTime.utc_now() |> DateTime.add(-6, :hour),
            last_import: DateTime.utc_now() |> DateTime.add(-1, :hour),
            url: "http://link.to/angers.zip?foo=bar",
            datagouv_id: "2",
            format: "GTFS"
          },
          %Resource{
            last_update: DateTime.utc_now() |> DateTime.add(-6, :hour),
            last_import: DateTime.utc_now() |> DateTime.add(-1, :hour),
            url: "http://link.to/gbfs",
            datagouv_id: "3",
            format: "gbfs"
          },
          %Resource{
            last_update: DateTime.utc_now() |> DateTime.add(-6, :hour),
            last_import: DateTime.utc_now() |> DateTime.add(-1, :hour),
            url: "http://link.to/file",
            datagouv_id: "4",
            schema_name: "etalab/foo",
            format: "json"
          },
          %Resource{
            last_update: DateTime.utc_now() |> DateTime.add(-6, :hour),
            last_import: DateTime.utc_now() |> DateTime.add(-1, :hour),
            url: "http://link.to/gtfs-rt",
            datagouv_id: "5",
            format: "gtfs-rt"
          }
        ],
        aom: %AOM{id: 4242, nom: "Angers Métropôle"}
      }
      |> Repo.insert()

    :ok
  end

  test "I can see my datasets", %{conn: conn} do
    %DB.Dataset{datagouv_title: datagouv_title, organization_id: organization_id} = insert(:dataset)

    Datagouvfr.Client.User.Mock
    |> expect(:me, fn _conn -> {:ok, %{"organizations" => [%{"id" => organization_id}]}} end)

    html =
      conn
      |> init_test_session(%{current_user: %{}})
      |> get(resource_path(conn, :datasets_list))
      |> html_response(200)

    assert html =~ datagouv_title
  end

  test "Non existing resource raises a Ecto.NoResultsError (interpreted as a 404 thanks to phoenix_ecto)", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn ->
      conn |> get(resource_path(conn, :details, 0))
    end
  end

  test "GTFS resource with associated NeTEx", %{conn: conn} do
    resource = Resource |> Repo.get_by(datagouv_id: "2")
    insert(:resource_history, resource_id: resource.id, payload: %{"uuid" => uuid = Ecto.UUID.generate()})

    insert(:data_conversion,
      resource_history_uuid: uuid,
      convert_from: "GTFS",
      convert_to: "NeTEx",
      payload: %{"permanent_url" => permanent_url = "https://super-cellar-url.com/netex"}
    )

    html_response = conn |> get(resource_path(conn, :details, resource.id)) |> html_response(200)
    assert html_response =~ "NeTEx"
    assert html_response =~ conversion_path(conn, :get, resource.id, :NeTEx)
    refute html_response =~ permanent_url
  end

  test "GBFS resource with multi-validation sends back 200", %{conn: conn} do
    resource = Resource |> Repo.get_by(datagouv_id: "3")
    assert Resource.is_gbfs?(resource)

    insert(:multi_validation, %{
      resource_history: insert(:resource_history, %{resource_id: resource.id}),
      validator: Transport.Validators.GBFSValidator.validator_name(),
      result: %{"errors_count" => 1},
      metadata: %DB.ResourceMetadata{metadata: %{}}
    })

    Transport.Shared.Schemas.Mock |> expect(:transport_schemas, fn -> %{} end)

    conn = conn |> get(resource_path(conn, :details, resource.id))
    assert conn |> html_response(200) =~ "1 erreur"
  end

  test "resource has its description displayed", %{conn: conn} do
    resource = Resource |> Repo.get_by(datagouv_id: "1")

    assert resource.description == "Une _très_ belle ressource"
    html = conn |> get(resource_path(conn, :details, resource.id)) |> html_response(200)
    assert html =~ "Une <em>très</em> belle ressource"
  end

  test "resource has download availability displayed", %{conn: conn} do
    resource = Resource |> Repo.get_by(datagouv_id: "4")

    Transport.Shared.Schemas.Mock
    |> expect(:schemas_by_type, 1, fn _type -> %{resource.schema_name => %{}} end)

    html = conn |> get(resource_path(conn, :details, resource.id)) |> html_response(200)

    assert html =~ "Disponibilité au téléchargement"
    assert html =~ "download_availability_100"
  end

  test "gtfs-rt resource with error details sends back a 200", %{conn: conn} do
    resource_url = "xxx"

    validation_result = %{
      "errors_count" => 2,
      "warnings_count" => 3,
      "files" => %{
        "gtfs_permanent_url" => "https://example.com/gtfs.zip",
        "gtfs_rt_permanent_url" => "https://example.com/gtfs-rt"
      },
      "errors" => [
        %{
          "title" => "error title",
          "description" => "error description",
          "severity" => "ERROR",
          "error_id" => "E001",
          "errors_count" => 2,
          "errors" => ["sample 1", "foo"]
        },
        %{
          "title" => "warning title",
          "description" => "warning description",
          "severity" => "WARNING",
          "error_id" => "W001",
          "errors_count" => 3,
          "errors" => ["sample 2", "bar", "baz"]
        }
      ]
    }

    dataset = insert(:dataset)
    resource = insert(:resource, dataset_id: dataset.id, url: resource_url, format: "gtfs-rt")

    insert(:multi_validation,
      validator: Transport.Validators.GTFSRT.validator_name(),
      resource_id: resource.id,
      validation_timestamp: DateTime.utc_now(),
      result: validation_result
    )

    resource = Resource |> preload(:dataset) |> DB.Repo.get!(resource.id)

    Transport.HTTPoison.Mock
    |> expect(:get, fn ^resource_url, [], [follow_redirect: true] ->
      {:ok, %HTTPoison.Response{status_code: 200, body: File.read!(@service_alerts_file)}}
    end)

    assert Resource.is_gtfs_rt?(resource)

    content = conn |> get(resource_path(conn, :details, resource.id)) |> html_response(200)

    [
      "2 erreurs",
      "3 avertissements",
      "error title",
      "E001",
      "warning title",
      "W001",
      "sample 1",
      "sample 2",
      validation_result["files"]["gtfs_permanent_url"],
      validation_result["files"]["gtfs_rt_permanent_url"],
      "Prolongation des travaux rue de Kermaria",
      "Impossible de déterminer le fichier GTFS à utiliser",
      "Validations précédentes"
    ]
    |> Enum.each(&assert content =~ &1)
  end

  test "gtfs-rt resource with feed decode error", %{conn: conn} do
    %{url: url} = resource = Resource |> Repo.get_by(datagouv_id: "5")

    Transport.HTTPoison.Mock
    |> expect(:get, fn ^url, [], [follow_redirect: true] ->
      {:ok, %HTTPoison.Response{status_code: 502, body: ""}}
    end)

    assert Resource.is_gtfs_rt?(resource)
    content = conn |> get(resource_path(conn, :details, resource.id)) |> html_response(200)

    assert content =~ "Impossible de décoder le flux GTFS-RT"
  end

  test "HEAD request for an HTTP resource", %{conn: conn} do
    resource = Resource |> Repo.get_by(datagouv_id: "2")
    refute Resource.can_direct_download?(resource)

    Transport.HTTPoison.Mock
    |> expect(:head, fn url, [] ->
      assert url == resource.url
      {:ok, %HTTPoison.Response{status_code: 200, headers: [{"Content-Type", "application/zip"}, {"foo", "bar"}]}}
    end)

    conn = conn |> head(resource_path(conn, :download, resource.id))
    assert ["application/zip"] == conn |> get_resp_header("content-type")
    assert ["bar"] == conn |> get_resp_header("foo")
    assert conn.assigns[:original_method] == "HEAD"
    assert conn |> response(200) == ""

    # With a resource that can be directly downloaded
    resource = Resource |> Repo.get_by(datagouv_id: "1")
    assert Resource.can_direct_download?(resource)
    assert conn |> head(resource_path(conn, :download, resource.id)) |> response(404) == ""
  end

  test "downloading a resource that can be directly downloaded", %{conn: conn} do
    resource = Resource |> Repo.get_by(datagouv_id: "1")
    assert Resource.can_direct_download?(resource)

    location = conn |> get(resource_path(conn, :download, resource.id)) |> redirected_to
    assert location == resource.url
  end

  test "downloading a resource that cannot be directly downloaded", %{conn: conn} do
    resource = Resource |> Repo.get_by(datagouv_id: "2")
    refute Resource.can_direct_download?(resource)

    Transport.HTTPoison.Mock
    |> expect(:get, fn url, [], hackney: [follow_redirect: true] ->
      assert url == resource.url
      {:ok, %HTTPoison.Response{status_code: 200, body: "payload", headers: [{"Content-Type", "application/zip"}]}}
    end)

    conn = conn |> get(resource_path(conn, :download, resource.id))
    assert ["application/zip"] == conn |> get_resp_header("content-type")
    assert [~s(attachment; filename="angers.zip")] == conn |> get_resp_header("content-disposition")

    assert conn |> response(200) == "payload"
  end

  test "downloading a resource that cannot be directly downloaded with a filename", %{conn: conn} do
    resource = Resource |> Repo.get_by(datagouv_id: "2")
    refute Resource.can_direct_download?(resource)

    Transport.HTTPoison.Mock
    |> expect(:get, fn url, [], hackney: [follow_redirect: true] ->
      assert url == resource.url

      {:ok,
       %HTTPoison.Response{
         status_code: 200,
         body: "payload",
         headers: [{"Content-Type", "application/zip"}, {"Content-Disposition", ~s(attachment; filename="foo.zip")}]
       }}
    end)

    conn = conn |> get(resource_path(conn, :download, resource.id))
    assert ["application/zip"] == conn |> get_resp_header("content-type")
    assert [~s(attachment; filename="foo.zip")] == conn |> get_resp_header("content-disposition")

    assert conn |> response(200) == "payload"
  end

  test "downloading a resource that cannot be directly downloaded, not found case", %{conn: conn} do
    test_remote_download_error(conn, 404)
  end

  test "downloading a resource that cannot be directly downloaded, remote server error case", %{conn: conn} do
    for status_code <- [500, 502] do
      test_remote_download_error(conn, status_code)
    end
  end

  test "flash message when parent dataset is inactive", %{conn: conn} do
    %{id: dataset_id} = insert(:dataset, %{is_active: false})
    %{id: resource_id} = insert(:resource, %{dataset_id: dataset_id, url: "https://example.com/file"})

    conn = conn |> get(resource_path(conn, :details, resource_id))
    assert conn |> html_response(200) =~ "supprimé de data.gouv.fr"
  end

  test "no flash message when parent dataset is active", %{conn: conn} do
    %{id: dataset_id} = insert(:dataset, %{is_active: true})
    %{id: resource_id} = insert(:resource, %{dataset_id: dataset_id, url: "https://example.com/file"})

    conn = conn |> get(resource_path(conn, :details, resource_id))
    refute conn |> html_response(200) =~ "supprimé de data.gouv.fr"
  end

  test "no validation report section for documentation resources", %{conn: conn} do
    resource =
      insert(:resource, %{
        dataset: insert(:dataset),
        format: "pdf",
        url: "https://example.com/file",
        type: "documentation"
      })

    assert DB.Resource.is_documentation?(resource)

    refute conn |> get(resource_path(conn, :details, resource.id)) |> html_response(200) =~ "Rapport de validation"
  end

  test "GTFS Transport validation is shown", %{conn: conn} do
    %{id: dataset_id} = insert(:dataset)

    %{id: resource_id} =
      insert(:resource, %{
        dataset_id: dataset_id,
        format: "GTFS",
        url: "https://example.com/file"
      })

    conn1 = conn |> get(resource_path(conn, :details, resource_id))
    assert conn1 |> html_response(200) =~ "Pas de validation disponible"

    %{id: resource_history_id} =
      insert(:resource_history, %{
        resource_id: resource_id,
        payload: %{"permanent_url" => permanent_url = "https://example.com/#{Ecto.UUID.generate()}"}
      })

    %{metadata: metadata} =
      insert(:multi_validation, %{
        resource_history_id: resource_history_id,
        validator: Transport.Validators.GTFSTransport.validator_name(),
        result: %{},
        metadata: %DB.ResourceMetadata{
          metadata: %{
            "networks" => ["3CM", "RLV"],
            "networks_start_end_dates" => %{
              "3CM" => %{
                "end_date" => "2022-09-30",
                "start_date" => "2021-03-05"
              },
              "RLV" => %{
                end_date: "2022-11-20",
                start_date: "2022-08-29"
              }
            }
          },
          modes: ["ferry"]
        },
        validation_timestamp: ~U[2022-10-28 14:12:29.041243Z]
      })

    conn2 = conn |> get(resource_path(conn, :details, resource_id))
    assert conn2 |> html_response(200) =~ "Rapport de validation"
    assert conn2 |> html_response(200) =~ "ferry"
    assert conn2 |> html_response(200) =~ "couverture calendaire par réseau"
    assert conn2 |> html_response(200) =~ "3CM"
    assert conn2 |> html_response(200) =~ "30/09/2022"

    assert conn2 |> html_response(200) =~
             ~s{Validation effectuée en utilisant <a href="#{permanent_url}">le fichier GTFS en vigueur</a> le 28/10/2022 à 16h12 Europe/Paris}

    # we remove "networks_start_end_dates" content
    DB.Repo.update!(
      Ecto.Changeset.change(metadata, %{metadata: %{"networks_start_end_dates" => nil, "networks" => ["foo", "bar"]}})
    )

    conn3 = conn |> get(resource_path(conn, :details, resource_id))
    refute conn3 |> html_response(200) =~ "couverture calendaire par réseau"
  end

  test "GTFS-RT validation is shown", %{conn: conn} do
    %{id: dataset_id} = insert(:dataset)
    %{id: gtfs_id} = insert(:resource, format: "GTFS", dataset_id: dataset_id)

    %{id: resource_id} =
      insert(:resource, %{
        dataset_id: dataset_id,
        format: "gtfs-rt",
        url: "https://example.com/file"
      })

    Transport.HTTPoison.Mock
    |> expect(:get, 2, fn _, _, _ -> {:ok, %HTTPoison.Response{status_code: 200, body: ""}} end)

    {conn1, _} = with_log(fn -> conn |> get(resource_path(conn, :details, resource_id)) end)
    assert conn1 |> html_response(200) =~ "Pas de validation disponible"
    # Even without a multi-validation we can validate now as we have a single GTFS resource
    assert conn1 |> html_response(200) =~ "Valider ce GTFS-RT maintenant"

    %{id: resource_history_id} = insert(:resource_history, %{resource_id: resource_id})

    insert(:multi_validation, %{
      resource_history_id: resource_history_id,
      validator: Transport.Validators.GTFSRT.validator_name(),
      result: %{
        "errors" => [
          %{
            "title" => "oops",
            "severity" => "ERROR",
            "error_id" => "id",
            "errors_count" => 1,
            "description" => "oops",
            "errors" => ["oops"]
          }
        ],
        "has_errors" => true,
        "errors_count" => 1,
        "ignore_shapes" => true,
        "files" => %{
          "gtfs_permanent_url" => "url",
          "gtfs_rt_permanent_url" => "url"
        }
      },
      secondary_resource_id: gtfs_id,
      metadata: %DB.ResourceMetadata{metadata: %{}}
    })

    {conn2, _} = with_log(fn -> conn |> get(resource_path(conn, :details, resource_id)) end)
    assert conn2 |> html_response(200) =~ "Rapport de validation"
    assert conn2 |> html_response(200) =~ "1 erreur"
    assert conn2 |> html_response(200) =~ "Les shapes présentes dans le GTFS ont été ignorées"
    assert conn2 |> html_response(200) =~ "Valider ce GTFS-RT maintenant"
    refute conn2 |> html_response(200) =~ "Pas de validation disponible"
  end

  test "Table Schema validation is shown", %{conn: conn} do
    %{id: dataset_id} = insert(:dataset)

    %{id: resource_id} =
      insert(:resource, %{
        dataset_id: dataset_id,
        format: "csv",
        schema_name: schema_name = "etalab/schema-lieux-covoiturage",
        url: "https://example.com/file"
      })

    Transport.Shared.Schemas.Mock
    |> expect(:schemas_by_type, 3, fn type ->
      case type do
        "tableschema" -> %{schema_name => %{}}
        "jsonschema" -> %{}
      end
    end)

    Transport.Shared.Schemas.Mock
    |> expect(:transport_schemas, 2, fn -> %{schema_name => %{"title" => "foo"}} end)

    conn1 = conn |> get(resource_path(conn, :details, resource_id))
    assert conn1 |> html_response(200) =~ "Pas de validation disponible"

    insert(:multi_validation, %{
      resource_history:
        insert(:resource_history, %{resource_id: resource_id, payload: %{"schema_name" => schema_name}}),
      validator: Transport.Validators.TableSchema.validator_name(),
      result: %{"has_errors" => true, "errors_count" => 1, "validation_performed" => true, "errors" => ["oops"]},
      metadata: %DB.ResourceMetadata{metadata: %{}}
    })

    response = conn |> get(resource_path(conn, :details, resource_id))
    assert response |> html_response(200) =~ "Rapport de validation"
    assert response |> html_response(200) =~ "1 erreur"
    assert response |> html_response(200) =~ "oops"
    refute response |> html_response(200) =~ "Pas de validation disponible"
  end

  test "JSON Schema validation is shown", %{conn: conn} do
    %{id: dataset_id} = insert(:dataset)

    %{id: resource_id} =
      insert(:resource, %{
        dataset_id: dataset_id,
        format: "csv",
        schema_name: schema_name = "etalab/zfe",
        url: "https://example.com/file"
      })

    Transport.Shared.Schemas.Mock
    |> expect(:schemas_by_type, 6, fn type ->
      case type do
        "tableschema" -> %{}
        "jsonschema" -> %{schema_name => %{}}
      end
    end)

    Transport.Shared.Schemas.Mock
    |> expect(:transport_schemas, 2, fn -> %{schema_name => %{"title" => "foo"}} end)

    conn1 = conn |> get(resource_path(conn, :details, resource_id))
    assert conn1 |> html_response(200) =~ "Pas de validation disponible"

    insert(:multi_validation, %{
      resource_history:
        insert(:resource_history, %{resource_id: resource_id, payload: %{"schema_name" => schema_name}}),
      validator: Transport.Validators.EXJSONSchema.validator_name(),
      result: %{"has_errors" => true, "errors_count" => 1, "validation_performed" => true, "errors" => ["oops"]},
      metadata: %DB.ResourceMetadata{metadata: %{}}
    })

    response = conn |> get(resource_path(conn, :details, resource_id))
    assert response |> html_response(200) =~ "Rapport de validation"
    assert response |> html_response(200) =~ "1 erreur"
    assert response |> html_response(200) =~ "oops"
    refute response |> html_response(200) =~ "Pas de validation disponible"
  end

  test "does not crash when validation_performed is false", %{conn: conn} do
    %{id: dataset_id} = insert(:dataset)

    %{id: resource_id} =
      insert(:resource, %{
        dataset_id: dataset_id,
        format: "csv",
        schema_name: schema_name = "etalab/zfe",
        url: "https://example.com/file"
      })

    Transport.Shared.Schemas.Mock
    |> expect(:schemas_by_type, 4, fn type ->
      case type do
        "tableschema" -> %{}
        "jsonschema" -> %{schema_name => %{}}
      end
    end)

    conn1 = conn |> get(resource_path(conn, :details, resource_id))
    assert conn1 |> html_response(200) =~ "Pas de validation disponible"

    %{id: resource_history_id} = insert(:resource_history, %{resource_id: resource_id})

    insert(:multi_validation, %{
      resource_history_id: resource_history_id,
      validator: Transport.Validators.EXJSONSchema.validator_name(),
      result: %{"validation_performed" => false}
    })

    conn2 = conn |> get(resource_path(conn, :details, resource_id))
    assert conn2 |> html_response(200) =~ "Pas de validation disponible"
  end

  test "gtfs-rt entities" do
    resource = %{id: resource_id} = insert(:resource, format: "gtfs-rt")
    insert(:resource_metadata, resource_id: resource_id, features: ["b"])
    insert(:resource_metadata, resource_id: resource_id, features: ["a", "d"])
    insert(:resource_metadata, resource_id: resource_id, features: ["c"])
    # too old
    insert(:resource_metadata, resource_id: resource_id, features: ["e"], inserted_at: ~U[2020-01-01 00:00:00Z])

    # we want a sorted list in the output!
    assert ["a", "b", "c", "d"] = TransportWeb.ResourceController.gtfs_rt_entities(resource)
  end

  describe "proxy_statistics" do
    test "requires authentication", %{conn: conn} do
      conn = conn |> get(resource_path(conn, :proxy_statistics))

      assert redirected_to(conn, 302) =~ "/login"
    end

    test "renders successfully with a resource handled by the proxy", %{conn: conn} do
      dataset = insert(:dataset, is_active: true, datagouv_id: Ecto.UUID.generate())

      gtfs_rt_resource =
        insert(:resource,
          dataset: dataset,
          format: "gtfs-rt",
          url: "https://proxy.transport.data.gouv.fr/resource/divia-dijon-gtfs-rt-trip-update"
        )

      assert DB.Resource.served_by_proxy?(gtfs_rt_resource)
      proxy_slug = DB.Resource.proxy_slug(gtfs_rt_resource)
      assert proxy_slug == "divia-dijon-gtfs-rt-trip-update"

      today = Transport.Telemetry.truncate_datetime_to_hour(DateTime.utc_now())

      insert(:metrics,
        target: "proxy:#{proxy_slug}",
        event: "proxy:request:external",
        count: 2,
        period: today
      )

      insert(:metrics,
        target: "proxy:#{proxy_slug}",
        event: "proxy:request:internal",
        count: 1,
        period: today
      )

      Datagouvfr.Client.User.Mock
      |> expect(:me, fn _conn -> {:ok, %{"organizations" => [%{"id" => dataset.organization_id}]}} end)

      html =
        conn
        |> init_test_session(%{current_user: %{}})
        |> get(resource_path(conn, :proxy_statistics))
        |> html_response(200)

      assert html =~ "Statistiques des requêtes gérées par le proxy"
      assert html =~ "<strong>2</strong>\nrequêtes gérées par le proxy au cours des 15 derniers jours"
      assert html =~ "<strong>1</strong>\nrequêtes transmises au serveur source au cours des 15 derniers jours"
    end
  end

  test "SIRI RequestorRef is displayed", %{conn: conn} do
    requestor_ref_value = Ecto.UUID.generate()

    resource =
      insert(:resource,
        format: "SIRI",
        url: "https://example.com/siri",
        dataset: insert(:dataset, custom_tags: ["requestor_ref:#{requestor_ref_value}", "foo"])
      )

    assert DB.Resource.is_siri?(resource)
    assert requestor_ref_value == DB.Resource.requestor_ref(resource)

    html = conn |> get(resource_path(conn, :details, resource.id)) |> html_response(200)
    assert html =~ ~s{<h2 id="siri-authentication">Authentification SIRI</h2>}
    assert html =~ requestor_ref_value
  end

  test "latest_validations_details" do
    resource = insert(:resource, format: "gtfs-rt")

    insert(:multi_validation,
      validator: Transport.Validators.GTFSRT.validator_name(),
      resource_id: resource.id,
      validation_timestamp: DateTime.utc_now() |> DateTime.add(-500),
      result: %{
        "errors" => [
          %{
            "title" => "error title",
            "description" => "error description",
            "severity" => "ERROR",
            "error_id" => "E001",
            "errors_count" => 2,
            "errors" => ["sample 1", "foo"]
          },
          %{
            "title" => "warning title",
            "description" => "warning description",
            "severity" => "WARNING",
            "error_id" => "W001",
            "errors_count" => 3,
            "errors" => ["sample 2", "bar", "baz"]
          }
        ]
      }
    )

    insert(:multi_validation,
      validator: Transport.Validators.GTFSRT.validator_name(),
      resource_id: resource.id,
      validation_timestamp: DateTime.utc_now(),
      result: %{
        "errors" => [
          %{
            "title" => "error title",
            "description" => "error description",
            "severity" => "ERROR",
            "error_id" => "E001",
            "errors_count" => 1,
            "errors" => ["sample 1"]
          },
          %{
            "title" => "error title",
            "description" => "error description 002",
            "severity" => "ERROR",
            "error_id" => "E002",
            "errors_count" => 2,
            "errors" => ["sample 1", "sample 2"]
          }
        ]
      }
    )

    assert %{
             "E001" => %{
               "description" => "error description",
               "errors_count" => 3,
               "occurence" => 2,
               "percentage" => 100
             },
             "E002" => %{
               "description" => "error description 002",
               "errors_count" => 2,
               "occurence" => 1,
               "percentage" => 50
             },
             "W001" => %{
               "description" => "warning description",
               "errors_count" => 3,
               "occurence" => 1,
               "percentage" => 50
             }
           } == TransportWeb.ResourceController.latest_validations_details(resource)
  end

  test "resources_related are displayed", %{conn: conn} do
    %{url: gtfs_url} = gtfs_rt_resource = Repo.get_by(Resource, datagouv_id: "5", format: "gtfs-rt")
    gtfs_resource = Repo.get_by(Resource, datagouv_id: "1", format: "GTFS")

    insert(:resource_related, resource_src: gtfs_rt_resource, resource_dst: gtfs_resource, reason: :gtfs_rt_gtfs)

    expect(Transport.HTTPoison.Mock, :get, fn ^gtfs_url, [], [follow_redirect: true] ->
      {:ok, %HTTPoison.Response{status_code: 200, body: ""}}
    end)

    {html_response, _logs} =
      with_log(fn -> conn |> get(resource_path(conn, :details, gtfs_rt_resource.id)) |> html_response(200) end)

    assert html_response =~ ~s(<h2 id="related-resources">Ressources associées</h2>)
    assert html_response =~ "Fichier GTFS associé"
  end

  defp test_remote_download_error(%Plug.Conn{} = conn, mock_status_code) do
    resource = Resource |> Repo.get_by(datagouv_id: "2")
    refute Resource.can_direct_download?(resource)

    Transport.HTTPoison.Mock
    |> expect(:get, fn url, [], hackney: [follow_redirect: true] ->
      assert url == resource.url
      {:ok, %HTTPoison.Response{status_code: mock_status_code}}
    end)

    conn = conn |> get(resource_path(conn, :download, resource.id))

    html = html_response(conn, 404)
    assert html =~ "Page non disponible"
    assert get_flash(conn, :error) == "La ressource n'est pas disponible sur le serveur distant"
  end
end
