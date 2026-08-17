# Parallels RAS Custom Provider for Proxmox VE

[Deutsch](README.md) | English

PowerShell-based custom provider for integrating Proxmox VE with Parallels RAS. Release `vNext21.4` fixes a VM network-cache type-corruption bug and includes the previously developed RASIMG versioning, VM placement, maintenance-state, and resilient Proxmox API functionality.

> **Important:** This is a customized and unofficial provider variant. Validate it in a test environment before production use. API credentials belong exclusively in the Parallels RAS connection settings and must never be committed to this repository.

## Features

- Parallels RAS JSON-RPC provider for Proxmox VE
- RASIMG versioning based on local ZFS linked clones
- separate VMID pools for RASIMGs and session hosts
- least-loaded or round-robin placement
- node, storage, health, and capacity checks
- persistent task, delete, and version states with rolling backups
- bounded API timeouts and safe retries for GET requests only
- typed IPv4/MAC network cache with initialization self-tests
- installer with backup, validation, and automatic rollback
- dedicated post-install verification and rollback scripts

## Repository contents

| File | Purpose |
| --- | --- |
| `Parallels-RAS-CPF-Proxmox-Versioning-vNext21.4.ps1` | Provider implementation |
| `Proxmox-RAS-Provider-vNext21.4.json` | Documented example configuration; customize before use |
| `Install-Parallels-RAS-Proxmox-vNext21.4.ps1` | Installation or update with backup and smoke tests |
| `Test-Parallels-RAS-Proxmox-vNext21.4.ps1` | Read-only post-install verification |
| `Rollback-Parallels-RAS-Proxmox-vNext21.4.ps1` | Restores an installer backup |
| `Parallels-RAS-CPF-Proxmox-vNext21.3-to-vNext21.4.diff` | Technical changes from vNext21.3 |
| `README-vNext21.4-DE.md` | German release notes and defect description |

## Requirements

- Parallels RAS with a custom provider configured
- Proxmox VE API token with the required VM and storage permissions
- Windows host running the `RAS Provider Service`
- elevated PowerShell; PowerShell 7 is recommended
- QEMU Guest Agent installed and running in the gold image
- local Proxmox storage available under the same name on every enabled compute node

## Configuration

Customize `Proxmox-RAS-Provider-vNext21.4.json` before installation. At a minimum, review:

- `storage`
- `preferred_ipv4_cidrs`
- `gold_vmid`
- `rasimg_vmid_pool_start` and `rasimg_vmid_pool_end`
- `session_vmid_pool_start` and `session_vmid_pool_end`
- `compute_nodes`
- minimum free-storage thresholds

The bundled node names `pve01` through `pve07` and the reserved documentation network `192.0.2.0/24` are placeholders. Ensure that the configured VMID ranges do not overlap existing VMs or other automation.

The Proxmox connection parameters (`host`, `username`, `token_name`, and `token_secret`) are supplied by Parallels RAS when it establishes the provider connection. They are not stored in the provider configuration file.

## Installation

Copy all versioned files into the same directory on the RAS provider host, for example:

```text
C:\CFP Scripts\Parallels-RAS-Proxmox-vNext21.4
```

Open an elevated PowerShell session and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force

& 'C:\CFP Scripts\Parallels-RAS-Proxmox-vNext21.4\Install-Parallels-RAS-Proxmox-vNext21.4.ps1' `
    -EnableNetworkCache `
    -NetworkCacheSeconds 30 `
    -NetworkNegativeCacheSeconds 1
```

Without `-EnableNetworkCache` or `-DisableNetworkCache`, the installer preserves the existing cache values. `-ReplaceConfiguration` replaces the current provider configuration and should only be used after explicitly reviewing the example configuration.

The installer:

1. validates the PowerShell source and JSON configuration,
2. stops the `RAS Provider Service`,
3. backs up the provider, configuration, and state files,
4. installs the provider as `C:\CFP Scripts\Parallels-RAS-CPF-Proxmox-Advanced.ps1`,
5. runs `provider/initialize`, including the regression self-tests,
6. starts and verifies the service, and
7. automatically rolls back if a step fails.

## Verification

```powershell
& 'C:\CFP Scripts\Parallels-RAS-Proxmox-vNext21.4\Test-Parallels-RAS-Proxmox-vNext21.4.ps1' `
    -ExpectNetworkCacheEnabled
```

The expected checks cover the implementation marker, PowerShell parser, configuration, typed network cache, `provider/initialize`, service status, and recent provider log.

A complete integration test requires a real Parallels RAS and Proxmox environment. Static checks or local parser validation do not replace this runtime test.

## Rollback

```powershell
& 'C:\CFP Scripts\Parallels-RAS-Proxmox-vNext21.4\Rollback-Parallels-RAS-Proxmox-vNext21.4.ps1' `
    -BackupDirectory 'C:\CFP Scripts\Backup-vNext21.4-YYYYMMDD-HHMMSS'
```

If `-BackupDirectory` is omitted, the rollback script uses the newest matching backup below the target directory.

## Security

- Keep API tokens, passwords, production hostnames, IP plans, logs, and state files out of the repository.
- Use a dedicated Proxmox API token with the minimum required privileges.
- Enforce TLS certificate validation whenever possible.
- Enable `debug_logging` only for a limited diagnostic period; logs may contain infrastructure and operational details.
- Include provider state files and their backup generations in the regular server backup.

See [SECURITY.md](SECURITY.md) for additional operational guidance.

## What changed in vNext21.4

The VM network cache now stores validated primitive `string[]` arrays only. Corrupt, expired, or complex entries are discarded and immediately refreshed through the QEMU Guest Agent. See [README-vNext21.4-DE.md](README-vNext21.4-DE.md) for the detailed release notes.

## Origin and licensing

The script header identifies the original base as the “Parallels RAS Custom Provider Sample Script for Proxmox VE” and names Parallels as its author. The supplied package did not include a license file. This repository therefore does not grant an additional license; confirm the required rights before redistribution or commercial use. See [NOTICE.md](NOTICE.md).
