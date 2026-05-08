defmodule Cluster.Strategy.DynamicSrvTest do
  @moduledoc """
  Note: A lot of this code is borrowed from the libcluster library tests.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Cluster.Strategy.DynamicSrv
  alias Cluster.Nodes

  @service "my-service.service.consul"

  describe "start_link/1" do
    setup do
      Code.ensure_loaded!(Cluster.Nodes)
      :ok
    end

    test "adds new nodes" do
      capture_log(fn ->
        state = %Cluster.Strategy.State{
          topology: :dynamic_srv,
          config: [
            service: @service,
            resolver: fn _query ->
              [
                {1, 1, 8001, ~c"node-a.#{@service}"},
                {1, 1, 8002, ~c"node-b.#{@service}"},
                {1, 1, 8003, ~c"node-c.#{@service}"}
              ]
            end
          ],
          connect: {Nodes, :connect, [self()]},
          disconnect: {Nodes, :disconnect, [self()]},
          list_nodes: {Nodes, :list_nodes, [[]]}
        }

        DynamicSrv.start_link([state])

        assert_receive {:connect, :"node-a@my-service.service.consul"}, 100
        assert_receive {:connect, :"node-b@my-service.service.consul"}, 100
        assert_receive {:connect, :"node-c@my-service.service.consul"}, 100
      end)
    end

    test "removes nodes" do
      capture_log(fn ->
        [
          %Cluster.Strategy.State{
            topology: :dynamic_srv,
            config: [
              service: @service,
              resolver: fn _query ->
                [
                  {1, 1, 8001, ~c"node-a.#{@service}"},
                  {1, 1, 8003, ~c"node-c.#{@service}"}
                ]
              end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes:
              {Nodes, :list_nodes,
               [[:"node-a@#{@service}", :"node-b@#{@service}", :"node-c@#{@service}"]]},
            meta:
              MapSet.new([:"node-a@#{@service}", :"node-b@#{@service}", :"node-c@#{@service}"])
          }
        ]
        |> DynamicSrv.start_link()

        assert_receive {:disconnect, :"node-b@my-service.service.consul"}, 100
      end)
    end

    test "keeps state" do
      capture_log(fn ->
        [
          %Cluster.Strategy.State{
            topology: :dynamic_srv,
            config: [
              service: @service,
              resolver: fn _query ->
                [
                  {1, 1, 8001, ~c"node-a.#{@service}"},
                  {1, 1, 8002, ~c"node-b.#{@service}"},
                  {1, 1, 8003, ~c"node-c.#{@service}"}
                ]
              end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes:
              {Nodes, :list_nodes,
               [[:"node-a@#{@service}", :"node-b@#{@service}", :"node-c@#{@service}"]]},
            meta:
              MapSet.new([:"node-a@#{@service}", :"node-b@#{@service}", :"node-c@#{@service}"])
          }
        ]
        |> DynamicSrv.start_link()

        refute_receive {:disconnect, _}, 100
        refute_receive {:connect, _}, 100
      end)
    end

    test "handles unexpected resolver response" do
      log =
        capture_log(fn ->
          [
            %Cluster.Strategy.State{
              topology: :dynamic_srv,
              config: [
                service: @service,
                resolver: fn _query -> {:error, :nxdomain} end
              ],
              connect: {Nodes, :connect, [self()]},
              disconnect: {Nodes, :disconnect, [self()]},
              list_nodes: {Nodes, :list_nodes, [[]]}
            }
          ]
          |> DynamicSrv.start_link()

          refute_receive {:connect, _}, 100
          refute_receive {:disconnect, _}, 100
        end)

      assert log =~ "Unexpected response from resolver"
    end

    test "ignores SRV records with non-matching hostname format" do
      capture_log(fn ->
        [
          %Cluster.Strategy.State{
            topology: :dynamic_srv,
            config: [
              service: @service,
              resolver: fn _query ->
                [
                  {1, 1, 8001, ~c"node-a.some-other-service.consul"},
                  {1, 1, 8002, ~c"malformed"}
                ]
              end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes: {Nodes, :list_nodes, [[]]}
          }
        ]
        |> DynamicSrv.start_link()

        refute_receive {:connect, _}, 100
      end)
    end

    test "raises when service config is missing" do
      capture_log(fn ->
        Process.flag(:trap_exit, true)

        {:ok, pid} =
          [
            %Cluster.Strategy.State{
              topology: :dynamic_srv,
              config: [],
              connect: {Nodes, :connect, [self()]},
              disconnect: {Nodes, :disconnect, [self()]},
              list_nodes: {Nodes, :list_nodes, [[]]}
            }
          ]
          |> DynamicSrv.start_link()

        assert_receive {:EXIT, ^pid, {%KeyError{key: :service}, _}}, 500
      end)
    end

    test "initializes meta as empty MapSet when meta is nil" do
      capture_log(fn ->
        [
          %Cluster.Strategy.State{
            topology: :dynamic_srv,
            config: [
              service: @service,
              resolver: fn _query -> [] end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes: {Nodes, :list_nodes, [[]]},
            meta: nil
          }
        ]
        |> DynamicSrv.start_link()

        refute_receive {:connect, _}, 100
        refute_receive {:disconnect, _}, 100
      end)
    end

    test "does not connect to itself" do
      me = node()

      capture_log(fn ->
        [
          %Cluster.Strategy.State{
            topology: :dynamic_srv,
            config: [
              service: @service,
              resolver: fn _query ->
                node_name = me |> Atom.to_string() |> String.split("@") |> hd()
                [
                  {1, 1, 8001, ~c"node-a.#{@service}"},
                  {1, 1, 8002, String.to_charlist("#{node_name}.#{@service}")}
                ]
              end
            ],
            connect: {Nodes, :connect, [self()]},
            disconnect: {Nodes, :disconnect, [self()]},
            list_nodes: {Nodes, :list_nodes, [[]]}
          }
        ]
        |> DynamicSrv.start_link()

        expected = :"node-a@#{@service}"
        assert_receive {:connect, ^expected}, 100
        refute_receive {:connect, ^me}, 100
      end)
    end

    test "continues polling after the initial poll" do
      caller = self()
      poll_count = :counters.new(1, [])

      capture_log(fn ->
        [
          %Cluster.Strategy.State{
            topology: :dynamic_srv,
            config: [
              service: @service,
              polling_interval: 50,
              resolver: fn _query ->
                :counters.add(poll_count, 1, 1)
                [{1, 1, 8001, ~c"node-a.#{@service}"}]
              end
            ],
            connect: {Nodes, :connect, [caller]},
            disconnect: {Nodes, :disconnect, [caller]},
            list_nodes: {Nodes, :list_nodes, [[]]}
          }
        ]
        |> DynamicSrv.start_link()

        # Wait long enough for at least 2 polls (initial + 1 recurring)
        Process.sleep(150)

        assert :counters.get(poll_count, 1) >= 2
      end)
    end
  end
end
