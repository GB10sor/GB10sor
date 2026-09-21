{
  description = "GB10sor: reproducible DGX Spark model deployment shells";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/c25784012c9982bca5b3e0de87e90bbdac8927d3";
    sglang-omni = {
      url = "github:sgl-project/sglang-omni/5207c5dbc45bd7fe8062bc9a222ea6121f990349";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, sglang-omni }:
    let
      system = "aarch64-linux";
      lib = nixpkgs.lib;
      pkgs = import nixpkgs {
        inherit system;
        config = { allowUnfree = true; allowUnsupportedSystem = true; };
      };
      profiles = (builtins.fromJSON (builtins.readFile ./model-profiles.json)).profiles;
      tools = with pkgs; [
        bash coreutils curl diffutils ethtool findutils gawk gitMinimal git-lfs
        gnugrep gnused gnutar gzip iperf3 iproute2 jq nix openssh pciutils
        podman procps python3 python3Packages.pip rdma-core util-linux uv
      ];
      shellFor = profileName: profile: pkgs.mkShell {
        name = "gb10sor-${profileName}";
        packages = tools;
        LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ];
        shellHook = ''
          echo ${lib.escapeShellArg "DGX Spark model: ${profile.title}"} >&2
          echo ${lib.escapeShellArg "Lane: ${profile.deployment.lane} (${toString profile.deployment.nodes} DGX Spark); status: ${profile.status}"} >&2
          echo "Nothing downloads or starts automatically." >&2
          echo "Run: ./scripts/launch-model.sh show|preflight|acceptance|qualify-and-serve|stop" >&2
          export GB10_MODEL_PROFILE=${lib.escapeShellArg profileName}
          export GB10_MODEL_PROFILE_REGISTRY=${./model-profiles.json}
          export GB10_MODEL_LAUNCHER=${lib.escapeShellArg profile.deployment.launcher}
          ${lib.optionalString (profileName == "minimax-music3") ''
            export GB10_SGLANG_OMNI_SOURCE=${sglang-omni}
          ''}
        '';
      };
      modelShells = lib.mapAttrs' (name: profile:
        lib.nameValuePair "model-${name}" (shellFor name profile)
      ) profiles;
      framework = pkgs.mkShell {
        name = "gb10sor-framework";
        packages = tools;
        shellHook = ''echo "GB10sor deployment tools ready. Nothing starts automatically." >&2'';
      };
      verify = pkgs.writeShellApplication {
        name = "gb10-verify";
        runtimeInputs = with pkgs; [ bash coreutils findutils jq ripgrep ];
        text = ''exec bash ./VERIFY.command'';
      };
    in {
      devShells.${system} = modelShells // { default = framework; framework = framework; };
      packages.${system} = { inherit verify; default = verify; };
      apps.${system} = {
        verify = { type = "app"; program = "${verify}/bin/gb10-verify"; };
        default = { type = "app"; program = "${verify}/bin/gb10-verify"; };
      };
      formatter.${system} = pkgs.nixfmt;
    };
}
