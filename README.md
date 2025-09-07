# libcluster-dynamic-srv

A lightweight pairing of:

1. A `libcluster` strategy (`Cluster.Strategy.DynamicSrv`) that discovers Erlang/Elixir nodes via DNS **SRV** records (works great with Consul, but is generic).
2. A drop‑in replacement for Erlang’s `epmd` client (`DynamicSrv.Epmd`) that lets you run distribution on a **dynamically assigned port** (e.g. one allocated/proxied by a service mesh) instead of a single fixed `EPMD` port.

Taken together, this lets you run clustered Elixir/Erlang nodes in modern, service‑mesh / DNS‑driven environments without relying on the static port assumptions baked into the classic EPMD workflow.

---

## Why does this exist?

Traditional Erlang distribution expects:

- A single `epmd` daemon per host listening on a well‑known port (default 4369)
- Each node listening on a second, usually static, distribution port (or from a narrow range)

In containerized or service-mesh architectures (Consul, sidecars, etc.), you often want:

- A dynamically chosen distribution port (surfaced via environment or injected config)
- Discovery based on DNS SRV records rather than explicit host:port lists
- No dependence on a locally running `epmd` daemon

This library enables exactly that:

- You set `ERL_DIST_PORT` dynamically (injected by your orchestrator / mesh)
- You tell the VM to use `DynamicSrv.Epmd` as its epmd module
- Nodes discover each other via SRV lookups like `<node-name>.<service-domain>`

---

## High‑Level Overview

| Concern | What this library provides |
|---------|----------------------------|
| Dynamic distribution port | `DynamicSrv.Epmd` reads `ERL_DIST_PORT` and reports it as the node’s listen port |
| No epmd daemon required | Functions like `register_node/2` are stubbed to satisfy the runtime without contacting epmd |
| Node address resolution | `address_please/3` resolves peers via DNS A + SRV queries |
| Cluster membership | `Cluster.Strategy.DynamicSrv` polls SRV records and connects/disconnects nodes accordingly |
| Generic SRV format | Works with any DNS provider returning SRV records shaped like `<node-name>.<service-domain>` |

---

## When to use this

Use `libcluster-dynamic-srv` if:

- You deploy into Consul (or another DNS system exposing SRV records)
- Your node distribution port is allocated dynamically (or you just want to standardize on one mechanism)
- You’d like to avoid running the epmd daemon entirely
- You want a simple, explicit mapping:
  SRV record host: `my-node.my-service.service.consul` → Node name: `:"my-node@my-service.service.consul"`

---

## Requirements

- Erlang / Elixir on OTP 20+ (needs `ERL_DIST_PORT` support)
- Environment variable `ERL_DIST_PORT` must be set before the BEAM starts
- DNS provider (e.g. Consul) returning SRV records where the target host includes the node label

---

## Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:libcluster_dynamic_srv, "~> 0.1"} # replace with the real version
  ]
end
```

---

## Enabling the custom epmd module

Start your release / node with:

```
ERL_DIST_PORT=$(allocate_a_port_somehow) \
elixir \
  -epmd_module DynamicSrv.Epmd \
  --name my-node@my-service.service.consul \
  -S mix run
```

Or for a release (example):

```
ERL_DIST_PORT=$PORT \
RELX_VM_ARGS="-epmd_module DynamicSrv.Epmd" \
_bin/my_app start
```

If you are using `--sname`, switch to `--name` because fully qualified hostnames are required for DNS-based discovery.

If `ERL_DIST_PORT` is not set, the custom module will raise on startup to avoid silent misconfiguration.

---

## Configuring the `libcluster` strategy

In `config/runtime.exs` (or similar):

```elixir
config :libcluster,
  topologies: [
    dyn_srv: [
      strategy: Cluster.Strategy.DynamicSrv,
      config: [
        service: "my-service.service.consul",
        # optional:
        # polling_interval: 5_000,
        # resolver: &MyCustom.resolver/1
      ]
    ]
  ]
