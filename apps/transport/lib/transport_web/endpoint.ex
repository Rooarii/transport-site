defmodule TransportWeb.Endpoint do
  use Sentry.PlugCapture
  use Phoenix.Endpoint, otp_app: :transport

  @session_options [
    store: :cookie,
    key: "_transport_key",
    signing_salt: "wqoqbzqj",
    same_site: "Lax",
    # 15 days
    max_age: 24 * 60 * 60 * 15
  ]

  socket("/socket", TransportWeb.UserSocket)
  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phoenix.digest
  # when deploying your static files in production.
  plug(Plug.Static,
    at: "/",
    from: :transport,
    gzip: Mix.env() == :prod,
    only: ~w(js css fonts images data favicon.ico documents BingSiteAuth.xml google5be4b09db1274976.html demo_rt.html)
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket("/", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"
  )

  plug(Plug.RequestId)
  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json, :multipart],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 100_000_000
  )

  plug(Sentry.PlugContext)

  plug(Plug.MethodOverride)
  plug(TransportWeb.Plugs.Head)

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  plug(Plug.Session, @session_options)

  plug(TransportWeb.Plugs.Router)

  @doc """
  Callback invoked for dynamically configuring the endpoint.

  It receives the endpoint configuration and checks if
  configuration should be loaded from the system environment.
  """
  def init(_key, config) do
    if config[:load_from_system_env] do
      port = System.get_env("PORT") || raise "expected the PORT environment variable to be set"
      {:ok, Keyword.put(config, :http, [:inet6, port: port])}
    else
      {:ok, config}
    end
  end
end
