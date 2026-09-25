# secretspec 0.21, for its KeePass (`kdbx:`) provider (0.17+); the pinned
# nixpkgs ships 0.10. Same published crate and hashes as nixpkgs-unstable's
# package, but without its test suite: two Claude Code integration tests
# (tests/claude_integration.rs) fail in the Darwin build sandbox, which makes
# the unstable package unbuildable on this platform.
{
  lib,
  rustPlatform,
  fetchCrate,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "secretspec";
  version = "0.21.0";

  src = fetchCrate {
    inherit (finalAttrs) pname version;
    hash = "sha256-U7cSQbkOsmTfJynb1YizyZI2STpX7fz9N8JmJDHNr9w=";
  };

  cargoHash = "sha256-rPtPWBq7MK/e9J4IHRpXlFtSwFom14QIgWXBEwJc/bI=";

  doCheck = false;

  meta = {
    description = "Declarative secrets, every environment, any provider";
    homepage = "https://secretspec.dev";
    license = lib.licenses.asl20;
    mainProgram = "secretspec";
  };
})
