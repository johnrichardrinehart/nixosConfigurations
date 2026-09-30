{ config, ... }:
let
  secrets = ../../secrets/nebula-framework.yaml;
  nebulaSecret = key: {
    sopsFile = secrets;
    inherit key;
    group = "nebula-mycelium";
    mode = "0440";
    restartUnits = [ "nebula@mycelium.service" ];
  };
in
{
  sops.secrets = {
    nebula-ca = nebulaSecret "nebula-ca";
    nebula-cert = nebulaSecret "nebula-cert";
    nebula-key = nebulaSecret "nebula-key";
  };

  dev.johnrinehart.nebula.client = {
    enable = true;
    network = "mycelium";
    lighthouse = {
      address = "10.77.0.1";
      endpoint = "nebula-lighthouse.johnrinehart.dev:4242";
    };
    ca = config.sops.secrets.nebula-ca.path;
    cert = config.sops.secrets.nebula-cert.path;
    key = config.sops.secrets.nebula-key.path;
    # SSH to KeePass on 2222 and Android Termux peers on 8022.
    peerSshPorts = [
      "22"
      "2222"
      "8022"
    ];
  };

  # Reach VPN-only web services, including keepass.johnrinehart.dev.
  services.nebula.networks.mycelium.firewall.outbound = [
    {
      port = "443";
      proto = "tcp";
      group = "peer";
    }
  ];

  # Refuse retired mycelium certificates; see the file for why each is listed.
  services.nebula.networks.mycelium.settings.pki.blocklist = import ../mycelium-blocklist.nix;
}
