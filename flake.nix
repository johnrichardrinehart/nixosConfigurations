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

    # Last package set before the September 7 rebase; matches the running system.
    nixpkgs.url = "github:johnrichardrinehart/nixpkgs/3cbb62194f2f3fce1bce5c60d70b2a70d2a47ae2";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      flake = true;
      inputs.nixpkgs.follows = "nixosModules/nixpkgs";
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
          aarch64DarwinPkgs = import inputs.nixpkgs { system = "aarch64-darwin"; };
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
          mbpAppleSiliconVm = aarch64DarwinPkgs.callPackage ./packages/mbp-apple-silicon-vm.nix vmArgs;
        in
        {
          nixosConfigurations = (import ./nixos-configurations inputs) // {
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

          packages.aarch64-darwin.mbp-apple-silicon-vm = mbpAppleSiliconVm;
          apps.aarch64-darwin.mbp-apple-silicon-vm = {
            type = "app";
            program = "${mbpAppleSiliconVm}/bin/mbp-apple-silicon-vm";
          };
        };
    };
}