```

What the strategy does:

1. Performs periodic SRV lookups for the configured `service` (e.g. `_service._proto.domain` is resolved internally by your DNS layer or Consul abstraction).
2. Expects SRV targets shaped like `<node-name>.<service-domain>`.
3. Converts each SRV target into a node atom `:"<node-name>@<service-domain>"`.
4. Connects to new nodes; disconnects nodes no longer present.

Example SRV answer (conceptual):

```
_my-service._tcp.service.consul  0  1  8001  my-node-a.my-service.service.consul
_my-service._tcp.service.consul  0  1  8017  my-node-b.my-service.service.consul
```

Produces candidate node names:

```
:"my-node-a@my-service.service.consul"
:"my-node-b@my-service.service.consul"
```

Each remote node is expected to also have started with:
```
-epmd_module DynamicSrv.Epmd
ERL_DIST_PORT=<its own listen port>
```

---

## Node Naming Conventions

Given SRV target host: `<node-label>.<service-domain>`
Node name must be: `:"<node-label>@<service-domain>"`

Regex used internally (case insensitive):

```
^(?<node_name>[a-z0-9-_]+)\.<service-domain>$
```

If the SRV target does not match this pattern, it is ignored.

---

## How remote resolution works

When a node tries to connect:

1. `DynamicSrv.Epmd.address_please/3` is invoked.
2. If the target matches the "self" pattern (including optional prefixes like `rpc-` or `rem-` for certain internal ops), it returns `{127,0,0,1, local_port}`.
3. Otherwise it:
   - Resolves the SRV target host to an IP (A lookup)
   - Fetches the SRV record to obtain the peer's distribution port
4. Returns the tuple expected by the distribution layer along with a constant distro protocol version (5).

This avoids ever calling a real `epmd` daemon.

---

## Recommended Deployment Pattern (Consul example)

1. Register each service instance in Consul with a service name like `my-service` and a tag or meta value that becomes the node label (`my-node-a`, `my-node-b`, ...).
2. Ensure Consul generates SRV records whose targets embed that label: `my-node-a.my-service.service.consul`.
3. Inject a unique `ERL_DIST_PORT` per instance (or have the service pick a free port at boot and export it).
4. Start the VM with `-epmd_module DynamicSrv.Epmd`.
5. Let `libcluster` manage membership.

---

## Troubleshooting

- Crash: `ERL_DIST_PORT is not set`
  You forgot to export the env var before starting the VM.
- Nodes see each other but disconnect frequently
  Check that SRV TTL + `polling_interval` aren’t causing churn; consider raising `polling_interval`.
- Node names never connect
  Verify the constructed atom matches what `node()` returns on peers. Log `node()` on both sides and compare.
- SRV returns but no connections
  Ensure your service mesh/firewall allows the dynamic ports.

---

## Security Considerations

You are exposing dynamic distribution ports. Secure Erlang distribution (cookies, TLS, network policy) as you normally would. This library does not add encryption or authentication beyond standard Erlang cookies.

---

## Limitations

- Does not implement `names/1` (returns `{:error, :address}`) because no epmd process is running.
- Assumes IPv4 in `address_please/3` (can be extended to IPv6 if needed).
- Relies on consistent SRV + A record correctness from DNS.

---

## Extensibility

You can provide a custom resolver (for testing or alternative DNS backends):

```elixir
resolver: fn service_charlist ->
  # Return a list shaped like: [{priority, weight, port, 'host'}]
end
```

---

## Summary

libcluster-dynamic-srv lets you:

- Drop the epmd daemon
- Use a dynamically assigned distribution port
- Discover and maintain cluster membership via DNS SRV
- Keep configuration minimal and provider-agnostic

If you run Elixir/Erlang in a dynamic, service-mesh-aware infrastructure, this approach simplifies distribution without giving up the benefits of the BEAM’s built‑in clustering.

---

Happy clustering!
