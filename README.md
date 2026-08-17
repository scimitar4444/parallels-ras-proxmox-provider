# Parallels RAS Custom Provider für Proxmox VE

Deutsch | [English](README.en.md)

PowerShell-basierter Custom Provider zur Anbindung von Proxmox VE an Parallels RAS. Der Stand `vNext21.4` behebt eine Typkorruption im VM-Netzwerkcache und enthält die zuvor entwickelten Funktionen für RASIMG-Versionierung, VM-Platzierung, Wartungszustände und robuste Proxmox-API-Aufrufe.

> **Wichtig:** Dies ist eine angepasste, nicht offiziell unterstützte Provider-Variante. Vor dem Produktiveinsatz in einer Testumgebung prüfen. API-Zugangsdaten gehören ausschließlich in die Parallels-RAS-Verbindungseinstellungen und niemals in dieses Repository.

## Funktionsumfang

- Parallels-RAS-JSON-RPC-Provider für Proxmox VE
- RASIMG-Versionierung mit lokalen ZFS-Linked-Clones
- getrennte VMID-Pools für RASIMGs und Session Hosts
- Least-loaded- oder Round-robin-Platzierung
- Node-, Storage- und Kapazitätsprüfungen
- persistente Task-, Delete- und Versionszustände mit Sicherungsgenerationen
- begrenzte API-Timeouts und sichere Wiederholungen ausschließlich für GET-Anfragen
- typisierter IPv4-/MAC-Netzwerkcache mit Selbsttests
- Installer mit Backup, Validierung und automatischem Rollback
- separates Prüf- und Rollback-Skript

## Repository-Inhalt

| Datei | Zweck |
| --- | --- |
| `Parallels-RAS-CPF-Proxmox-Versioning-vNext21.4.ps1` | Provider-Implementierung |
| `Proxmox-RAS-Provider-vNext21.4.json` | dokumentierte Beispielkonfiguration; vor Nutzung anpassen |
| `Install-Parallels-RAS-Proxmox-vNext21.4.ps1` | Installation bzw. Update mit Sicherung und Smoke-Tests |
| `Test-Parallels-RAS-Proxmox-vNext21.4.ps1` | schreibgeschützte Prüfung nach der Installation |
| `Rollback-Parallels-RAS-Proxmox-vNext21.4.ps1` | Wiederherstellung eines Installer-Backups |
| `Parallels-RAS-CPF-Proxmox-vNext21.3-to-vNext21.4.diff` | technische Änderung gegenüber vNext21.3 |
| `README-vNext21.4-DE.md` | Versionshinweise und Fehlerbeschreibung |

## Voraussetzungen

- Parallels RAS mit aktiviertem Custom Provider
- Proxmox VE mit API-Token und den erforderlichen VM-/Storage-Rechten
- Windows-Host für den `RAS Provider Service`
- administrative PowerShell; PowerShell 7 wird empfohlen
- QEMU Guest Agent im Goldimage
- lokaler Proxmox-Storage mit identischem Namen auf allen aktivierten Compute-Nodes

## Konfiguration

Vor der Installation `Proxmox-RAS-Provider-vNext21.4.json` an die eigene Umgebung anpassen. Mindestens prüfen:

- `storage`
- `preferred_ipv4_cidrs`
- `gold_vmid`
- `rasimg_vmid_pool_start` und `rasimg_vmid_pool_end`
- `session_vmid_pool_start` und `session_vmid_pool_end`
- `compute_nodes`
- freie Storage-Schwellwerte

Die mitgelieferten Namen `pve01` bis `pve07` und das reservierte Dokumentationsnetz `192.0.2.0/24` sind Platzhalter. Die VMID-Bereiche dürfen keine vorhandenen VMs oder andere Automatisierungen überschneiden.

Die Proxmox-Verbindungsdaten (`host`, `username`, `token_name`, `token_secret`) werden von Parallels RAS beim Verbindungsaufbau übergeben. Sie werden nicht in der Provider-Konfigurationsdatei gespeichert.

