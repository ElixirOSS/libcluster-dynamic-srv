defmodule DynamicSrv.Epmd do
  @moduledoc """
  This module was inspired heavily by [Caravan](https://github.com/uberbrodt/caravan)

  Custom EPMD replacement used to run Erlang distribution with dynamic ports and
  without a local epmd daemon. If you run this with a service mesh like Consul,
  coupled with a mutual TLS (Consul Connect), you can use this module to
  discover peers via DNS SRV records instead of a well‑known static port
  published through epmd and have service to service TLS encryption.

  This module is passed to the Erlang VM through the -epmd_module flag (or the
  :kernel, :epmd_module application environment) and implements just enough of
  the epmd client contract that the distribution layer (net_kernel /
  erl_distribution) can:

    * announce the local node's listening port (picked externally and exported
      via ERL_DIST_PORT), and
    * resolve remote nodes to {ip, port, version} tuples by consulting DNS,
      specifically SRV records to obtain the port.

  High level behavior
  -------------------
  1. Registration: register_node/2,3 does NOT talk to a daemon. It simply
     returns a pseudo "creation" (1..3) as expected by the runtime.
  2. Outbound connections: address_please/3 converts an incoming (Name, Host)
     pair into "Name.Host", performs DNS lookups:
       - A/AAAA (currently :inet.getaddr with :inet, i.e. IPv4 only)
       - SRV (via :inet_res.lookup) to obtain the distribution port
     and returns the distribution version (hard‑coded 5).
  3. Local listen port: listen_port_please/2 fetches the port from
     ERL_DIST_PORT (except for special ephemeral "rpc-" / "rem-" prefixed
     helper nodes, which are answered with port 0).
  4. names/1 is intentionally unsupported and returns {:error, :address}
     because there is no central registry.

  Node naming convention
  ----------------------
  The real Erlang node name is still of the form name@host. For matching
  purposes we map the current node (name@host) to "name.host" and compare it
  with the requested "Name.Host" (including optional prefixes):
    (rpc|rem)-<base>-<...>.service.consul
  This allows short‑lived, prefixed nodes (e.g. rpc-* for remote procedure
  helper processes) to co‑exist without requiring dedicated ports.

  Environment contract
  --------------------
  ERL_DIST_PORT MUST be set before the VM starts distribution. Failure to do
  so raises at runtime when local_dist_port/0 is invoked.

  DNS / Consul expectations
  -------------------------
  For a target like: mynode.myservice.service.consul
    * A (or CNAME) record resolves to the host IP.
    * SRV record (<my-service>.service.<consul-domain> - however you configure
      Consul) must return the distribution port you want peers to dial. (This
      code presently just takes the first returned SRV entry.) Adjust or wrap
      get_remote_ip_and_port/1 if you need prioritization or IPv6.

  Distribution version
  --------------------
  Kept at 5 (unchanged since OTP R6). Change only if upstream protocol
  conventions evolve.

  Limitations / Caveats
  ---------------------
  * No IPv6: :inet.getaddr(..., :inet) restricts lookups to IPv4.
  * No fallback / retries: DNS lookups are performed once; transient failures
    will bubble up as distribution connection errors.
  * Assumes SRV availability: If no SRV record exists the pattern match will
    fail. Wrap lookup logic if you need graceful degradation.
  * names/1 unsupported: Tools expecting epmd name listings will not work.
  * Single ERL_DIST_PORT: You are responsible for ensuring uniqueness (e.g.
    by provisioning ports or injecting them via orchestration).

  Configuration example (Elixir)
  ------------------------------
   Before launching the VM:
   NOTE: The `Elixir.` prefix is required for specifying the EPMD module.
  # `export ELIXIR_ERL_OPTIONS="-start_epmd false -epmd_module Elixir.DynamicSrv.Epmd"`
  # `export ERL_DIST_PORT=<some-port>`
  # `export RELEASE_DISTRIBUTION=name` - longnames are required
  # `export RELEASE_NODE="node_a@<myservice>.service.<consul domain>"`

  If you want to see a Nomad/Consul example using Consul Connect for mutual TLS
  see [examples/app.nomad](./examples/app.nomad)

  Troubleshooting
  ---------------
  * "ERL_DIST_PORT is not set": Ensure the environment variable is exported
    in the same shell / container context.
  * Cannot resolve remote node: Verify DNS (dig A / SRV records). Make sure
    the node name you pass maps to the expected SRV record.
  * Connection refused: Confirm the remote BEAM VM is listening on the port
    published by the SRV record and that network policies allow traffic.
  * Hanging node connections: Use :inet_res.getbyname / :inet_res.lookup in
    a shell to confirm that the BEAM's resolver can see the records inside
    the runtime environment.
  * If you are using Consul Connect, ensure that you have a permissive Intention
    in Consul for the service.
  """

  # The distribution protocol version number has been 5 ever since Erlang/OTP R6.
  @distro_version 5

  @doc """
  erl_distribution wants us to start a worker process. We don't need one,
  though.

  Returns :ignore
  """
  def start_link do
    :ignore
  end

  @doc """
  See: https://www.erlang.org/doc/apps/kernel/erl_epmd.html#register_node/3

  As of Erlang/OTP 19.1, register_node/3 is used instead of register_node/2,
  passing along the address family, 'inet_tcp' or 'inet6_tcp'. This makes no
  difference for our purposes.
  """
  def register_node(name, port, _family) do
    register_node(name, port)
  end

  def register_node(_name, _port) do
    # This is where we would connect to epmd and tell it which port
    # we're listening on, but since we're epmd-less, we don't do that.

    # Need to return a "creation" number between 1 and 3.
    creation = :rand.uniform(3)
    {:ok, creation}
  end

  @doc """
  See: https://www.erlang.org/doc/apps/kernel/erl_epmd.html#address_please/3

  This is using optimized version of this function that also returns the port
  and version. This will ensure that we don't need to also call port_please/3.
  """
  def address_please(name, host, _address_family) do
    my_node = node() |> to_string() |> String.replace("@", ".")
    target_node = "#{name}.#{host}"

    if String.match?(my_node, ~r/^((rpc|rem)-.*-)?#{target_node}$/) do
      {:ok, {127, 0, 0, 1}, local_dist_port(), @distro_version}
    else
      {address, service_port} = get_remote_ip_and_port(target_node)
      {:ok, address, service_port, @distro_version}
    end
  end

  def listen_port_please(name, _host) do
    if String.match?(to_string(name), ~r/^(rpc|rem)-/) do
      {:ok, 0}
    else
      {:ok, local_dist_port()}
    end
  end

  @doc """
  See: https://www.erlang.org/doc/apps/kernel/erl_epmd.html#names/1

  We are not implementing this because we are not running epmd.
  """
  def names(_hostname) do
    {:error, :address}
  end

  defp local_dist_port() do
    case System.get_env("ERL_DIST_PORT") do
      nil ->
        raise "ERL_DIST_PORT is not set"

      port ->
        String.to_integer(port)
    end
  end

  # Given a target node name, return the IP address and service port.
  # For Consul the target_node might look like "<node_name>.<service_name>.service.consul".
  # In this case, the EPMD node name is "<node_name>@<service_name>.service.consul"
  defp get_remote_ip_and_port(target_node) do
    target_node = String.to_charlist(target_node)

    # Get the IP Address
    {:ok, address} = :inet.getaddr(target_node, :inet)

    # Get the Service Port
    [{_, _, service_port, _host} | _rest] = :inet_res.lookup(target_node, :in, :srv)

    {address, service_port}
  end
end
