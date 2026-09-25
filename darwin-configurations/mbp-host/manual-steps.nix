# Steps macOS only accepts from the user (permission and extension approvals,
# secrets), declared next to the feature that needs them. `provision-mac`
# runs every check after activation, lists the ones still pending, runs their
# actions and opens the first one's System Settings pane. A step whose check
# passes is not mentioned, so a machine that is fully set up stays quiet.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.dev.johnrinehart.provisionMac.summary = mkOption {
    type = types.attrsOf types.str;
    default = { };
    example = {
      shotedit = "shotedit-1a2b3c4d";
    };
    description = "Lines `provision-mac` prints after every activation, as `name: value`.";
  };

  options.dev.johnrinehart.provisionMac.manualSteps = mkOption {
    default = { };
    description = "Imperative steps to surface after `provision-mac` activates.";
    type = types.attrsOf (
      types.submodule {
        options = {
          check = mkOption {
            type = types.lines;
            description = "Shell run as the primary user; exit status 0 means the step is done.";
          };
          instructions = mkOption {
            type = types.lines;
            description = "What to do, shown while the step is pending.";
          };
          action = mkOption {
            type = types.nullOr types.lines;
            default = null;
            description = "Shell run while the step is pending, e.g. launching the app that asks for it.";
          };
          settingsPane = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
            description = "System Settings URL where the step is done.";
          };
        };
      }
    );
  };
}
