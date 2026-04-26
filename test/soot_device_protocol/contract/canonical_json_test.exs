defmodule SootDeviceProtocol.Contract.CanonicalJSONTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Contract.CanonicalJSON

  describe "encode!/1" do
    test "sorts top-level map keys lexicographically" do
      assert CanonicalJSON.encode!(%{"b" => 2, "a" => 1, "c" => 3}) ==
               ~s({"a":1,"b":2,"c":3})
    end

    test "sorts nested map keys lexicographically" do
      assert CanonicalJSON.encode!(%{"outer" => %{"z" => 1, "a" => 2}}) ==
               ~s({"outer":{"a":2,"z":1}})
    end

    test "stringifies atom keys before sorting" do
      assert CanonicalJSON.encode!(%{b: 1, a: 2}) == ~s({"a":2,"b":1})
    end

    test "preserves list order" do
      assert CanonicalJSON.encode!([3, 1, 2]) == "[3,1,2]"
    end

    test "recurses into list elements" do
      assert CanonicalJSON.encode!([%{"b" => 1, "a" => 2}]) ==
               ~s([{"a":2,"b":1}])
    end

    test "stringifies non-boolean atoms as values" do
      assert CanonicalJSON.encode!(%{"k" => :foo}) == ~s({"k":"foo"})
    end

    test "preserves nil/true/false as JSON literals" do
      assert CanonicalJSON.encode!(%{"a" => nil, "b" => true, "c" => false}) ==
               ~s({"a":null,"b":true,"c":false})
    end

    test "encodes DateTime as ISO8601 string" do
      dt = ~U[2026-04-26 12:00:00Z]
      assert CanonicalJSON.encode!(%{"at" => dt}) ==
               ~s({"at":"2026-04-26T12:00:00Z"})
    end

    test "encodes Date as ISO8601 string" do
      assert CanonicalJSON.encode!(%{"on" => ~D[2026-04-26]}) ==
               ~s({"on":"2026-04-26"})
    end

    test "produces a stable byte-identical output for same input" do
      payload = %{"version" => 1, "fingerprint" => "abc", "assets" => %{"b.json" => 1, "a.json" => 2}}
      assert CanonicalJSON.encode!(payload) == CanonicalJSON.encode!(payload)
    end
  end
end
