# Iconoclasts PortMaster files (TSPS)

This repository contains the PortMaster launcher and supporting runtime/configuration files for the Iconoclasts port. Commercial game data is intentionally not included.

## Install layout

Copy `Iconoclasts.sh` to `Roms/ports/` and the `iconoclasts/` directory to `Roms/ports/iconoclasts/`. Place a legally obtained GOG Linux installer named `iconoclasts_*.sh` in `Roms/ports/iconoclasts/gamedata/`; the launcher uses the included `extract.py` when the game executable is absent. Do not commit the installer or extracted game files.

The repository also omits device logs, save data, diagnostic SDL probes, and temporary backups. `settings.txt` is the clean default template, without the per-device diagnostic overrides used during troubleshooting.

## Contents

- `Iconoclasts.sh` — PortMaster launcher.
- `iconoclasts/box64/`, `iconoclasts/gl4es/` — bundled runtime components.
- `iconoclasts/libaa_preload.so` and `iconoclasts/modules/` — port helper and game-specific modules.
- Controller/configuration and extraction files, plus third-party license notices.

## Validation status

On the TSPS device, the installed copy reached the title/menu startup at 1280×720. This clean repository snapshot has not been independently reinstalled and tested; the device installation also contained local game data and troubleshooting artifacts that are excluded here. Gameplay, controls, and long-session stability are not claimed as verified by this repository snapshot.
