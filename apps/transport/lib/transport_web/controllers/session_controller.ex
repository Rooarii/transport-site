defmodule TransportWeb.SessionController do
  @moduledoc """
  Session management for transport.
  """
  use TransportWeb, :controller
  alias Datagouvfr.Authentication
  require Logger

  def new(conn, _) do
    redirect(conn, external: Authentication.authorize_url())
  end

  def create(conn, %{"code" => code}) do
    authentication_module = Datagouvfr.Authentication.Wrapper.impl()
    user_module = Datagouvfr.Client.User.Wrapper.impl()

    with %{token: token} <- authentication_module.get_token!(code: code),
         conn <-
           conn
           |> put_session(:token, token)
           |> assign(:token, token),
         {:ok, user} <- user_module.me(conn) do
      user_params = user_params(user)
      find_or_create_contact(user_params)

      conn
      |> save_current_user(user_params)
      |> redirect(to: get_redirect_path(conn))
      |> halt()
    else
      {:error, error} ->
        Logger.error(error)

        conn
        |> put_flash(:error, dgettext("alert", "An error occured, please try again"))
        |> redirect(to: session_path(conn, :new))
        |> halt()
    end
  end

  def create(conn, %{"error" => error, "error_description" => description}) do
    Logger.error("error while creating the session: #{error} - #{description}")

    conn
    |> put_flash(:error, dgettext("alert", "An error occured, please try again"))
    |> redirect(to: session_path(conn, :new))
    |> halt()
  end

  def delete(%Plug.Conn{} = conn, _) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: get_redirect_path(conn))
    |> halt()
  end

  def find_or_create_contact(
        %{
          "id" => user_id,
          "first_name" => first_name,
          "last_name" => last_name,
          "email" => email,
          "organizations" => organizations
        } = user_params
      ) do
    DB.Contact
    |> DB.Repo.get_by(datagouv_user_id: user_id)
    |> case do
      %DB.Contact{mailing_list_title: nil} = contact ->
        contact
        |> DB.Contact.changeset(%{
          first_name: first_name,
          last_name: last_name,
          email: email
        })
        |> DB.Repo.update!()

      %DB.Contact{mailing_list_title: mailing_list_title} = contact when mailing_list_title != nil ->
        contact
        |> DB.Contact.changeset(%{email: email})
        |> DB.Repo.update!()

      nil ->
        find_contact_by_email_or_create(user_params)
    end
    |> DB.Contact.changeset(%{last_login_at: DateTime.utc_now(), organizations: organizations})
    |> DB.Repo.update!()
  end

  defp find_contact_by_email_or_create(%{
         "id" => user_id,
         "first_name" => first_name,
         "last_name" => last_name,
         "email" => email
       }) do
    case DB.Repo.get_by(DB.Contact, email_hash: String.downcase(email)) do
      %DB.Contact{mailing_list_title: nil} = contact ->
        contact
        |> DB.Contact.changeset(%{
          datagouv_user_id: user_id,
          first_name: first_name,
          last_name: last_name
        })
        |> DB.Repo.update!()

      %DB.Contact{mailing_list_title: mailing_list_title} = contact when mailing_list_title != nil ->
        contact
        |> DB.Contact.changeset(%{datagouv_user_id: user_id})
        |> DB.Repo.update!()

      nil ->
        %{
          datagouv_user_id: user_id,
          first_name: first_name,
          last_name: last_name,
          email: email
        }
        |> DB.Contact.insert!()
    end
  end

  defp user_params(%{} = user) do
    Map.take(
      user,
      ["id", "apikey", "email", "first_name", "last_name", "avatar_thumbnail", "organizations"]
    )
  end

  def save_current_user(%Plug.Conn{} = conn, %{} = user_params) do
    conn |> put_session(:current_user, user_params |> user_params_for_session())
  end

  @doc """
  iex> pan_org = %{"slug" => "equipe-transport-data-gouv-fr", "name" => "PAN"}
  iex> other_org = %{"slug" => "foo-inc", "name" => "Foo Inc"}
  iex> user_params_for_session(%{"foo" => "bar", "organizations" => [pan_org, other_org]})
  %{"foo" => "bar", "organizations" => [pan_org]}
  """
  def user_params_for_session(%{} = params) do
    Map.put(
      params,
      "organizations",
      Enum.filter(
        params["organizations"],
        &match?(%{"slug" => "equipe-transport-data-gouv-fr"}, &1)
      )
    )
  end

  defp get_redirect_path(%Plug.Conn{} = conn) do
    case get_session(conn, :redirect_path) do
      nil -> "/"
      path -> path
    end
  end
end
