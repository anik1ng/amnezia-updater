# amnezia-updater

Update the `amneziawg-go` binary inside an Amnezia self-hosted Docker container
**without regenerating client configs**. The server key and all peers are kept, so
nobody needs a new config.

The official app only offers `Install`, which recreates the server with a new key
and breaks every existing config. This script updates just the binary instead.

## Usage

```bash
chmod +x update-awg.sh
sudo ./update-awg.sh --dry-run    # show the plan, change nothing
sudo ./update-awg.sh              # update to latest
sudo ./update-awg.sh 0.2.19       # or a specific tag
```

Idempotent: if the binary is already current, it exits without changes.

## How it works

Backs up `awg0.conf`, snapshots the running container, rebuilds it with the fresh
binary, restarts with the same flags, and verifies key/peers/NAT. The old container
is kept (autostart off) as a rollback, and the script auto-rolls-back if verification
fails.

## Requirements

- Root, `docker`, and a running Amnezia AWG container (found via
  `/opt/amnezia/awg/awg0.conf`).
- Fits the official app layout only — not custom installer/systemd setups.
- Tested on Ubuntu 24.04 + AWG 2.0.

## Notes

- Don't click "reinstall / Install protocol" in the app afterwards — it regenerates
  the server key. Adding/removing/sharing users still works fine.
- Keep the backup in `/root/awg-backups/`.

## Disclaimer

Use at your own risk. Verified on one server, not widely tested — run `--dry-run`
first. The backup-first + auto-rollback design keeps config-loss risk low, not zero.

MIT License.
