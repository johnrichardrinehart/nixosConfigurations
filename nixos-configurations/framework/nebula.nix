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

  dev.johnrinehart.mycelium = {
    enable = true;
    ca = config.sops.secrets.nebula-ca.path;
    cert = config.sops.secrets.nebula-cert.path;
    key = config.sops.secrets.nebula-key.path;
    # SSH to KeePass on 2222 and Android Termux peers on 8022.
    firewall.peerSshPorts = [
      "22"
      "2222"
      "8022"
    ];
    firewall.allowPeerHTTPS = true;
  };

}
