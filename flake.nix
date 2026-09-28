{
  description = "JohnOS NixOS system configurations";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixosModules.url = "github:johnrichardrinehart/nixosModules";
    nixosModules.inputs.nixpkgs.follows = "nixpkgs";
    # Keep the source revision supported by the local terminal patch series.
    nixosModules.inputs.monstar.url = "github:rockorager/monstar/6cf9c9f3b5f297cfdc2798484b324187d6ce9dc5";

    nixpkgs.url = "github:johnrichardrinehart/nixpkgs?ref=rock-5c-nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      flake = true;
      inputs.nixpkgs.follows = "nixosModules/nixpkgs";
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixosModules/nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixosModules/nixpkgs";
    };

    rock5c-nixos = {
      url = "github:johnrichardrinehart/rock5c-nixos";
      inputs.nixpkgs.follows = "nixosModules/nixpkgs";
    };

    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixosModules/nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.flake-parts.flakeModules.partitions ];

      systems = [ "x86_64-linux" ];

      partitionedAttrs = {
        checks = "dev";
        devShells = "dev";
        formatter = "dev";
      };

      partitions.dev = {
        extraInputsFlake = ./dev;
        module =
          { inputs, ... }:
          {
            perSystem =
              { system, ... }:
              let
                pkgs = inputs.nixosModules.legacyPackages.${system};
                treefmtEval = inputs."treefmt-nix".lib.evalModule pkgs ./treefmt.nix;
                preCommitCheck = inputs."git-hooks".lib.${system}.run {
                  src = ./.;
                  hooks = {
                    treefmt-nix = {
                      enable = true;
                      name = "treefmt";
                      entry = "${treefmtEval.config.build.wrapper}/bin/treefmt --fail-on-change";
                      language = "system";
                      pass_filenames = false;
                    };
                  };
                };
              in
              {
                devShells = import ./dev-shells.nix {
                  inherit pkgs;
                  inherit preCommitCheck;
                  treefmtBin = treefmtEval.config.build.wrapper;
                };

                checks = {
                  pre-commit = preCommitCheck;
                  formatting = treefmtEval.config.build.check inputs.self;
                };

                formatter = treefmtEval.config.build.wrapper;
              };
          };
      };

      flake =
        let
          aarch64DarwinPkgs = import inputs.nixpkgs {
            system = "aarch64-darwin";
            overlays = [ (import ./packages/spice-quartz-overlay.nix) ];
          };
          bootstrapIso = aarch64DarwinPkgs.fetchurl {
            url = "https://releases.nixos.org/nixos/unstable/nixos-26.11pre1073009.ef34387ddd75/nixos-minimal-26.11pre1073009.ef34387ddd75-aarch64-linux.iso";
            hash = "sha256-0ObLuRcYGcsfF0SCV9i+NjZVImGvr1EFX8JH+4e5u7M=";
          };
          guestFlake =
            if inputs.self ? rev then
              "github:johnrichardrinehart/nixosConfigurations/${inputs.self.rev}"
            else
              "github:johnrichardrinehart/nixosConfigurations/main";
          installerBoot = aarch64DarwinPkgs.callPackage ./packages/nixos-installer-boot.nix {
            inherit bootstrapIso;
          };
          serialProvisioner = aarch64DarwinPkgs.callPackage ./packages/serial-provisioner.nix {
            inherit guestFlake;
          };
          vmArgs = {
            inherit
              bootstrapIso
              guestFlake
              installerBoot
              serialProvisioner
              ;
          };
          mbpAppleSiliconQemuVm = aarch64DarwinPkgs.callPackage ./packages/mbp-apple-silicon-qemu-vm.nix vmArgs;

          # The Mac host itself. Downstream flakes add their own modules with
          # `mkMbpHost { modules = [ ... ]; }` and get a matching provisioner
          # from `mkProvisionMac`.
          mbpHostModule = import ./darwin-configurations/mbp-host { inherit inputs; };
          mkMbpHost =
            {
              modules ? [ ],
            }:
            inputs.nix-darwin.lib.darwinSystem { modules = [ mbpHostModule ] ++ modules; };
          mkProvisionMac =
            darwinConfiguration:
            let
              provisioner = aarch64DarwinPkgs.callPackage ./packages/provision-mac.nix {
                inherit darwinConfiguration;
              };
            in
            {
              type = "app";
              program = "${provisioner}/bin/provision-mac";
            };
          mbpHost = mkMbpHost { };
        in
        {
          nixosConfigurations = (import ./nixos-configurations inputs) // {
            nebula-lighthouse = inputs.nixosModules.lib.nixosSystem {
              modules = [ ./nixos-configurations/nebula-lighthouse ];
              specialArgs = { inherit inputs; };
            };
            mbp-apple-silicon-bootstrap = inputs.nixosModules.lib.nixosSystem {
              modules = [ ./nixos-configurations/mbp-apple-silicon/bootstrap.nix ];
              specialArgs = { inherit inputs; };
            };
          };

          nixosModules = {
            mbp-intel-silicon = {
              imports = [
                inputs.nixosModules.nixosModules.default
                ./nixos-configurations/mbp-intel-silicon
              ];
              nixpkgs.overlays = [ inputs.nixosModules.overlays.default ];
            };

            mbp-apple-silicon =
              { lib, ... }:
              {
                imports = [
                  inputs.nixosModules.nixosModules.default
                  ./nixos-configurations/mbp-apple-silicon
                ];
                nixpkgs.overlays = [ inputs.nixosModules.overlays.default ];
                _module.args.inputs = lib.mkDefault inputs;
              };
          };
          darwinModules.mbp-host = mbpHostModule;
          darwinConfigurations.mbp-host = mbpHost;

          lib = { inherit mkMbpHost mkProvisionMac; };

          packages.aarch64-darwin = {
            mbp-apple-silicon-qemu-vm = mbpAppleSiliconQemuVm;
          };
          apps.aarch64-darwin = {
            mbp-apple-silicon-qemu-vm = {
              type = "app";
              program = "${mbpAppleSiliconQemuVm}/bin/mbp-apple-silicon-qemu-vm";
            };
            provision-mac = mkProvisionMac mbpHost;
          };
        };
    };
}
