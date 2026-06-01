defmodule Mix.Tasks.Workspace.BeforeRemove do
  use Mix.Task

  alias SymphonyElixir.Config
  alias SymphonyElixir.VCS

  @shortdoc "Close open PRs/MRs for the current branch before workspace removal"

  @moduledoc """
  Closes open pull requests or merge requests for the current Git branch.

  This task is intended for use from the `before_remove` workspace hook.

  Usage:

      mix workspace.before_remove
      mix workspace.before_remove --branch feature/my-branch
      mix workspace.before_remove --repo openai/symphony
      mix workspace.before_remove --provider gitlab --repo group/project
  """

  @default_repo "openai/symphony"
  @default_provider "github"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [branch: :string, help: :boolean, provider: :string, repo: :string],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        vcs = configured_vcs()
        provider = opts[:provider] || vcs.provider
        repo = opts[:repo] || vcs.repo
        branch = opts[:branch] || current_branch()

        maybe_close_open_pull_requests(provider, repo, branch)
    end
  end

  defp maybe_close_open_pull_requests(_provider, _repo, nil), do: :ok

  defp maybe_close_open_pull_requests(provider, repo, branch) do
    if VCS.supported_provider?(provider) do
      maybe_close_open_pull_requests_for_provider(provider, repo, branch)
    end

    :ok
  end

  defp maybe_close_open_pull_requests_for_provider(provider, repo, branch) do
    cli = VCS.cli(provider)

    if cli_available?(cli) and cli_authenticated?(cli) do
      repo
      |> list_open_pull_request_numbers(provider, branch)
      |> Enum.each(&close_pull_request(provider, repo, branch, &1))
    end

    :ok
  end

  defp cli_available?(cli) do
    not is_nil(System.find_executable(cli))
  end

  defp cli_authenticated?(cli) do
    match?({:ok, _output}, run_command(cli, ["auth", "status"]))
  end

  defp list_open_pull_request_numbers(repo, "github", branch) do
    case run_command("gh", [
           "pr",
           "list",
           "--repo",
           repo,
           "--head",
           branch,
           "--state",
           "open",
           "--json",
           "number",
           "--jq",
           ".[].number"
         ]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == ""))

      {:error, _reason} ->
        []
    end
  end

  defp list_open_pull_request_numbers(repo, "gitlab", branch) do
    case run_command("glab", [
           "mr",
           "list",
           "--repo",
           repo,
           "--source-branch",
           branch,
           "--output",
           "json"
         ]) do
      {:ok, output} ->
        output
        |> Jason.decode()
        |> case do
          {:ok, merge_requests} when is_list(merge_requests) ->
            merge_requests
            |> Enum.map(&Map.get(&1, "iid"))
            |> Enum.reject(&is_nil/1)
            |> Enum.map(&to_string/1)

          _ ->
            []
        end

      {:error, _reason} ->
        []
    end
  end

  defp close_pull_request("github", repo, branch, pr_number) do
    case run_command("gh", [
           "pr",
           "close",
           pr_number,
           "--repo",
           repo,
           "--comment",
           closing_comment(branch)
         ]) do
      {:ok, _output} ->
        Mix.shell().info("Closed PR ##{pr_number} for branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to close PR ##{pr_number} for branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp close_pull_request("gitlab", repo, branch, merge_request_iid) do
    note_result =
      run_command("glab", [
        "mr",
        "note",
        merge_request_iid,
        "--repo",
        repo,
        "--message",
        closing_comment(branch)
      ])

    close_result =
      run_command("glab", [
        "mr",
        "close",
        merge_request_iid,
        "--repo",
        repo
      ])

    case note_result do
      {:ok, _output} ->
        :ok

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to comment on MR !#{merge_request_iid} for branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end

    case close_result do
      {:ok, _output} ->
        Mix.shell().info("Closed MR !#{merge_request_iid} for branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to close MR !#{merge_request_iid} for branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp closing_comment(branch) do
    "Closing because the tracker issue for branch #{branch} entered a terminal state without merge."
  end

  defp format_output(""), do: ""
  defp format_output(output), do: " output=#{inspect(output)}"

  defp current_branch do
    case run_command("git", ["branch", "--show-current"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          branch -> branch
        end

      {:error, _reason} ->
        nil
    end
  end

  defp configured_vcs do
    case Config.settings() do
      {:ok, settings} ->
        %{
          provider: settings.vcs.provider || @default_provider,
          repo: settings.vcs.repo || @default_repo
        }

      {:error, _reason} ->
        %{
          provider: @default_provider,
          repo: @default_repo
        }
    end
  end

  defp run_command(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, {:enoent, ""}}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end
end
