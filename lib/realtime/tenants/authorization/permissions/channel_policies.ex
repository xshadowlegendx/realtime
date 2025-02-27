defmodule Realtime.Tenants.Authorization.Policies.ChannelPolicies do
  @moduledoc """
  ChannelPolicies structure that holds the required authorization information for a given connection within the scope of a reading / altering channel entities

  Uses the Realtime.Api.Channel to try reads and writes on the database to determine authorization for a given connection.

  > Note: Currently we only allow policies to read all but not write all IF the RLS policies allow it.

  Implements Realtime.Tenants.Authorization behaviour.
  """
  require Logger
  import Ecto.Query

  alias Realtime.Api.Channel
  alias Realtime.Repo
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies

  defstruct read: false, write: false

  @behaviour Realtime.Tenants.Authorization.Policies

  @type t :: %__MODULE__{
          :read => boolean(),
          :write => boolean()
        }

  @impl true
  def check_read_policies(conn, %Policies{} = policies, %Authorization{channel: nil}) do
    Postgrex.transaction(conn, fn transaction_conn ->
      case Repo.all(transaction_conn, Channel, Channel, mode: :savepoint) do
        {:ok, channels} when channels != [] ->
          Policies.update_policies(policies, :channel, :read, true)

        {:ok, _} ->
          Policies.update_policies(policies, :channel, :read, false)

        {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
          Policies.update_policies(policies, :channel, :read, false)

        {:error, error} ->
          Logger.error(
            "Error getting all channel read policies for connection: #{inspect(error)}"
          )

          Postgrex.rollback(transaction_conn, error)
      end
    end)
  end

  def check_read_policies(conn, %Policies{} = policies, %Authorization{channel: channel}) do
    query = from(c in Channel, where: c.id == ^channel.id)

    Postgrex.transaction(conn, fn transaction_conn ->
      case Repo.one(transaction_conn, query, Channel) do
        {:ok, %Channel{}} ->
          Policies.update_policies(policies, :channel, :read, true)

        {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
          Policies.update_policies(policies, :channel, :read, false)

        {:error, :not_found} ->
          Policies.update_policies(policies, :channel, :read, false)

        {:error, error} ->
          Logger.error("Error getting channel read policies for connection: #{inspect(error)}")
          Postgrex.rollback(transaction_conn, error)
      end
    end)
  end

  @impl true
  def check_write_policies(_conn, policies, %Authorization{channel: nil}) do
    {:ok, Policies.update_policies(policies, :channel, :write, false)}
  end

  def check_write_policies(conn, policies, %Authorization{channel: channel}) do
    changeset = Channel.check_changeset(channel, %{check: true})

    case Repo.update(conn, changeset, Channel, mode: :savepoint) do
      {:ok, %Channel{check: true} = channel} ->
        revert_changeset = Channel.check_changeset(channel, %{check: false})
        {:ok, _} = Repo.update(conn, revert_changeset, Channel)
        {:ok, Policies.update_policies(policies, :channel, :write, true)}

      {:ok, _} ->
        {:ok, Policies.update_policies(policies, :channel, :write, false)}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        {:ok, Policies.update_policies(policies, :channel, :write, false)}

      {:error, :not_found} ->
        {:ok, Policies.update_policies(policies, :channel, :write, false)}

      {:error, error} ->
        Logger.error("Error getting channel write policies for connection: #{inspect(error)}")
        {:error, error}
    end
  end
end
