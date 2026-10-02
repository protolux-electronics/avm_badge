defmodule Badge.Store.FetchTest do
  use ExUnit.Case, async: true

  alias Badge.Store.Fetch

  test "folds status, body chunks and the end into a body" do
    acc = Fetch.fold([{:status, :r, 200}, {:data, :r, "ab"}], Fetch.new())
    acc = Fetch.fold([{:data, :r, "cd"}, {:done, :r}], acc)

    assert acc.done
    assert acc.bytes == 4
    assert Fetch.result(acc) == {:ok, "abcd"}
  end

  test "a bare :done also ends the transfer, and unknown responses are skipped" do
    acc = Fetch.fold([{:status, :r, 200}, {:header, :r, {"x", "y"}}, :done], Fetch.new())
    assert acc.done
    assert Fetch.result(acc) == {:ok, ""}
  end

  test "anything but 200 is an error" do
    acc = Fetch.fold([{:status, :r, 404}, {:data, :r, "nope"}, {:done, :r}], Fetch.new())
    assert Fetch.result(acc) == {:error, {:status, 404}}
  end

  test "without :ahttp_client the fetch fails instead of raising" do
    assert {:error, _reason} = Fetch.get({:http, "localhost", 1, "/"}, 10)
  end
end
