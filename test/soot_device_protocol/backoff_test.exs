defmodule SootDeviceProtocol.BackoffTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Backoff

  test "doubles base up to the configured max" do
    b = Backoff.new(initial: 100, max: 800)
    rand_fn = fn base -> base end

    {delays, _} =
      Enum.map_reduce(1..6, b, fn _i, acc ->
        {delay, acc} = Backoff.next(acc, rand_fn: rand_fn)
        {delay, acc}
      end)

    assert delays == [100, 200, 400, 800, 800, 800]
  end

  test "next/2 is bounded above by base" do
    b = Backoff.new(initial: 100, max: 1_000)

    Enum.reduce(1..50, b, fn _i, acc ->
      {delay, acc2} = Backoff.next(acc)
      assert delay >= 0
      base = min(acc.max, acc.initial * Integer.pow(2, acc.attempts))
      assert delay <= base
      acc2
    end)
  end

  test "reset clears the attempt counter" do
    rand_fn = fn base -> base end
    b = Backoff.new(initial: 100, max: 1_000)
    {_, b} = Backoff.next(b, rand_fn: rand_fn)
    {_, b} = Backoff.next(b, rand_fn: rand_fn)
    {delay_after_reset, _} = Backoff.next(Backoff.reset(b), rand_fn: rand_fn)
    assert delay_after_reset == 100
  end

  test "rand_fn override produces deterministic delays" do
    b = Backoff.new(initial: 50, max: 500)
    {delay, _} = Backoff.next(b, rand_fn: fn _base -> 17 end)
    assert delay == 17
  end
end
