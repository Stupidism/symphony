defmodule SymphonyElixir.VCS do
  @moduledoc """
  Helpers for repository-hosting provider configuration.
  """

  @providers ["github", "gitlab"]

  @doc """
  Returns true when the value is a supported VCS provider.
  """
  @spec supported_provider?(term()) :: boolean()
  def supported_provider?(provider) when provider in @providers, do: true
  def supported_provider?(_provider), do: false

  @doc """
  Returns the CLI executable used for a provider.
  """
  @spec cli(String.t()) :: String.t()
  def cli("github"), do: "gh"
  def cli("gitlab"), do: "glab"

  @doc """
  Returns the pull-request-like noun for a provider.
  """
  @spec pull_request_label(String.t()) :: String.t()
  def pull_request_label("gitlab"), do: "merge request"
  def pull_request_label(_provider), do: "pull request"
end
