{ config, ... }:
let
  secrets = ../../secrets/nebula-framework.yaml;
  nebulaSecret = key: {
    sopsFile = secrets;
    inherit key;
    group = "nebula-nebula";
    mode = "0440";
    restartUnits = [ "nebula@nebula.service" ];
  };
in
{
  sops.secrets = {
    nebula-ca = nebulaSecret "nebula-ca";
    nebula-cert = nebulaSecret "nebula-cert";
    nebula-key = nebulaSecret "nebula-key";
  };

  services.nebula.networks.nebula = {
    ca = config.sops.secrets.nebula-ca.path;
    cert = config.sops.secrets.nebula-cert.path;
    key = config.sops.secrets.nebula-key.path;
    lighthouses = [ "10.77.0.1" ];
    staticHostMap."10.77.0.1" = [ "nebula-lighthouse.johnrinehart.dev:4242" ];
    listen.port = 0;
    # Nebula denies outbound traffic unless a rule permits it.
    firewall.outbound = [
      {
        port = "22";
        proto = "tcp";
        cidr = "10.77.0.1/32";
      }
    ];
    firewall.inbound = [
      {
        port = "any";
        proto = "icmp";
        cidr = "10.77.0.0/24";
      }
      {
        port = "22";
        proto = "tcp";
        cidr = "10.77.0.0/24";
      }
    ];
  };
}
