defmodule Tai.Trading.OrderOutbox do
  @moduledoc """
  Convert submissions into orders and send them to the exchange
  """

  use GenServer

  require Logger

  alias Tai.PubSub
  alias Tai.Trading.{Orders, OrderResponses, OrderStatus}

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    PubSub.subscribe(:order_enqueued)

    {:ok, state}
  end

  def handle_call({:add, submissions}, _from, state) do
    new_orders = submissions
                 |> Orders.add
                 |> Enum.map(&broadcast_enqueued_order/1)

    {:reply, new_orders, state}
  end

  def handle_info({:order_enqueued, order}, state) do
    {:ok, _pid} = Task.start_link(fn ->
      Tai.Exchanges.Account.buy_limit(order.exchange, order.symbol, order.price, order.size)
      |> handle_buy_limit_response(order)
    end)

    {:noreply, state}
  end

  @doc """
  Create new orders to be sent to their exchange in the background
  """
  def add(submissions) do
    GenServer.call(__MODULE__, {:add, submissions})
  end

  defp broadcast_enqueued_order(order) do
    PubSub.broadcast(:order_enqueued, {:order_enqueued, order})
    order
  end

  defp handle_buy_limit_response(
    {
      :ok,
      %OrderResponses.Created{id: server_id, created_at: created_at}
    },
    order
  ) do
    pending_order = Orders.update(
      order.client_id,
      server_id: server_id,
      created_at: created_at,
      status: OrderStatus.pending
    )
    PubSub.broadcast(:order_create_ok, {:order_create_ok, pending_order})
  end
  defp handle_buy_limit_response({:error, reason}, order) do
    error_order = Orders.update(order.client_id, status: OrderStatus.error)
    PubSub.broadcast(:order_create_error, {:order_create_error, reason, error_order})
  end
end