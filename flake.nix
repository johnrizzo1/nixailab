{
  description = "Description for the project";

  inputs = {
    devenv-root = {
      url = "file+file:///dev/null";
      flake = false;
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    devenv.url = "github:cachix/devenv";
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

  outputs = inputs@{ flake-parts, devenv-root, devenv, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.devenv.flakeModule
        inputs.process-compose-flake.flakeModule
      ];
      systems = [ "x86_64-linux" "i686-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];

      perSystem = { config, self', inputs', pkgs, system, lib, ... }: {
        packages.default = self'.packages.nixailab;
        process-compose."nixailab" = pc:
          let
            rosettaPkgs =
              if pkgs.stdenv.isDarwin && pkgs.stdenv.isAarch64
              then pkgs.pkgsx86_64Darwin
              else pkgs;
            
            dbName = "sample";
            dataDirBase = "$HOME/.cache/.nixailab/llm";
          in
          {
            imports = [
              inputs.services-flake.processComposeModules.default
            ];

            services = {
              # Backend service to perform inference on LLM models
              ollama."ollama1" = {
                enable = true;

                # The models are usually huge, downloading them in every project
                # directory can lead to a lot of duplication. Change here to a
                # directory where the Ollama models can be stored and shared across
                # projects.
                dataDir = "${dataDirBase}/ollama1";

                # Define the models to download when our app starts
                #
                # You can also initialize this to empty list, and download the
                # models manually in the UI.
                #
                # Search for the models here: https://ollama.com/library
                models = [ "phi3" ];
              };

              # Get ChatGPT like UI, but open-source, with Open WebUI
              open-webui."open-webui1" = {
                enable = true;
                dataDir = "${dataDirBase}/open-webui";
                environment =
                  let
                    inherit (pc.config.services.ollama.ollama1) host port;
                  in
                  {
                    OLLAMA_API_BASE_URL = "http://${host}:${toString port}/api";
                    WEBUI_AUTH = "False";
                    # Not required since `WEBUI_AUTH=False`
                    WEBUI_SECRET_KEY = "";
                    # If `RAG_EMBEDDING_ENGINE != "ollama"` Open WebUI will use
                    # [sentence-transformers](https://pypi.org/project/sentence-transformers/) to fetch the embedding models,
                    # which would require `DEVICE_TYPE` to choose the device that performs the embedding.
                    # If we rely on ollama instead, we can make use of [already documented configuration to use GPU acceleration](https://community.flake.parts/services-flake/ollama#acceleration).
                    RAG_EMBEDDING_ENGINE = "ollama";
                    RAG_EMBEDDING_MODEL = "mxbai-embed-large:latest";
                    # RAG_EMBEDDING_MODEL_AUTO_UPDATE = "True";
                    # RAG_RERANKING_MODEL_AUTO_UPDATE = "True";
                    # DEVICE_TYPE = "cpu";
                  };
              };

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

              mongodb."mongodb1".enable = true;
              # services.kafka.enable = true;
            };

            settings.processes = {
              # Start the Open WebUI service after the Ollama service has finished initializing and loading the models
              open-webui1.depends_on.ollama1-models.condition = "process_completed_successfully";

              # Open the browser after the Open WebUI service has started
              open-browser = {
                command =
                  let
                    inherit (pc.config.services.open-webui.open-webui1) host port;
                    opener = if pkgs.stdenv.isDarwin then "open" else lib.getExe' pkgs.xdg-utils "xdg-open";
                    url = "http://${host}:${toString port}";
                  in
                  "${opener} ${url}";
                depends_on.open-webui1.condition = "process_healthy";
              };
              pgweb =
                let
                  pgcfg = pc.config.services.postgres.pg1;
                in
                {
                  environment.PGWEB_DATABASE_URL = pgcfg.connectionURI { inherit dbName; };
                  command = pkgs.pgweb;
                  depends_on."pg1".condition = "process_healthy";
                };

              test = {
                command = pkgs.writeShellApplication {
                  name = "pg1-test";
                  runtimeInputs = [ pc.config.services.postgres.pg1.package ];
                  text = ''
                    echo 'SELECT version();' | psql -h 127.0.0.1 ${dbName}
                  '';
                };
                depends_on."pg1".condition = "process_healthy";
              };
            };
          };

        devenv.shells.default = {
          devenv.root =
            let
              devenvRootFileContent = builtins.readFile devenv-root.outPath;
            in
            lib.mkIf (devenvRootFileContent != "") devenvRootFileContent;

          name = "nixailab";
          imports = [
            # This is just like the imports in devenv.nix.
            # See https://devenv.sh/guides/using-with-flake-parts/#import-a-devenv-module
            # ./devenv-foo.nix
          ];

          # https://devenv.sh/reference/options/
          packages = with pkgs; [ 
            config.packages.default 
            git # Code management
            jq # Query JSON
            yq # Query YAML
            wget
            curl
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
        };
      };

      flake = {
        # The usual flake attributes can be defined here, including system-
        # agnostic ones like nixosModule and system-enumerating ones, although
        # those are more easily expressed in perSystem.
      };
    };
}
