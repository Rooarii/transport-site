defmodule Transport.CommentsChecker do
  @moduledoc """
  Check for new comments posted on data.gouv.fr for datasets referenced on the PAN.

  Send an email to contacts with a subscription to the `daily_new_comments` reason
  with the new comments and a link to them.
  """
  alias Datagouvfr.Client.Discussions
  alias DB.{Dataset, Repo}
  import Ecto.Query
  require Logger

  @type datagouv_id :: binary()
  @type title :: binary()
  @type datagouv_comment :: map()
  @type comments_with_context :: {%Dataset{}, datagouv_id(), title(), [datagouv_comment()]}

  @notification_reason DB.NotificationSubscription.reason(:daily_new_comments)

  def check_for_new_comments do
    comments_with_context = fetch_new_comments()
    number_new_comments = comments_with_context |> count_comments()
    handle_new_comments(number_new_comments, comments_with_context)

    number_new_comments
  end

  @spec fetch_new_comments :: [comments_with_context()]
  def fetch_new_comments do
    Dataset
    |> where([d], d.is_active == true)
    |> select([:id, :datagouv_id, :latest_data_gouv_comment_timestamp])
    |> Repo.all()
    |> Enum.map(fn %{datagouv_id: datagouv_id, latest_data_gouv_comment_timestamp: current_ts} = dataset ->
      comments =
        datagouv_id
        |> Discussions.get()
        |> add_discussion_id_to_comments()
        |> comments_posted_after(current_ts)

      title = get_dataset_title(datagouv_id)

      {dataset, datagouv_id, title, comments}
    end)
  end

  @spec count_comments([comments_with_context()]) :: integer
  def count_comments(comments_with_context) do
    comments_with_context
    |> Enum.reduce(0, fn {_, _, _, comments}, acc -> acc + Enum.count(comments) end)
  end

  @spec handle_new_comments(integer(), [comments_with_context()]) :: :ok
  def handle_new_comments(0 = _comments_number, _comments) do
    Logger.info("no new comment posted since last check")
  end

  def handle_new_comments(comments_number, comments) do
    Logger.info("#{comments_number} new comment(s), sending emails")

    email_content = Phoenix.View.render_to_string(TransportWeb.EmailView, "index.html", comments_with_context: comments)

    emails =
      @notification_reason
      |> DB.NotificationSubscription.subscriptions_for_reason()
      |> DB.NotificationSubscription.subscriptions_to_emails()

    Enum.each(emails, fn email ->
      Transport.EmailSender.impl().send_mail(
        "transport.data.gouv.fr",
        Application.get_env(:transport, :contact_email),
        email,
        Application.get_env(:transport, :contact_email),
        "#{comments_number} nouveaux commentaires sur data.gouv.fr",
        "",
        email_content
      )
    end)

    update_all_datasets_ts(comments)
    save_notifications(comments, emails)

    :ok
  end

  def save_notifications(comments_with_context, emails) do
    comments_with_context
    |> Enum.reject(fn {%Dataset{}, _datagouv_id, _title, comments} -> Enum.empty?(comments) end)
    |> Enum.each(fn {%Dataset{} = dataset, _datagouv_id, _title, _comments} ->
      Enum.each(emails, fn email -> DB.Notification.insert!(@notification_reason, dataset, email) end)
    end)
  end

  @spec update_all_datasets_ts([comments_with_context()]) :: []
  def update_all_datasets_ts(comments_with_context) do
    comments_with_context
    |> Enum.map(fn {dataset, _datagouv_id, _title, comments} ->
      comments
      |> comments_latest_timestamp()
      |> case do
        nil ->
          nil

        datetime ->
          update_dataset_ts(dataset, datetime)
      end
    end)
  end

  @spec update_dataset_ts(Dataset.t(), DateTime.t()) :: {:ok, any()} | {:error, any()}
  def update_dataset_ts(dataset, timestamp) do
    changeset_request = Ecto.Changeset.change(dataset, %{latest_data_gouv_comment_timestamp: timestamp})
    update = Repo.update(changeset_request)

    with {:error, _changeset} <- update do
      Sentry.capture_message("unable_to_update_dataset_comment_timestamp",
        extra: %{id: dataset.id}
      )
    end

    update
  end

  defp get_dataset_title(datagouv_id) do
    Dataset
    |> where([d], d.datagouv_id == ^datagouv_id)
    |> select([d], d.custom_title)
    |> Repo.one()
  end

  def comment_timestamp(comment) do
    comment
    |> Map.get("posted_on")
    |> DateTime.from_iso8601()
    |> case do
      {:ok, %DateTime{} = datetime, 0} -> datetime |> DateTime.truncate(:second)
      _ -> nil
    end
  end

  def comments_latest_timestamp(nil), do: nil
  def comments_latest_timestamp([]), do: nil

  def comments_latest_timestamp(comments) when is_list(comments) do
    case comments do
      [comment] ->
        comment_timestamp(comment)

      [c | comments] ->
        latest_datetime(comment_timestamp(c), comments_latest_timestamp(comments))
    end
  end

  defp latest_datetime(%DateTime{} = date1, %DateTime{} = date2) do
    Enum.max([date1, date2], DateTime)
  end

  def comments_posted_after(discussions, nil) do
    discussions |> Enum.flat_map(fn d -> d["discussion"] end)
  end

  def comments_posted_after(discussions, timestamp) do
    discussions
    |> Enum.flat_map(fn d -> d["discussion"] end)
    |> Enum.filter(fn comment -> DateTime.diff(comment_timestamp(comment), timestamp) >= 1 end)
  end

  def add_discussion_id_to_comments(discussions) do
    discussions
    |> Enum.map(fn discussion ->
      discussion_id = discussion |> Map.get("id")
      comments = discussion |> Map.get("discussion")

      updated_comments = comments |> Enum.map(fn comment -> Map.put(comment, "discussion_id", discussion_id) end)

      %{discussion | "discussion" => updated_comments}
    end)
  end
end
