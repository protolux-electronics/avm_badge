defmodule Badge.Bluesky.HttpTest do
  use ExUnit.Case, async: true

  alias Badge.Bluesky.Http

  describe "endpoint/1" do
    test "the scheme picks the port and a trailing slash is dropped" do
      assert Http.endpoint("https://public.api.bsky.app") ==
               {:https, "public.api.bsky.app", 443}

      assert Http.endpoint("http://192.168.1.10/") == {:http, "192.168.1.10", 80}
      assert Http.endpoint("http://bench:8080/proxy") == {:http, "bench", 8080}
    end

    test "anything else is not an endpoint" do
      assert Http.endpoint("ftp://x") == nil
      assert Http.endpoint("https://") == nil
      assert Http.endpoint("http://bench:port") == nil
      assert Http.endpoint("http://bench:70000") == nil
    end
  end

  describe "query/1" do
    test "joins the pairs and percent-encodes the values" do
      assert Http.query([
               {"feed", "at://did:plc:ab/app.bsky.feed.generator/x y"},
               {"limit", "10"}
             ]) ==
               "?feed=at%3A%2F%2Fdid%3Aplc%3Aab%2Fapp.bsky.feed.generator%2Fx%20y&limit=10"
    end

    test "a name may repeat" do
      assert Http.query([{"feeds", "a"}, {"feeds", "b"}]) == "?feeds=a&feeds=b"
    end

    test "unreserved characters pass through" do
      assert Http.query([{"handle", "goat-mcmire_1.bsky.social~"}]) ==
               "?handle=goat-mcmire_1.bsky.social~"
    end
  end

  test "bearer/1 is an authorization header" do
    assert Http.bearer("abc") == {"authorization", "Bearer abc"}
  end

  test "decode/1 reads JSON and refuses anything else" do
    assert Http.decode(~s({"a":1})) == {:ok, %{"a" => 1}}
    assert Http.decode("{nope") == :error
  end
end
