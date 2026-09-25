defmodule CornermanTest do
  use ExUnit.Case
  doctest Cornerman

  test "greets the world" do
    assert Cornerman.hello() == :world
  end
end
