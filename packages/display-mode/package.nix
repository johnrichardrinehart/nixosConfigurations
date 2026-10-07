# Built with nixpkgs' Swift toolchain rather than Xcode's, like shotedit.
{
  runCommandCC,
  swift,
}:
runCommandCC "display-mode"
  {
    nativeBuildInputs = [ swift ];
    meta.mainProgram = "display-mode";
  }
  ''
    mkdir -p "$out/bin"
    swiftc -O ${./display-mode.swift} -o "$out/bin/display-mode"
  ''
