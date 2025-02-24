{
  inputs = {
    # nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    systems.url = "github:nix-systems/default";
    # devenv.url = "github:cachix/devenv";
    # devenv.inputs.nixpkgs.follows = "nixpkgs";

    devenv-root = {
      url = "file+file:///dev/null";
      flake = false;
    };
    # flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
    nix2container.url = "github:nlewo/nix2container";
    nix2container.inputs.nixpkgs.follows = "nixpkgs";
    mk-shell-bin.url = "github:rrbutani/nix-mk-shell-bin";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    services-flake.url = "github:juspay/services-flake";
    northwind.url = "github:pthom/northwind_psql";
    northwind.flake = false;
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = { self, nixpkgs, devenv, systems, ... } @ inputs:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);
    in
    {
      packages = forEachSystem (system: (
        let
          devenv-up = self.devShells.${system}.default.config.procfileScript;
          devenv-test = self.devShells.${system}.default.config.test;
          pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
            # config.cudaSupport = nixpkgs.lib.isLinux;
          };
          rosettaPkgs =
            if pkgs.stdenv.isDarwin && pkgs.stdenv.isAarch64
            then pkgs.pkgsx86_64Darwin
            else pkgs;
          dbName = "sample";
          dataDirBase = "$HOME/.cache/.nixailab/llm";
          process-compose = (import inputs.process-compose-flake.lib { inherit pkgs; }).makeProcessCompose;
        in
        {
          process-compose.nixailab = {
            modules = [
              inputs.services-flake.processComposeModules.default
              {
                services = {
                  postgres."pg1" = {
                    enable = true;
                    initialDatabases = [
                      {
                        name = dbName;
                        schemas = [ "${inputs.northwind}/northwind.sql" ];
                      }
                    ];
                    listen_addresses = "127.0.0.1";
                    port = 5432;
                    extensions = extensions: [
                      extensions.postgis
                      # extensions.timescaledb
                      extensions.pgvector
                    ];
                    # settings.shared_preload_libraries = "timescaledb";
                    # initialScript = "CREATE EXTENSION IF NOT EXISTS timescaledb; CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS pgvector;";
                  };
                };

                # settings.processes = {
                #   pgweb =
                #     let
                #       pgcfg = pkgs.config.services.postgres.pg1;
                #     in
                #     {
                #       environment.PGWEB_DATABASE_URL = pgcfg.connectionURI { inherit dbName; };
                #       command = pkgs.pgweb;
                #       depends_on."pg1".condition = "process_healthy";
                #     };

                #   test = {
                #     command = pkgs.writeShellApplication {
                #       name = "pg1-test";
                #       runtimeInputs = [ pkgs.config.services.postgres.pg1.package ];
                #       text = ''
                #         echo 'SELECT version();' | psql -h 127.0.0.1 ${dbName}
                #       '';
                #     };
                #     depends_on."pg1".condition = "process_healthy";
                #   };
                # };
              }
            ];
          };

          devShells = forEachSystem (system:
            {
              default = devenv.lib.mkShell {
                inherit inputs pkgs;
                modules = [{
                  # https://devenv.sh/reference/options/
                  # packages = [ pkgs.hello ];
                  packages = with pkgs; [
                    # config.packages.default 
                    git # Code management
                    jq # Query JSON
                    yq # Query YAML
                    wget
                    curl
                    # (python3.withPackages (pkgs-python: with pkgs-python; [
                    #   python-dotenv
                    #   torch
                    # ]))
                  ] ++ lib.optionals pkgs.stdenv.isDarwin [
                    darwin.apple_sdk.frameworks.CoreFoundation
                    darwin.apple_sdk.frameworks.Security
                    darwin.apple_sdk.frameworks.SystemConfiguration
                  ] ++ lib.optionals pkgs.stdenv.isLinux [
                    rstudio
                  ];

                  # R setup
                  languages.r.enable = true;

                  # Python setup
                  languages.python.enable = true;
                  languages.python.venv.enable = true;
                  languages.python.venv.requirements = ''
                    python-dotenv
                    numpy
                    torch
                  '';
                  languages.python.uv.enable = true;
                  languages.python.poetry.enable = true;

                  difftastic.enable = true;
                  dotenv.enable = true;

                  cachix.enable = true;
                  cachix.pull = [ "pre-commit-hooks" ];

                  enterShell = ''
                    echo "Welcome to the nix ai/ml/ds toolkit"
                    echo '-----------------------------------'
                    echo -n 'Git:    '; git --version
                    echo -n 'Python: '; python --version
                    echo -n 'CUDA:   '; python -c "import torch; print(torch.cuda.is_available());"
                    echo -n 'MPS:    '; python -c "import torch; print(torch.backends.mps.is_available());"
                    echo ""
                  '';
                }];
              };
            });
        }
      ));
    };
}
