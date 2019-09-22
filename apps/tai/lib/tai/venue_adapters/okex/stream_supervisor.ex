defmodule Tai.VenueAdapters.OkEx.StreamSupervisor do
  use Supervisor
  alias Tai.VenueAdapters.OkEx.Stream

  @type venue_id :: Tai.Venues.Adapter.venue_id()
  @type channel :: Tai.Venues.Adapter.channel()
  @type product :: Tai.Venues.Product.t()

  @spec start_link(
          venue_id: atom,
          channels: [channel],
          accounts: map,
          products: [product],
          opts: map
        ) ::
          Supervisor.on_start()
  def start_link([venue_id: venue_id, channels: _, accounts: _, products: _, opts: _] = args) do
    Supervisor.start_link(__MODULE__, args, name: :"#{__MODULE__}_#{venue_id}")
  end

  # TODO: Make this configurable
  @endpoint "wss://real.okex.com:8443/ws/v3"

  def init(
        venue_id: venue_id,
        channels: channels,
        accounts: accounts,
        products: products,
        opts: _
      ) do
    order_books = build_order_books(products)
    order_book_stores = build_order_book_stores(products)

    system = [
      {Stream.RouteOrderBooks, [venue: venue_id, products: products]},
      {Stream.ProcessAuth, [venue: venue_id]},
      {Stream.ProcessOptionalChannels, [venue: venue_id]},
      {Stream.Connection,
       [
         endpoint: @endpoint,
         venue: venue_id,
         channels: channels,
         account: accounts |> Map.to_list() |> List.first(),
         products: products
       ]}
    ]

    (order_books ++ order_book_stores ++ system)
    |> Supervisor.init(strategy: :one_for_one)
  end

  # TODO: Potentially this could use new order books? Send the change quote
  # event to subscribing advisors?
  defp build_order_books(products) do
    products
    |> Enum.map(fn p ->
      name = Tai.Markets.OrderBook.to_name(p.venue_id, p.symbol)

      %{
        id: name,
        start: {
          Tai.Markets.OrderBook,
          :start_link,
          [[feed_id: p.venue_id, symbol: p.symbol]]
        }
      }
    end)
  end

  defp build_order_book_stores(products) do
    products
    |> Enum.map(fn p ->
      %{
        id: Stream.ProcessOrderBook.to_name(p.venue_id, p.venue_symbol),
        start: {
          Stream.ProcessOrderBook,
          :start_link,
          [[venue_id: p.venue_id, symbol: p.symbol, venue_symbol: p.venue_symbol]]
        }
      }
    end)
  end
end
