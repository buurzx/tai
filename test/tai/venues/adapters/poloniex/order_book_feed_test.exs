defmodule Tai.Venues.Adapters.Poloniex.OrderBookFeedTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  @currency_pair_channel_id_mappings %{
    "USDT_BTC" => 121
  }

  def send_feed_order_book_change(pid, currency_pair, changes) do
    Tai.WebSocket.send_json_msg(pid, [
      @currency_pair_channel_id_mappings[currency_pair],
      2,
      changes
    ])
  end

  defp send_feed_snapshot(pid, currency_pair, bids, asks) do
    Tai.WebSocket.send_json_msg(pid, [
      @currency_pair_channel_id_mappings[currency_pair],
      2,
      [
        [
          "i",
          %{
            "currencyPair" => currency_pair,
            "orderBook" => [asks, bids]
          }
        ]
      ]
    ])
  end

  setup do
    on_exit(fn ->
      Application.stop(:tai)
    end)

    {:ok, _} = Application.ensure_all_started(:tai)
    Process.register(self(), :test)

    my_poloniex_feed_btc_usd_pid =
      start_supervised!(
        {Tai.Markets.OrderBook, [feed_id: :my_poloniex_feed, symbol: :btc_usdt]},
        id: :my_poloniex_feed_btc_usdt
      )

    my_poloniex_feed_ltc_usd_pid =
      start_supervised!(
        {Tai.Markets.OrderBook, [feed_id: :my_poloniex_feed, symbol: :ltc_usdt]},
        id: :my_poloniex_feed_ltc_usdt
      )

    my_feed_b_btc_usd_pid =
      start_supervised!(
        {Tai.Markets.OrderBook, [feed_id: :my_feed_b, symbol: :btc_usdt]},
        id: :my_feed_b_btc_usdt
      )

    {:ok, my_poloniex_feed_pid} =
      Tai.VenueAdapters.Poloniex.OrderBookFeed.start_link(
        "ws://localhost:#{EchoBoy.Config.port()}/ws",
        feed_id: :my_poloniex_feed,
        symbols: [:btc_usd, :ltc_usd]
      )

    Tai.Markets.OrderBook.replace(%Tai.Markets.OrderBook{
      venue_id: :my_poloniex_feed,
      product_symbol: :ltc_usdt,
      bids: %{100.0 => {0.1, nil, nil}},
      asks: %{100.1 => {0.1, nil, nil}}
    })

    Tai.Markets.OrderBook.replace(%Tai.Markets.OrderBook{
      venue_id: :my_feed_b,
      product_symbol: :btc_usdt,
      bids: %{1.0 => {1.1, nil, nil}},
      asks: %{1.2 => {0.1, nil, nil}}
    })

    start_supervised!({
      Support.ForwardOrderBookEvents,
      [feed_id: :my_poloniex_feed, symbol: :btc_usdt]
    })

    {
      :ok,
      %{
        my_poloniex_feed_pid: my_poloniex_feed_pid,
        my_poloniex_feed_btc_usd_pid: my_poloniex_feed_btc_usd_pid,
        my_poloniex_feed_ltc_usd_pid: my_poloniex_feed_ltc_usd_pid,
        my_feed_b_btc_usd_pid: my_feed_b_btc_usd_pid
      }
    }
  end

  test("initialization replaces the bids/asks in the order book for the symbol", %{
    my_poloniex_feed_pid: my_poloniex_feed_pid,
    my_poloniex_feed_btc_usd_pid: my_poloniex_feed_btc_usd_pid,
    my_poloniex_feed_ltc_usd_pid: my_poloniex_feed_ltc_usd_pid,
    my_feed_b_btc_usd_pid: my_feed_b_btc_usd_pid
  }) do
    send_feed_snapshot(
      my_poloniex_feed_pid,
      "USDT_BTC",
      %{"110.0" => "100.0", "100.0" => "110.0"},
      %{
        "120.0" => "10.0",
        "130.0" => "11.0"
      }
    )

    assert_receive {:order_book_snapshot, :my_poloniex_feed, :btc_usdt, %Tai.Markets.OrderBook{}}
    assert {:ok, p_btc_usd_book} = Tai.Markets.OrderBook.quotes(my_poloniex_feed_btc_usd_pid)

    assert [
             %Tai.Markets.PriceLevel{price: 110.0, size: 100.0, server_changed_at: nil} = bid_a,
             %Tai.Markets.PriceLevel{price: 100.0, size: 110.0, server_changed_at: nil} = bid_b
           ] = p_btc_usd_book.bids

    assert [
             %Tai.Markets.PriceLevel{price: 120.0, size: 10.0, server_changed_at: nil} = ask_a,
             %Tai.Markets.PriceLevel{price: 130.0, size: 11.0, server_changed_at: nil} = ask_b
           ] = p_btc_usd_book.asks

    assert DateTime.compare(bid_a.processed_at, bid_b.processed_at)
    assert DateTime.compare(bid_a.processed_at, ask_a.processed_at)
    assert DateTime.compare(bid_a.processed_at, ask_b.processed_at)

    assert {:ok, p_ltc_usd_book} = Tai.Markets.OrderBook.quotes(my_poloniex_feed_ltc_usd_pid)

    assert p_ltc_usd_book.bids == [
             %Tai.Markets.PriceLevel{price: 100.0, size: 0.1, processed_at: nil}
           ]

    assert p_ltc_usd_book.asks == [
             %Tai.Markets.PriceLevel{price: 100.1, size: 0.1, processed_at: nil}
           ]

    assert {:ok, b_btc_usd_book} = Tai.Markets.OrderBook.quotes(my_feed_b_btc_usd_pid)

    assert b_btc_usd_book.bids == [
             %Tai.Markets.PriceLevel{price: 1.0, size: 1.1, processed_at: nil}
           ]

    assert b_btc_usd_book.asks == [
             %Tai.Markets.PriceLevel{price: 1.2, size: 0.1, processed_at: nil}
           ]
  end

  test("order book changes adds/updates/deletes the bids/asks", %{
    my_poloniex_feed_pid: my_poloniex_feed_pid,
    my_poloniex_feed_btc_usd_pid: my_poloniex_feed_btc_usd_pid,
    my_poloniex_feed_ltc_usd_pid: my_poloniex_feed_ltc_usd_pid,
    my_feed_b_btc_usd_pid: my_feed_b_btc_usd_pid
  }) do
    send_feed_snapshot(
      my_poloniex_feed_pid,
      "USDT_BTC",
      %{},
      %{}
    )

    assert_receive {:order_book_snapshot, :my_poloniex_feed, :btc_usdt, %Tai.Markets.OrderBook{}}

    send_feed_order_book_change(my_poloniex_feed_pid, "USDT_BTC", [
      ["o", 1, "0.9", "0.1"],
      ["o", 0, "1.4", "0.12"],
      ["o", 1, "1.0", "1.2"],
      ["o", 0, "1.2", "0.11"],
      ["o", 1, "1.1", "0"],
      ["o", 0, "1.3", "0.0"]
    ])

    assert_receive {:order_book_changes, :my_poloniex_feed, :btc_usdt, %Tai.Markets.OrderBook{}}

    assert {:ok, p_btc_usd_book} = Tai.Markets.OrderBook.quotes(my_poloniex_feed_btc_usd_pid)

    assert [
             %Tai.Markets.PriceLevel{price: 1.0, size: 1.2} = bid_a,
             %Tai.Markets.PriceLevel{price: 0.9, size: 0.1} = bid_b
           ] = p_btc_usd_book.bids

    assert [
             %Tai.Markets.PriceLevel{price: 1.2, size: 0.11} = ask_a,
             %Tai.Markets.PriceLevel{price: 1.4, size: 0.12} = ask_b
           ] = p_btc_usd_book.asks

    assert DateTime.compare(bid_a.processed_at, bid_b.processed_at)
    assert DateTime.compare(bid_a.processed_at, ask_a.processed_at)
    assert DateTime.compare(bid_a.processed_at, ask_b.processed_at)

    assert {:ok, p_ltc_usd_book} = Tai.Markets.OrderBook.quotes(my_poloniex_feed_ltc_usd_pid)

    assert p_ltc_usd_book.bids == [
             %Tai.Markets.PriceLevel{price: 100.0, size: 0.1, processed_at: nil}
           ]

    assert p_ltc_usd_book.asks == [
             %Tai.Markets.PriceLevel{price: 100.1, size: 0.1, processed_at: nil}
           ]

    assert {:ok, b_btc_usd_book} = Tai.Markets.OrderBook.quotes(my_feed_b_btc_usd_pid)

    assert b_btc_usd_book.bids == [
             %Tai.Markets.PriceLevel{price: 1.0, size: 1.1, processed_at: nil}
           ]

    assert b_btc_usd_book.asks == [
             %Tai.Markets.PriceLevel{price: 1.2, size: 0.1, processed_at: nil}
           ]
  end

  test "logs a warning for unhandled messages", %{
    my_poloniex_feed_pid: my_poloniex_feed_pid
  } do
    log_msg =
      capture_log(fn ->
        Tai.WebSocket.send_json_msg(my_poloniex_feed_pid, %{type: "unknown_type"})
        :timer.sleep(100)
      end)

    assert log_msg =~ "unhandled message: %{\"type\" => \"unknown_type\"}"
  end
end
