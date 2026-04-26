# soot_device_protocol — Quality Review

Findings against the playbook in `../QUALITY-REVIEW.md`. Baseline:
70 tests, 0 failures; `mix format` dirty in one file; library not yet
on a CI gate.

## Correctness / refactors

1. **Bare `rescue _` swallows error type**
   `lib/soot_device_protocol/storage/local.ex:40-44` —
   `try { :erlang.binary_to_term(bin) } rescue _ -> :error`. Either
   match `ArgumentError` (the only thing `binary_to_term` raises for
   corrupt input) or let it propagate; bare rescues hide load-bearing
   errors like `:badarg` from the wrong arity.

2. **Bare `rescue _` falls back silently**
   `lib/soot_device_protocol/contract/bundle.ex:183-185` —
   `public_keys_for_pem/1` rescues anything and falls back to a raw
   `:public_key.pem_decode/1` walk. The fallback exists because
   `X509.from_pem/1` is fussy about PEMs containing a single `EC PARAMETERS`
   block. Match the specific exception (`MatchError`, `FunctionClauseError`)
   or refactor so both branches share one decode path.

3. **`HTTPC.ssl_options/1` is `def @doc false` but only called internally**
   `lib/soot_device_protocol/http_client/httpc.ex:60`. Make it `defp` —
   nothing outside the module references it.

## Re-integration (soot_device_test dissolution)

`soot_device_test` no longer exists as a separate library; its fixtures
already live under `test/support/` here with the
`SootDeviceProtocol.Test.*` namespace. To finish the dissolution,
promote them into `lib/` so downstream consumers (soot_device tests,
end-user device tests) can `alias SootDeviceProtocol.Test.{FakeHTTP,
Ingest, PKI}` through the path/hex dep:

* `test/support/fake_http.ex` → `lib/soot_device_protocol/test/fake_http.ex`
* `test/support/ingest.ex`    → `lib/soot_device_protocol/test/ingest.ex`
* `test/support/test_pki.ex`  → `lib/soot_device_protocol/test/pki.ex`
  (filename normalised; module already `SootDeviceProtocol.Test.PKI`)
* `mix.exs` — drop `only: :test` from `:plug`, drop `test/support` from
  `elixirc_paths(:test)`.

## Test gaps

* `SootDeviceProtocol.Contract.CanonicalJSON` — no direct test. Used by
  Bundle and PKI fixture; canonicalisation is load-bearing for
  signature verification, so add direct unit tests for sort order,
  nested maps, lists, primitives.
* `SootDeviceProtocol.MQTT.Message.new/3` — public, tested only as a
  side-effect of Client tests. Add a small unit test.
* `SootDeviceProtocol.HTTPClient.HTTPC.ssl_options/1` (or its
  private replacement) — tested only indirectly through Enrollment.
  Add a unit test that asserts `:cert`, `:key`, `:cacerts`,
  `:verify`, `:server_name_indication`, `:customize_hostname_check`
  appear and that `nil` cert/key + empty trust returns `[]`.
* `SootDeviceProtocol.Supervisor` — not tested at all. Its
  `:rest_for_one` order is load-bearing (Enrollment must be running
  before Contract.Refresh, before MQTT.Client). Add an integration
  test that boots the supervisor with the Memory storage + Test MQTT
  transport + FakeHTTP + a PKI-built bundle and asserts all children
  are `:running`.

## Tooling gaps

* `mix format --check-formatted` fails on
  `test/support/fake_http.ex` (one map literal needs wrapping).
* No `.tool-versions` — pin Elixir/Erlang.
* No `LICENSE` file — `mix.exs` package files glob references it.
* No `CHANGELOG.md` — same.
* No `.credo.exs` — `:credo` is in deps but unconfigured.
* No `dialyxir`, `sobelow`, `mix_audit` — playbook gate references all
  three.
* No `.dialyzer_ignore.exs`.
* No `.github/workflows/`.
* No `usage-rules.md`.

## Stylistic

* `extra_applications: [:logger, :public_key, :crypto, :ssl, :inets]` —
  `:ssl` already pulls `:crypto` and `:public_key`. Leaving them
  explicit is harmless but the playbook flags it as redundant; trim
  to `[:logger, :ssl, :inets]`.

## Out of scope

* `MQTT.Transport.EMQTT` is untested — requires a real broker or heavy
  mocking. Acceptable per the playbook's "skip the playbook" guidance
  for hardware/network-dependent code.
* `:emqtt` C-NIF (quicer) compile warnings — upstream, not ours.

## Commit plan

Following the playbook's commit order:

1. `mix format` (test/support/fake_http.ex)
2. `LICENSE` + `mix.exs` `package` polish + `extra_applications` trim
3. Re-integration: move fixtures to `lib/`, drop `test/support` from
   `elixirc_paths`, promote `:plug` to a non-test dep
4. Correctness: typed rescues in `Storage.Local` and `Bundle`; make
   `HTTPC.ssl_options/1` private (export the dep on `decode_cert!` / `decode_key!`
   handling via a small `@doc false` shim if a unit test needs it)
5. Misc cleanups (none currently)
6. Test infra (capture_log, async true is already on)
7. New tests: CanonicalJSON, MQTT.Message, HTTPC ssl options,
   Supervisor integration
8. `.tool-versions`, `CHANGELOG.md`
9. `.github/workflows/ci.yml`
10. Lint stack — credo + sobelow + mix_audit + ex_doc + config
11. Dialyzer with PLT and ignore file