## Installation

Alle versionierten Dateien in denselben Ordner auf dem RAS-Provider-Host kopieren, beispielsweise nach:

```text
C:\CFP Scripts\Parallels-RAS-Proxmox-vNext21.4
```

Danach eine administrative PowerShell öffnen:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force

& 'C:\CFP Scripts\Parallels-RAS-Proxmox-vNext21.4\Install-Parallels-RAS-Proxmox-vNext21.4.ps1' `
    -EnableNetworkCache `
    -NetworkCacheSeconds 30 `
    -NetworkNegativeCacheSeconds 1
```

Ohne `-EnableNetworkCache` oder `-DisableNetworkCache` bleiben vorhandene Cachewerte erhalten. `-ReplaceConfiguration` ersetzt die bestehende Providerkonfiguration und sollte nur nach ausdrücklicher Prüfung verwendet werden.

Der Installer:

1. validiert Skript und JSON-Konfiguration,
2. stoppt den `RAS Provider Service`,
3. sichert Provider-, Konfigurations- und State-Dateien,
4. installiert den Provider als `C:\CFP Scripts\Parallels-RAS-CPF-Proxmox-Advanced.ps1`,
5. führt `provider/initialize` einschließlich Regressionstests aus,
6. startet und prüft den Dienst,
7. rollt bei einem Fehler automatisch zurück.

## Prüfung

```powershell
& 'C:\CFP Scripts\Parallels-RAS-Proxmox-vNext21.4\Test-Parallels-RAS-Proxmox-vNext21.4.ps1' `
    -ExpectNetworkCacheEnabled
```

Erwartet werden erfolgreiche Prüfungen für Implementierung, PowerShell-Parser, Konfiguration, Netzwerkcache, `provider/initialize`, Dienststatus und aktuelles Providerlog.

Der vollständige Integrationstest benötigt eine echte Parallels-RAS-/Proxmox-Umgebung. Ein statischer oder lokaler Parser-Test ersetzt diesen Laufzeittest nicht.

## Rollback

```powershell
& 'C:\CFP Scripts\Parallels-RAS-Proxmox-vNext21.4\Rollback-Parallels-RAS-Proxmox-vNext21.4.ps1' `
    -BackupDirectory 'C:\CFP Scripts\Backup-vNext21.4-YYYYMMDD-HHMMSS'
```

Ohne `-BackupDirectory` verwendet das Skript das neueste passende Backup im Zielordner.

## Sicherheit

- Repository und Logs vor Tokens, Passwörtern und internen Infrastrukturdetails schützen.
- Für Proxmox ein dediziertes API-Token mit minimal erforderlichen Rechten verwenden.
- TLS-Prüfung aktivieren, sobald ein vertrauenswürdiges Proxmox-Zertifikat eingesetzt wird.
- `debug_logging` nur vorübergehend aktivieren; Logs können Infrastruktur- und Betriebsdaten enthalten.
- State-Dateien und Backups in die reguläre Serversicherung aufnehmen.

Weitere Hinweise stehen in [SECURITY.md](SECURITY.md).

## Version vNext21.4

Der Netzwerkcache speichert ausschließlich validierte primitive `string[]`-Arrays. Beschädigte, abgelaufene oder komplexe Einträge werden verworfen und sofort über den QEMU Guest Agent erneuert. Details: [README-vNext21.4-DE.md](README-vNext21.4-DE.md).

## Herkunft und Lizenz

Der Skriptkopf bezeichnet die ursprüngliche Basis als „Parallels RAS Custom Provider Sample Script for Proxmox VE“ und nennt Parallels als Autor. Im bereitgestellten Paket war keine Lizenzdatei enthalten. Dieses Repository erteilt daher keine zusätzliche Lizenz; vor öffentlicher Weitergabe oder kommerzieller Nutzung müssen die erforderlichen Rechte geklärt werden. Siehe [NOTICE.md](NOTICE.md).
