# Certificate fingerprints every mycelium host refuses (Nebula `pki.blocklist`).
# Nebula has no revocation service: a certificate stays valid until it expires
# unless each host blocklists it. Keep entries until the certificate's notAfter
# has passed; both below expire with the CA on 2027-09-25.
[
  # `framie` (10.77.0.2), replaced by `framework` on 2026-09-27 when hosts moved
  # to the `peer` group. Its private key still exists, encrypted, in commit
  # 78de93aa4c8d of secrets/nebula-framework.yaml, which older clones retain.
  "23ae11b31009bebd6e3d5be6d4c73c8e56a2156da91d33e763b8cf0f4d5b45cf"
  # `nebula-lighthouse` (10.77.0.1), replaced by `lighthouse` on 2026-09-27.
  # Its private key was shredded on the lighthouse; blocklisted in case a copy
  # survives elsewhere.
  "b7f47c14215f37116e4e674fe3a9014afc756e53e4b62edf3c835f9177754740"
]
