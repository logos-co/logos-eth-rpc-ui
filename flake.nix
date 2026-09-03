{
  description = "Logos eth_rpc_ui — device-wide JSON-RPC endpoints and verified routing for every Logos wallet on this device.";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # The dependency must build against THIS module-builder. Without the follows it drags
    # its own, and a skewed generated ABI segfaults the module inside provider init.
    #
    # The locked rev PREDATES verified routing: `verified_proxy_status` and
    # `set_verified_proxy_mode` are unpushed, so a bare `nix build` cannot compile the verdict
    # half of this panel. Build with
    #   --override-input eth_rpc_module git+file://$PWD/../eth-rpc-module
    # until that work lands upstream, then re-lock.
    eth_rpc_module = {
      url = "github:logos-co/logos-evm-eth-rpc-module";
      inputs.logos-module-builder.follows = "logos-module-builder";
    };
  };

  # mkLogosQmlModule, NOT mkLogosModule: the generic builder compiles the plugin but never
  # assembles the QML, so the .lgx step then fails with "view file not found in staged payload".
  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
