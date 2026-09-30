defmodule Badge.EspnowVendorTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "the espnow wrapper is compiled into the project" do
    assert Code.ensure_loaded?(:espnow)

    for {name, arity} <- [open: 1, close: 1, send: 3, add_peer: 3, del_peer: 2, get_channel: 1] do
      assert function_exported?(:espnow, name, arity), "espnow:#{name}/#{arity} missing"
    end
  end

  test "the vendored source keeps its licence beside it" do
    assert File.regular?(Path.join(@root, "src/espnow.erl"))
    licence = File.read!(Path.join(@root, "src/LICENSE.espnow"))
    assert licence =~ "Apache License"
  end

  test "the build compiles Erlang from src" do
    assert Mix.Project.config()[:erlc_paths] == ["src"]
  end
end
