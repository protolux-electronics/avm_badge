{
  description = "AtomVM badge firmware development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";

    esp-dev = {
      url = "github:mirrexagon/nixpkgs-esp-dev/5287d6e1ca9e15ebd5113c41b9590c468e1e001b";
      inputs.nixpkgs.follows = "nixpkgs-stable";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs =
    { nixpkgs, nixpkgs-stable, flake-utils, esp-dev, ... }:
    flake-utils.lib.eachSystem
      [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ]
      (
        system:
        let
          pkgs = import nixpkgs { inherit system; };

          espPkgs = import nixpkgs-stable {
            inherit system;
            overlays = [ esp-dev.overlays.default ];
            config.permittedInsecurePackages = [
              "python3.13-ecdsa-0.19.1"
            ];
          };

          beam = pkgs.beam.packages.erlang_29;

          espIdf = espPkgs.esp-idf-xtensa.override {
            owner = "espressif";
            repo = "esp-idf";
            rev = "v5.5.5";
            sha256 = "sha256-/xVsusdmXFMLImfKryoB5ulR09AJefzoIUFmTAb3n/s=";
            python3 = espPkgs.python313;
            toolsToInclude = [
              "xtensa-esp-elf"
              "esp32ulp-elf"
              "openocd-esp32"
              "esp-rom-elfs"
            ];
            extraPythonPackages = pythonPackages: [
              pythonPackages.freetype-py
            ];
          };
        in
        {
          devShells.default = pkgs.mkShell {
            name = "avm-badge-dev";

            packages = [
              beam.elixir_1_20
              beam.erlang
              beam.rebar3
              espIdf
            ];

            IDF_PATH = "${espIdf}";
            IDF_TOOLS_PATH = "${espIdf}/tools";
            IDF_PYTHON_ENV_PATH = "${espIdf}/python-env";
            IDF_PYTHON_CHECK_CONSTRAINTS = "no";
            IDF_TARGET = "esp32s3";

            LANG = "C.UTF-8";
            LC_ALL = "C.UTF-8";

            shellHook = ''
              echo
              echo "AVM badge development shell"
              echo
              echo "Elixir: $(elixir --version | tail -n 1)"
              echo "Erlang: $(erl -version 2>&1)"
              echo "Rebar3: $(rebar3 --version)"
              echo "Python: $(python3 --version)"
              echo "ESP-IDF: $(idf.py --version)"
              echo "esptool: $(esptool.py version | grep esptool)"

              if command -v git >/dev/null 2>&1; then
                echo "Git: $(git --version)"
              else
                echo "Git: ❌ not installed"
              fi

              if command -v gh >/dev/null 2>&1; then
                echo "GitHub CLI: $(gh --version | head -n 1)"
              else
                echo "GitHub CLI: ❌ not installed"
              fi

              echo "ESP-IDF target: $IDF_TARGET"
              echo
            '';
          };
        }
      );
}
