defmodule Cluster.Strategy.DynamicSrv do
  @moduledoc """
  This implements a libcluster strategy that utilizes DNS SRV records in a
  generic way. The K8s SRV strategy is too prescriptive to use generically
  because of the way it formulates its SRV hostnames.

  For this strategy to work the SRV records should be in the format of `<node-name>.<service-domain-name>`.
  This works with [Consul](https://www.consul.io/) by specifying the node-name
  as a label and the service-domain-name is `service.consul` by default.

  You can read more about Consul's DNS SRV records
  [here](https://developer.hashicorp.com/consul/docs/discover/service/static#service-lookups).

  While this was implemented to work with Consul, it can be used with any DNS
  service that supports SRV records and tagging of the hostname.

  Example Configuration:

  ```elixir
  config :libcluster,
    topologies: [
      dyn_srv: [
        strategy: Cluster.Strategy.DynamicSrv,
        config: [
          service: "my-service-name.service.consul"
        ]
      ]
    ]
  ```
  """
  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy
  alias Cluster.Strategy.State
  alias Cluster.Logger, as: CLogger

  @default_polling_interval 5_000

  @impl Cluster.Strategy
  def start_link([%State{} = state]), do: GenServer.start_link(__MODULE__, state)

  @impl GenServer
  def init(%State{meta: nil} = state) do
    init(%State{state | :meta => MapSet.new()})
  end

  def init(%State{} = state) do
    {:ok, do_poll(state)}
  end

  @impl GenServer
  def handle_info(:timeout, state), do: handle_info(:poll, state)

  def handle_info(:poll, state) do
    CLogger.debug(state.topology, "Polling for new nodes")
    state = do_poll(state)
    Process.send_after(self(), :poll, polling_interval(state))
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # This is lifted from the `Cluster.Strategy.DNSPoll` module
  defp do_poll(
         %State{
           topology: topology,
           connect: connect,
           disconnect: disconnect,
           list_nodes: list_nodes
         } = state
       ) do
    new_nodelist = state |> get_nodes() |> MapSet.new()
    removed = MapSet.difference(state.meta, new_nodelist)

    new_nodelist =
      case Strategy.disconnect_nodes(
             topology,
             disconnect,
             list_nodes,
             MapSet.to_list(removed)
           ) do
        :ok ->
          new_nodelist

        {:error, bad_nodes} ->
          # Add back the nodes which should have been removed, but which couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.put(acc, n)
          end)
      end

    new_nodelist =
      case Strategy.connect_nodes(
             topology,
             connect,
             list_nodes,
             MapSet.to_list(new_nodelist)
           ) do
        :ok ->
          new_nodelist

        {:error, bad_nodes} ->
          # Remove the nodes which should have been added, but couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.delete(acc, n)
          end)
      end

    %{state | :meta => new_nodelist}
  end

  defp get_nodes(%State{} = state) do
    service = service(state)

    case resolver(state).(String.to_charlist(service)) do
      [] ->
        CLogger.info(state.topology, "No nodes found")
        []

      [{_, _, _, _} | _] = resp ->
        CLogger.debug(state.topology, "Found #{length(resp)} nodes")
        me = node()

        format_nodes(resp, service)
        |> Enum.filter(&(&1 != me))
    end
  end

  # This will take in a list of SRV records and turn them into a list of nodes.
  # It uses the passed in `service` to convert the hostnames into node names.
  # In order for this to work, your SRV response should have the service name in it.
  # Example: `[{1,1,8001,~c"my-node.erl.service.consul"}]` -> `[:"my-node@erl.service.consul"]`
  defp format_nodes(srv_records, service) do
    regex = ~r/^(?<node_name>[a-z0-9-_]+)\.#{service}$/i

    Enum.map(srv_records, fn {_, _, _, host} ->
      case Regex.named_captures(regex, to_string(host)) do
        %{"node_name" => node_name} ->
          :"#{node_name}@#{service}"

        nil ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp polling_interval(%State{config: config}) do
    Keyword.get(config, :polling_interval, @default_polling_interval)
  end

  defp service(%State{config: config}) do
    Keyword.fetch!(config, :service)
  end

  defp resolver(%State{config: config}) do
    Keyword.get(config, :resolver, &:inet_res.lookup(&1, :in, :srv))
  end
end
