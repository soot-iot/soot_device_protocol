# soot_device_protocol

Imperative device-side runtime for the [Soot](../soot) framework. Implements
the five behaviors a Soot device honors: identity / enrollment, contract
refresh, MQTT transport, shadow sync, commands, and telemetry.

This is the lean substrate: each component is a supervised GenServer with a
documented API and a swappable behavior under it. The declarative
`soot_device` DSL is sugar on top of this layer; both surfaces hit the same
imperative implementation.

## Phase status

* **D1 — skeleton + enrollment + contract refresh + MQTT client.** Shipped.
* **D2 — shadow sync + commands dispatcher.** Pending.
* **D3 — telemetry pipeline (local buffer + ingest uploader).** Pending.

## Usage sketch

```elixir
{:ok, storage} = SootDeviceProtocol.Storage.Local.open("/data/soot")

children = [
  {SootDeviceProtocol.Supervisor,
   storage: storage,
   enrollment: [
     enroll_url: "https://soot.example.com/enroll",
     enrollment_token: System.fetch_env!("SOOT_ENROLL_TOKEN"),
     bootstrap_cert: File.read!("/data/pki/bootstrap.pem"),
     bootstrap_key: File.read!("/data/pki/bootstrap.key"),
     trust_pems: [File.read!("/data/pki/trust_chain.pem")],
     subject: "/CN=ACME-EU-WIDGET-0001-000001"
   ],
   contract_refresh: [
     url: "https://soot.example.com/.well-known/soot/contract",
     trust_pems: [File.read!("/data/pki/trust_chain.pem")],
     on_change: &MyApp.Contract.applied/1
   ],
   mqtt: [
     transport: SootDeviceProtocol.MQTT.Transport.EMQTT,
     transport_opts: [
       host: ~c"broker.example.com",
       port: 8883,
       ssl: true,
       ssl_opts: [
         certfile: "/data/pki/operational.pem",
         keyfile: "/data/pki/operational.key",
         cacertfile: "/data/pki/trust_chain.pem",
         verify: :verify_peer
       ]
     ]
   ]}
]

Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
```

See `DEVICE-SPEC.md` in the [`soot`](../soot) repo for the full architecture.
