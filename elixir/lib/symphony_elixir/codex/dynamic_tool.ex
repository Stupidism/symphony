defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Jira, Linear.Client}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @jira_rest_tool "jira_rest"
  @jira_rest_description """
  Execute an authenticated Jira Cloud REST request using Symphony's configured Jira auth.
  """
  @jira_rest_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "description" => "HTTP method such as GET, POST, PUT, or DELETE."
      },
      "path" => %{"type" => "string", "description" => "Jira REST path beginning with /rest/."},
      "query" => %{
        "type" => ["object", "null"],
        "description" => "Optional query parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "type" => ["object", "array", "string", "null"],
        "description" => "Optional JSON request body."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @jira_rest_tool ->
        execute_jira_rest(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @jira_rest_tool,
        "description" => @jira_rest_description,
        "inputSchema" => @jira_rest_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp execute_jira_rest(arguments, opts) do
    jira_client = Keyword.get(opts, :jira_client, &Jira.Client.request/3)

    with {:ok, method, path, request_opts} <- normalize_jira_rest_arguments(arguments),
         {:ok, response} <- jira_client.(method, path, request_opts) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_jira_rest_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <-
           normalize_jira_method(Map.get(arguments, "method") || Map.get(arguments, :method)),
         {:ok, path} <- normalize_jira_path(Map.get(arguments, "path") || Map.get(arguments, :path)),
         {:ok, query} <-
           normalize_optional_map_argument(
             Map.get(arguments, "query") || Map.get(arguments, :query),
             :invalid_query
           ),
         {:ok, body} <- normalize_jira_body(Map.get(arguments, "body") || Map.get(arguments, :body)) do
      opts = []
      opts = if is_nil(query), do: opts, else: Keyword.put(opts, :params, query)
      opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)
      {:ok, method, path, opts}
    end
  end

  defp normalize_jira_rest_arguments(_arguments), do: {:error, :invalid_jira_arguments}

  defp normalize_jira_method(method) when is_binary(method) do
    case method |> String.trim() |> String.downcase() do
      value when value in ["get", "post", "put", "patch", "delete"] -> {:ok, value}
      _ -> {:error, :invalid_jira_method}
    end
  end

  defp normalize_jira_method(_method), do: {:error, :invalid_jira_method}

  defp normalize_jira_path(path) when is_binary(path) do
    case String.trim(path) do
      "/" <> _ = trimmed -> {:ok, trimmed}
      _ -> {:error, :invalid_jira_path}
    end
  end

  defp normalize_jira_path(_path), do: {:error, :invalid_jira_path}

  defp normalize_optional_map_argument(nil, _reason), do: {:ok, nil}
  defp normalize_optional_map_argument(value, _reason) when is_map(value), do: {:ok, value}
  defp normalize_optional_map_argument(_value, reason), do: {:error, reason}

  defp normalize_jira_body(nil), do: {:ok, nil}

  defp normalize_jira_body(value) when is_map(value) or is_list(value) or is_binary(value),
    do: {:ok, value}

  defp normalize_jira_body(_value), do: {:error, :invalid_jira_body}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_jira_arguments) do
    %{
      "error" => %{
        "message" => "`jira_rest` expects an object with `method`, `path`, and optional `query`/`body`."
      }
    }
  end

  defp tool_error_payload(:invalid_jira_method) do
    %{
      "error" => %{
        "message" => "`jira_rest.method` must be one of GET, POST, PUT, PATCH, or DELETE."
      }
    }
  end

  defp tool_error_payload(:invalid_jira_path) do
    %{"error" => %{"message" => "`jira_rest.path` must be a Jira REST path beginning with `/`."}}
  end

  defp tool_error_payload(:invalid_query) do
    %{"error" => %{"message" => "`jira_rest.query` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:invalid_jira_body) do
    %{"error" => %{"message" => "`jira_rest.body` must be a JSON object, array, string, or null."}}
  end

  defp tool_error_payload(:missing_jira_url) do
    %{"error" => %{"message" => "Symphony is missing Jira URL. Set `tracker.url` or export `JIRA_URL`."}}
  end

  defp tool_error_payload(:missing_jira_username) do
    %{
      "error" => %{
        "message" => "Symphony is missing Jira username. Set `tracker.username` or export `JIRA_USERNAME`."
      }
    }
  end

  defp tool_error_payload(:missing_jira_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Jira API token. Set `tracker.api_token` or export `JIRA_API_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:jira_api_status, status}) do
    %{"error" => %{"message" => "Jira REST request failed with HTTP #{status}.", "status" => status}}
  end

  defp tool_error_payload({:jira_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Jira REST request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
