# Changelog

## 0.9.1

- README: "Common choices" section covering a separate relay port when a home
  WireGuard server is forwarded, and NAT vs. no-NAT on OPNsense with the
  matching `WG_PEER_ALLOWED_IPS`.
- README: OPNsense section links to `docs/opnsense.md` (step-by-step guide).
- `config.env`: comments for `WG_PORT` and `WG_PEER_ALLOWED_IPS` describe both
  setups.

## 0.9.0

- First release: installer (new tunnel, migration, reconfigure), export/import,
  status, diagnostics, uninstall.
