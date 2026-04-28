# Each entry must be a real warning Dialyzer is currently emitting,
# otherwise list_unused_filters?: true causes the run to fail.
[
  # Duxedo.Streams typespecs declare {:ok, _} | :ok return shapes but
  # the actual implementation also returns `:error` for unknown
  # streams (covered by Buffer.DuxedoTest "take/3 on undefined stream
  # returns []"). Until Duxedo's specs are corrected, the defensive
  # `:error` arms in Buffer.Duxedo are reachable in practice and must
  # stay. The dialyzer warnings on those arms are spec-driven false
  # positives.
  {"lib/soot_device_protocol/telemetry/buffer/duxedo.ex", :pattern_match}
]
