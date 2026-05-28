defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Jira Cloud REST client for polling board issues.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @fields "summary,description,status,assignee,labels,priority,created,updated,issuelinks"
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_board_config(tracker),
         {:ok, assignee_filter} <- routing_assignee_filter() do
      jql = states_jql(tracker.active_states, tracker.project_key)
      fetch_board_issues(tracker.board_id, jql, assignee_filter)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- validate_board_config(tracker) do
        jql = states_jql(normalized_states, tracker.project_key)
        fetch_board_issues(tracker.board_id, jql, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    keys = issue_ids |> Enum.map(&to_string/1) |> Enum.uniq()

    case keys do
      [] ->
        {:ok, []}

      keys ->
        with :ok <- validate_auth_config(Config.settings!().tracker),
             {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, body} <-
               post("/rest/api/3/search/jql", %{
                 jql: keys_jql(keys),
                 maxResults: length(keys),
                 fields: String.split(@fields, ",")
               }) do
          {:ok, normalize_issues(body["issues"], assignee_filter)}
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_key, body) when is_binary(issue_key) and is_binary(body) do
    case post("/rest/api/3/issue/#{URI.encode(issue_key)}/comment", %{body: jira_doc(body)}) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_key, state_name) when is_binary(issue_key) and is_binary(state_name) do
    with {:ok, transition_id} <- resolve_transition_id(issue_key, state_name),
         {:ok, _body} <-
           post("/rest/api/3/issue/#{URI.encode(issue_key)}/transitions", %{
             transition: %{id: transition_id}
           }) do
      :ok
    end
  end

  @spec request(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(method, path, opts \\ []) when is_binary(method) and is_binary(path) and is_list(opts) do
    tracker = Config.settings!().tracker

    with :ok <- validate_auth_config(tracker),
         {:ok, headers} <- auth_headers(tracker) do
      url = build_url(tracker.url, path)
      request_opts = [headers: headers, connect_options: [timeout: 30_000]] |> Keyword.merge(opts)

      case Req.request(Keyword.put(request_opts, :method, method) |> Keyword.put(:url, url)) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          Logger.error("Jira REST request failed method=#{method} path=#{path} status=#{status} body=#{summarize_error_body(body)}")

          {:error, {:jira_api_status, status}}

        {:error, reason} ->
          Logger.error("Jira REST request failed method=#{method} path=#{path}: #{inspect(reason)}")
          {:error, {:jira_api_request, reason}}
      end
    end
  end

  defp fetch_board_issues(board_id, jql, assignee_filter) do
    fetch_board_issues_page(board_id, jql, assignee_filter, 0, [])
  end

  defp fetch_board_issues_page(board_id, jql, assignee_filter, start_at, acc_issues) do
    params = [jql: jql, fields: @fields, maxResults: @issue_page_size, startAt: start_at]

    with {:ok, body} <-
           get("/rest/agile/1.0/board/#{URI.encode(board_id)}/issue", params: params) do
      issues = normalize_issues(body["issues"], assignee_filter)
      updated_acc = Enum.reverse(issues, acc_issues)
      next_start_at = start_at + length(issues)
      total = body["total"] || next_start_at

      if length(issues) > 0 and next_start_at < total do
        fetch_board_issues_page(board_id, jql, assignee_filter, next_start_at, updated_acc)
      else
        {:ok, Enum.reverse(updated_acc)}
      end
    end
  end

  defp get(path, opts), do: request("get", path, opts)
  defp post(path, json), do: request("post", path, json: json)

  defp resolve_transition_id(issue_key, state_name) do
    with {:ok, body} <- get("/rest/api/3/issue/#{URI.encode(issue_key)}/transitions", []),
         transitions when is_list(transitions) <- body["transitions"],
         %{"id" => transition_id} <-
           Enum.find(transitions, fn transition ->
             normalize_state_name(get_in(transition, ["to", "name"])) == normalize_state_name(state_name) or
               normalize_state_name(transition["name"]) == normalize_state_name(state_name)
           end) do
      {:ok, transition_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :jira_transition_not_found}
    end
  end

  defp validate_board_config(tracker) do
    with :ok <- validate_auth_config(tracker) do
      if is_binary(tracker.board_id), do: :ok, else: {:error, :missing_jira_board_id}
    end
  end

  defp validate_auth_config(tracker) do
    cond do
      not is_binary(tracker.url) -> {:error, :missing_jira_url}
      not is_binary(tracker.username) -> {:error, :missing_jira_username}
      not is_binary(tracker.api_token) -> {:error, :missing_jira_api_token}
      true -> :ok
    end
  end

  defp auth_headers(tracker) do
    credentials = Base.encode64("#{tracker.username}:#{tracker.api_token}")

    {:ok,
     [
       {"Authorization", "Basic #{credentials}"},
       {"Accept", "application/json"},
       {"Content-Type", "application/json"}
     ]}
  end

  defp build_url(base_url, path) do
    base_url
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp states_jql(state_names, project_key) when is_list(state_names) do
    state_clause = "status in (#{Enum.map_join(state_names, ", ", &jql_quote/1)})"

    case normalize_blank(project_key) do
      nil -> state_clause
      key -> "project = #{jql_quote(key)} AND #{state_clause}"
    end
  end

  defp keys_jql(keys) when is_list(keys), do: "key in (#{Enum.map_join(keys, ", ", &jql_quote/1)})"

  defp jql_quote(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      "me" ->
        with {:ok, body} <- get("/rest/api/3/myself", []) do
          account_id = body["accountId"]

          if is_binary(account_id),
            do: {:ok, %{match_values: MapSet.new([account_id])}},
            else: {:error, :missing_jira_viewer_identity}
        end

      assignee ->
        {:ok, %{match_values: MapSet.new([assignee])}}
    end
  end

  defp normalize_issues(issues, assignee_filter) when is_list(issues) do
    issues
    |> Enum.map(&normalize_issue(&1, assignee_filter))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_issues(_issues, _assignee_filter), do: []

  defp normalize_issue(%{"key" => key, "fields" => fields}, assignee_filter) when is_map(fields) do
    assignee = fields["assignee"]

    %Issue{
      id: key,
      identifier: key,
      title: fields["summary"],
      description: extract_description(fields["description"]),
      priority: parse_priority(get_in(fields, ["priority", "id"])),
      state: get_in(fields, ["status", "name"]),
      branch_name: key,
      url: issue_url(key),
      assignee_id: assignee_field(assignee, "accountId"),
      blocked_by: extract_blockers(fields["issuelinks"]),
      labels: extract_labels(fields["labels"]),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp issue_url(key) do
    case Config.settings!().tracker.url do
      url when is_binary(url) -> String.trim_trailing(url, "/") <> "/browse/" <> key
      _ -> nil
    end
  end

  defp assignee_field(%{} = assignee, field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values}) do
    values =
      [assignee["accountId"], assignee["emailAddress"], assignee["displayName"]]
      |> Enum.map(&normalize_blank/1)
      |> Enum.reject(&is_nil/1)

    Enum.any?(values, &MapSet.member?(match_values, &1))
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp extract_labels(labels) when is_list(labels), do: Enum.map(labels, &String.downcase(to_string(&1)))
  defp extract_labels(_labels), do: []

  defp extract_blockers(links) when is_list(links) do
    Enum.flat_map(links, fn link ->
      outward_type = get_in(link, ["type", "outward"])
      inward_issue = link["inwardIssue"]

      if is_map(inward_issue) and is_binary(outward_type) and String.downcase(outward_type) == "blocks" do
        [
          %{
            id: inward_issue["key"],
            identifier: inward_issue["key"],
            state: get_in(inward_issue, ["fields", "status", "name"])
          }
        ]
      else
        []
      end
    end)
  end

  defp extract_blockers(_links), do: []

  defp extract_description(nil), do: nil
  defp extract_description(value) when is_binary(value), do: value

  defp extract_description(%{} = doc) do
    doc
    |> collect_doc_text()
    |> Enum.join("")
    |> String.trim()
    |> normalize_blank()
  end

  defp extract_description(_value), do: nil

  defp collect_doc_text(%{"type" => "text", "text" => text}) when is_binary(text), do: [text]

  defp collect_doc_text(%{"type" => type, "content" => content})
       when is_list(content) and type in ["paragraph", "heading"] do
    collect_doc_text(content) ++ ["\n"]
  end

  defp collect_doc_text(%{"content" => content}) when is_list(content), do: collect_doc_text(content)
  defp collect_doc_text(values) when is_list(values), do: Enum.flat_map(values, &collect_doc_text/1)
  defp collect_doc_text(_value), do: []

  defp jira_doc(text) do
    %{
      type: "doc",
      version: 1,
      content: [
        %{
          type: "paragraph",
          content: [%{type: "text", text: text}]
        }
      ]
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority

  defp parse_priority(priority) when is_binary(priority) do
    case Integer.parse(priority) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp parse_priority(_priority), do: nil

  defp normalize_state_name(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_state_name(_value), do: nil

  defp normalize_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_blank(_value), do: nil

  defp summarize_error_body(body) when is_binary(body) do
    body |> String.replace(~r/\s+/, " ") |> String.trim() |> truncate_error_body() |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
