# logos-eth-rpc-ui

Basecamp panel for [`eth_rpc_module`](https://github.com/logos-co/logos-evm-eth-rpc-module):
the JSON-RPC endpoint and the light-client verified-routing mode, per chain.

A `ui_qml` module — a QML view (`src/qml/EthRpcView.qml`) over a small C++ backend
(`src/eth_rpc_ui_backend.{h,cpp}`) whose QML-facing surface is the QtRO contract in
`src/eth_rpc_ui.rep`.

```bash
git add -A   # nix only sees git-tracked files
nix build '.#lgx'
```

## Why this is its own app and not a page in the wallet

`eth_rpc_module` persists `chains.json` in *its* instance directory, and that store is
**device-wide**: every Logos wallet on the device reads the endpoints configured here.
`eth_wallet_backend` already treats it that way — it *seeds* a chain rather than overwriting
one, and patches a single field when the endpoint changes, so a sibling wallet's tuning
survives. A device-wide store edited from inside one wallet's Settings sheet is a category
error: the wallet's Settings should configure the wallet.

So the wallet loses `set_rpc_url` and `set_verified_proxy_mode` outright. It still *shows*
the verified verdict in full — the chip, the banner, the frozen-rows notice — it just cannot
**set** it. That is what makes the split enforced rather than a convention.

## Five decisions worth knowing

**The chain roster is cosmetic.** `list_chains` returns only *configured* chains, so a fresh
device offers nothing. This app carries its own display-name table (Ethereum, Sepolia, Hoodi)
and merges it with whatever eth_rpc holds plus whatever the user types into "Add chain by id".
That table is **not** an allowlist and not a security boundary: eth_rpc will configure any
chain id, and an id with no name renders as `Chain 42161` with no `testnet` claim at all —
absent, never `false`, because calling an unrecognised chain "mainnet" is the one wrong answer.
The wallet's `networks::ALL` is deliberately *not* imported: that is the wallet's allowlist and
it answers a different question.

**The config is pushed; only the verdict is polled.** This app is a viewer of a store it does
not own — `eth_wallet_backend` seeds chains through `init_defaults` and `seed_chain_config`,
and a second instance of this app edits the same file. `chain_config_changed` is subscribed
and re-reads the roster. `verified_proxy_mode_changed` is deliberately not: eth_rpc emits it
*alongside* the config event for every mode change, so subscribing to both would refresh twice
for one move. The writes here keep their own `refresh()` regardless, because a **refused**
write emits nothing and the switch has to snap back to what eth_rpc still says.

**The verdict is polled, and only the selected chain's.** `verified_proxy_status` spends a
real probe budget (a `modules_state` listing plus a call into the proxy) whenever a chain is
set to `required`; polling every chain would pay that N times over. The interval is 5000 ms,
matching eth_rpc's own verdict TTL, and three consecutive silent polls (~15 s) retire the badge
to "could not be read" rather than leaving a stale `ready` on screen while nothing is verifying.

**`verified_proxy_status` and `verify_chain_id` are asynchronous; the config calls are not.**
Both of those spend real budgets and this backend runs on the GUI thread. `get_chain_config`,
`list_chains`, `patch_*` and `remove_chain_config` are in-memory reads and a file write, so
they stay synchronous. The async guard is a *deadline* (`InFlight`), never a latch — a callback
that never fires must not wedge the probe shut for good.

**Saving an endpoint saves only the endpoint.** `patch_chain_endpoint`, not
`set_chain_config`: the store is shared, so a user retyping a URL must not silently reset
another wallet's verified mode or transport timeouts. Same reasoning for the mode and the
timeouts — each writes one thing.

**The panel is built from `Logos.Controls` on `Logos.Theme`, and nothing declares it.** The
design system is compiled into the *host* binary as static `qt_add_qml_module` targets under
`qrc:/qt/qml`, and a `ui_qml` view is loaded by the host's own `QQmlEngine`. There is no flake
input, no `metadata.json` key and nothing staged into the `.lgx`. Two things break it at
*runtime* rather than at build time: shipping your own `src/qml/qmldir` (the builder generates
one carrying this module's private URI, and overwriting it lets Qt's process-global type cache
cross-match another plugin's same-named types), and creating a `src/qml/Logos/` directory (the
host's `RestrictedUrlInterceptor` reserves that prefix case-insensitively).

## Known limits

- **Chain ids are `int` on the wire.** The `.rep` carries `chainId` as `int`, so an id above
  2^31 cannot be selected, edited or removed from here. The "Add chain by id" field says so,
  and a configured chain with such an id is dropped from the list rather than shown as a row
  that cannot be acted on.
- **`timeoutSecs` above ~20 s has no effect** — the Logos call deadline fires first. The
  verified leg is additionally clamped to 1–60 s inside eth_rpc.
- **One chain's verdict at a time.** A screen showing all three verdicts at once would need a
  batched verdict call in `eth_rpc_module`, which does not exist.

## Build

`ws build` **SKIPs** the EVM repos — they have no `dep-graph.nix` entry — and exits 0, so a
green `ws build` here proves nothing. Build directly:

```bash
nix build '.#lgx'
```

`nix` only sees git-tracked files: `git add -A` before every build.
