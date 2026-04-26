defmodule SootDeviceProtocol.Backoff do
  @moduledoc """
  Capped exponential backoff with full jitter.

  Used everywhere the device retries a network operation: enrollment,
  contract refresh, telemetry uploads, ingest retries. There is no
  time-sync wait before the first attempt — TLS retries are the
  answer, the device just keeps trying with backoff until the
  backend's clock is in range.

  ## Use

      backoff = Backoff.new(initial: 1_000, max: 60_000)

      case do_thing() do
        :ok -> Backoff.reset(backoff)
        {:error, _} -> {delay, backoff} = Backoff.next(backoff); ...
      end

  ## Algorithm

  Full-jitter exponential backoff
  (see https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/):

      base = min(max, initial * 2^attempts)
      delay = rand(0, base)

  This avoids thundering-herd retries from synchronized failures.

  ## Why jitter

  Without jitter, a fleet that lost connectivity at the same moment
  reconnects in lockstep, hammering the backend. The jitter spreads
  the retries across the backoff window so the load returns smoothly.
  """

  @enforce_keys [:initial, :max]
  defstruct [:initial, :max, attempts: 0]

  @type t :: %__MODULE__{
          initial: pos_integer(),
          max: pos_integer(),
          attempts: non_neg_integer()
        }

  @doc "Build a backoff with `:initial` and `:max` durations in ms."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      initial: Keyword.get(opts, :initial, 1_000),
      max: Keyword.get(opts, :max, 5 * 60_000)
    }
  end

  @doc """
  Compute the next jittered delay (ms) and return the updated state.

  The delay is uniformly random in `[0, base]` where `base = min(max,
  initial * 2^attempts)` — full-jitter exponential. Use the random
  function in `:rand`; tests can override via the `:rand_fn` option.
  """
  @spec next(t(), keyword()) :: {non_neg_integer(), t()}
  def next(%__MODULE__{} = state, opts \\ []) do
    rand_fn = Keyword.get(opts, :rand_fn, &default_rand/1)
    base = min(state.max, state.initial * Integer.pow(2, state.attempts))
    delay = rand_fn.(base)
    {delay, %{state | attempts: state.attempts + 1}}
  end

  @doc "Reset the attempt counter after a successful operation."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = state), do: %{state | attempts: 0}

  defp default_rand(0), do: 0
  defp default_rand(base) when base > 0, do: :rand.uniform(base) - 1
end
