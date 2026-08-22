# Foundry Core Repack

A PowerShell-based launcher that downloads and prepares a full TrinityCore server installation from a manifest file. 
Supports first-time install and update modes with automatic file versioning, Google Drive large file downloads, mirror fallback, and optional GenAI integration for Followship Bots.
The core is based on the public TrinityCore fork: https://github.com/stevebone/StefalWoW

## Features

- **One-click setup** — Downloads all server files (ZIPs, SQL, data files) from a remote manifest
- **Smart updates** — Compares local vs remote manifest versions; only downloads changed files
- **Google Drive support** — Handles large file downloads with confirmation page bypass and retry logic
- **Data mirror fallback** — If a primary download fails, automatically tries mirror URLs
- **Server data options** — Download data files (Maps, Vmaps, MMaps, DB2) automatically, extract from game client, or add manually
- **GenAI integration** — Optional local Llama CPP server setup for Followship Bots GenAI features
- **Server launcher menu** — Start BnetServer, WorldServer, or both; manage MySQL; start Llama CPP server
- **Self-updating** — The script checks for newer versions and updates itself automatically

## Requirements

- **Windows** with PowerShell 5.1+
- **World of Warcraft client** (if using the extraction option for data files)
- **NVIDIA RTX GPU with CUDA** (if using the local Llama CPP GenAI server)

## Quick Start

1. Download `FoundryCoreRepack.ps1` and `StartRepackNoAdminRights.bat` to a folder on your machine.
2. Run `StartRepackNoAdminRights.bat` — this bypasses PowerShell execution policy automatically.

   Alternatively, run in PowerShell:
   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process
   .\FoundryCoreRepack.ps1
   ```

3. Follow the on-screen prompts to complete setup.

## Files

| File | Description |
|------|-------------|
| `FoundryCoreRepack.ps1` | Main launcher script |
| `StartRepackNoAdminRights.bat` | Batch launcher that bypasses PowerShell execution policy |
| `repack.manifest` | Manifest file listing all downloadable files with versions (auto-generated on first run) |
| `repack.conf` | Persistent config file tracking setup state (auto-generated on first run) |

## Manifest Format

The manifest file uses INI-style sections with `identifier=[version, url]` entries:

```ini
[zip]
core=[1.0.0, https://example.com/core.zip]

[data]
maps=[1.0.0, https://drive.google.com/...]

[datamirror]
maps=[1.0.0, https://mirror.example.com/maps.zip]

[genai]
llamacpp=[1.0.0, https://drive.google.com/...]

[script]
main=[21082026-03, https://raw.githubusercontent.com/stevebone/FoundryCoreRepack/refs/heads/main/FoundryCoreRepack.ps1]
```

### Supported Sections

| Section | Description |
|---------|-------------|
| `zip` | ZIP files extracted to the script directory |
| `sql` | SQL files placed in the server's SQL directory |
| `other` | Miscellaneous files |
| `gdrive` | Google Drive files (with confirmation page handling) |
| `data` | Large data files (Maps, Vmaps, MMaps, DB2) from Google Drive |
| `datamirror` | Mirror URLs for data files (tried as fallback if primary download fails) |
| `genai` | GenAI server files for Llama CPP |
| `script` | Script self-update version and URL |

## Server Operations Menu

After setup, the launcher provides a menu:

1. **Start BnetServer** — Starts the bnetserver (requires MySQL)
2. **Start WorldServer** — Starts the worldserver (requires MySQL)
3. **Start Both Servers** — Starts both servers
4. **Start Llama CPP Server** — Starts the GenAI server (downloads files if missing)
5. **Server Operations** — Kill or start MySQL
6. **Exit**

## Discord

Join our Discord server for discussions, support, and updates:

[**https://discord.gg/fggW9fHJNd**](https://discord.gg/fggW9fHJNd)

## License

This project is released under the GPL-2.0 license. See [COPYING](COPYING) for details.
