{
  writeShellApplication,
  bash,
  coreutils,
  findutils,
  gawk,
  jq,
  nix,
  openssh,
  shellcheck-minimal,
  tailscale,
  util-linux,
}:

writeShellApplication {
  name = "tailscale-nix-builders";
  runtimeInputs = [
    coreutils
    findutils
    gawk
    jq
    nix
    openssh
    tailscale
    util-linux
  ];
  text = builtins.readFile ./tailscale-nix-builders.sh;
  checkPhase = ''
    runHook preCheck
    ${bash}/bin/bash -n "$target"
    ${shellcheck-minimal}/bin/shellcheck \
      "$target" \
      ${./tailscale-nix-builders-test.sh}
    TAILSCALE_NIX_BUILDERS_PROGRAM="$target" \
      ${bash}/bin/bash ${./tailscale-nix-builders-test.sh}
    runHook postCheck
  '';
}
