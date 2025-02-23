defmodule TransportWeb.API.Schemas do
  @moduledoc """
    OpenAPI schema defintions
  """
  require OpenApiSpex
  alias OpenApiSpex.{ExternalDocumentation, Schema}

  defmodule GeometryBase do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "GeometryBase",
      type: :object,
      description: "GeoJSon geometry",
      required: [:type],
      externalDocs: %ExternalDocumentation{url: "http://geojson.org/geojson-spec.html#geometry-objects"},
      properties: %{
        type: %Schema{
          type: :string,
          enum: ["Point", "LineString", "Polygon", "MultiPoint", "MultiLineString", "MultiPolygon"]
        }
      }
    })
  end

  defmodule NumberItems do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "NumberItems",
      type: :number
    })
  end

  defmodule Point2D do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Point2D",
      type: :array,
      description: "Point in 2D space",
      externalDocs: %ExternalDocumentation{url: "http://geojson.org/geojson-spec.html#id2"},
      minItems: 2,
      maxItems: 2,
      items: NumberItems
    })
  end

  defmodule LineString do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LineString",
      type: :object,
      description: "GeoJSon geometry",
      externalDocs: %ExternalDocumentation{url: "http://geojson.org/geojson-spec.html#id3"},
      allOf: [
        GeometryBase.schema(),
        %Schema{
          type: :object,
          properties: %{
            coordinates: %Schema{type: :array, items: Point2D}
          }
        }
      ]
    })
  end

  defmodule Polygon do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      title: "Polygon",
      description: "GeoJSon geometry",
      externalDocs: %ExternalDocumentation{url: "http://geojson.org/geojson-spec.html#id4"},
      allOf: [
        GeometryBase.schema(),
        %Schema{
          type: :object,
          properties: %{
            coordinates: %Schema{type: :array, items: %Schema{type: :array, items: Point2D}}
          }
        }
      ]
    })
  end

  defmodule MultiPoint do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      title: "MultiPoint",
      description: "GeoJSon geometry",
      externalDocs: %ExternalDocumentation{url: "http://geojson.org/geojson-spec.html#id5"},
      allOf: [
        GeometryBase.schema(),
        %Schema{
          type: :object,
          properties: %{
            coordinates: %Schema{type: :array, items: Point2D}
          }
        }
      ]
    })
  end

  defmodule MultiLineString do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      title: "MultiLineString",
      description: "GeoJSon geometry",
      externalDocs: %ExternalDocumentation{url: "http://geojson.org/geojson-spec.html#id4"},
      allOf: [
        GeometryBase.schema(),
        %Schema{
          type: :object,
          properties: %{
            coordinates: %Schema{type: :array, items: %Schema{type: :array, items: Point2D}}
          }
        }
      ]
    })
  end

  defmodule MultiPolygon do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      title: "MultiPolygon",
      description: "GeoJSon geometry",
      externalDocs: %ExternalDocumentation{url: "http://geojson.org/geojson-spec.html#id6"},
      allOf: [
        GeometryBase.schema(),
        %Schema{
          type: :object,
          properties: %{
            coordinates: %Schema{
              type: :array,
              items: %Schema{type: :array, items: %Schema{type: :array, items: Point2D}}
            }
          }
        }
      ]
    })
  end

  defmodule Geometry do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Geometry",
      description: "Geometry object",
      type: :object,
      oneOf: [
        LineString.schema(),
        Polygon.schema(),
        MultiPoint.schema(),
        MultiLineString.schema(),
        MultiPolygon.schema()
      ]
    })
  end

  defmodule Feature do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      title: "Feature",
      description: "Feature object",
      required: [:type, :geometry, :properties],
      properties: %{
        type: %Schema{type: :string, enum: ["Feature"]},
        geometry: Geometry,
        properties: %Schema{type: :object},
        id: %Schema{
          oneOf: [%Schema{type: :string}, %Schema{type: :number}]
        }
      }
    })
  end

  defmodule FeatureCollection do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      type: :object,
      title: "FeatureCollection",
      description: "FeatureCollection object",
      properties: %{
        features: %Schema{type: :array, items: Feature}
      }
    })
  end

  defmodule AOMResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AOM",
      description: "AOM object",
      type: :object,
      properties: %{
        siren: %Schema{type: :string},
        nom: %Schema{type: :string},
        insee_commune_principale: %Schema{type: :string},
        forme_juridique: %Schema{type: :string},
        departement: %Schema{type: :string}
      }
    })
  end

  defmodule GeoJSONResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "GeoJSONResponse",
      description: "Response in GeoJSON",
      type: :object,
      oneOf: [
        Geometry.schema(),
        Feature.schema(),
        FeatureCollection.schema()
      ]
    })
  end

  defmodule Utils do
    @moduledoc false
    def get_resource_prop(conversions: false),
      do: %{
        url: %Schema{type: :string, description: "Stable URL of the file"},
        original_url: %Schema{type: :string, description: "Direct URL of the file"},
        title: %Schema{type: :string, description: "Title of the resource"},
        updated: %Schema{type: :string, description: "Last update date-time"},
        end_calendar_validity: %Schema{
          type: :string,
          description:
            "The last day of the validity period of the file (read from the calendars for the GTFS). null if the file couldn’t be read"
        },
        start_calendar_validity: %Schema{
          type: :string,
          description:
            "The first day of the validity period of the file (read from the calendars for the GTFS). null if the file couldn’t be read"
        },
        format: %Schema{type: :string, description: "The format of the resource (GTFS, NeTEx, etc.)"},
        metadata: %Schema{
          type: :object,
          description: "Some metadata about the resource"
        }
      }

    def get_resource_prop(conversions: true),
      do:
        [conversions: false]
        |> get_resource_prop()
        |> Map.put(:conversions, %Schema{
          type: :object,
          description: "Available conversions of the resource in other formats",
          properties: %{
            GeoJSON: %Schema{
              type: :object,
              description: "Conversion to the GeoJSON format",
              properties: conversion_properties()
            },
            NeTEx: %Schema{
              type: :object,
              description: "Conversion to the NeTEx format",
              properties: conversion_properties()
            }
          }
        })

    defp conversion_properties,
      do: %{
        filesize: %Schema{type: :integer, description: "File size in bytes"},
        last_check_conversion_is_up_to_date: %Schema{
          type: :string,
          format: "date-time",
          description: "Last datetime (UTC) it was checked the converted file is still up-to-date with the resource"
        },
        stable_url: %Schema{type: :string, description: "The converted file stable download URL"}
      }
  end

  defmodule Resource do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%Schema{
      type: :object,
      description: "A single resource",
      properties: Utils.get_resource_prop(conversions: true)
    })
  end

  defmodule CommunityResource do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%Schema{
      type: :object,
      description: "A single community resource",
      properties:
        [conversions: false]
        |> Utils.get_resource_prop()
        |> Map.put(:community_resource_publisher, %Schema{
          type: :string,
          description: "Name of the producer of the community resource"
        })
        |> Map.put(:original_resource_url, %Schema{
          type: :string,
          description: """
          some community resources have been generated from another dataset (like the generated NeTEx / GeoJson).
          Those resources have a `original_resource_url` equals to the original resource's `original_url`
          """
        })
    })
  end

  defmodule DatasetsResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Dataset",
      description: "A dataset is a composed of at least one GTFS resource",
      type: :object,
      properties: %{
        updated: %Schema{type: :string, description: "The last update of any resource of that dataset"},
        name: %Schema{type: :string},
        licence: %Schema{type: :string, description: "The licence of the dataset"},
        created_at: %Schema{type: :string, format: :date, description: "Date of creation of the dataset"},
        aom: %Schema{type: :string, description: "Transit authority responsible of this authority"},
        resources: %Schema{
          type: :array,
          description: "All the resources (files) associated with the dataset",
          items: Resource
        },
        community_resources: %Schema{
          type: :array,
          description: "All the community resources (files published by the community) associated with the dataset",
          items: CommunityResource
        }
      }
    })
  end

  defmodule AutocompleteItem do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Autocomplete result",
      description: "One result of the autocomplete",
      type: :object,
      properties: %{
        url: %Schema{type: :string, description: "URL of the Resource"},
        type: %Schema{type: :string, description: "type of the resource (commune, region, aom)"},
        name: %Schema{type: :string, description: "name of the resource"}
      }
    })
  end

  defmodule AutocompleteResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Autocomplete results",
      description: "An array of matching results",
      type: :array,
      items: AutocompleteItem
    })
  end
end
