# Changelog

## v0.1.0 — Unreleased

Initial public release. Imperative device-side runtime for the Soot
framework.

### Added

* `SootDeviceProtocol.Storage` behavior with `Memory` (ETS) and `Local`
  (file-system) implementations.
* `SootDeviceProtocol.Enrollment` GenServer: bootstrap-cert + token →
  operational mTLS identity via CSR against `/enroll`.
* `SootDeviceProtocol.Contract.{Bundle, CanonicalJSON, Refresh}`:
  manifest+asset fetch, signature verification against trust PEMs,
  fingerprint-based no-op detection, persisted state.
* `SootDeviceProtocol.HTTPClient` behavior + `:httpc` implementation
  with mTLS.
* `SootDeviceProtocol.MQTT.{Client, Message, Transport}` behavior with
  `EMQTT` (production, optional dep) and in-memory `Test` transports;
  MQTT-5 publish / invoke (correlation roundtrip) / dispatch with
  topic-filter wildcard matching.
* `SootDeviceProtocol.Shadow.Sync`: desired/delta/reported reconciliation
  with handler dispatch and persistence.
* `SootDeviceProtocol.Commands.Dispatcher`: routes command messages to
  handlers, validates payload format, publishes correlation replies.
* `SootDeviceProtocol.Telemetry.{Buffer, Encoder, Pipeline}`: pluggable
  buffer + encoder behaviors, ETS Memory buffer, JSONLines encoder,
  per-stream sequence persistence, retention prune, exponential backoff
  with 409 → drop+refresh / 410 → drop semantics.
* `SootDeviceProtocol.Supervisor`: `:rest_for_one` wiring of all of the
  above so users compose a working device with a single supervisor
  child.
* `SootDeviceProtocol.Test.{FakeHTTP, Ingest, PKI}` fixtures shipped in
  `lib/` for downstream test suites — supersedes the now-dissolved
  `soot_device_test` library.
