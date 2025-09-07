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
  end
end
