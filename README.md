# cockpit-gpu

Cockpit plugin for monitoring NVIDIA GPU utilization, memory, temperature and processes.

## Install

Clone this repository, review the source, then run from the checkout:

```bash
sudo ./install.sh
```

The installer requires root and a non-root build user (`SUDO_USER`, or `--build-user USER` when running as root). It downloads Cockpit release 372, verifies its SHA-256, and builds the local plugin source as that user. Dependencies include curl, tar, Python 3, Node.js 22 or newer, npm, rsync, systemd and standard user-management tools. npm dependencies are installed without lifecycle scripts; their versions are not locked by Cockpit 372.

Files go to `/usr/local/share/cockpit/gpus`, the collector to `/usr/local/libexec/cockpit-gpu`, and usage data to `/var/lib/cockpit/gpus`. The service runs as the dedicated `cockpit-gpu` account. `nvidia-smi` and accessible NVIDIA devices are required for GPU data.

Options:

- `--build-user USER`: non-root user for downloading and building.
- `--dir PATH`: alternate root-owned plugin directory (all ancestors must be root-owned and not group/world writable; system and user directories are refused).
- `--ref COMMIT`: download plugin source at a full commit SHA instead of using this checkout; `--repo OWNER/REPO` selects its GitHub repository.
- `--restart-cockpit`: restart installed Cockpit services; otherwise refresh manually.
- `--uninstall`: remove the plugin, collector, unit, dedicated account and usage data. Pass the same `--dir` if customized.

Update by running the installer again. To uninstall:

```bash
sudo ./install.sh --uninstall
```

The former SSH deployment script is disabled; copy the checkout to the target and install there. The installer does not remove old user-level installations or other plugins. Remove a verified legacy `~/.local/share/cockpit/gpus` manually if present.

## License

MIT License.
