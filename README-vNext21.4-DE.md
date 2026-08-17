# Versionshinweise vNext21.4

## Behobener Fehler

In vNext21.3 konnte ein frischer QEMU-Guest-Agent-Aufruf korrekte IPv4- und MAC-Werte liefern, während ein nachfolgender Cachetreffer statt Zeichenfolgen ein PowerShell-Hashtable-Objekt zurückgab. Dadurch erschien `System.Collections.Hashtable` in den an Parallels RAS gelieferten Netzwerkdaten.

## Technische Korrektur

- Der VM-Netzwerkcache ist von `Copy-ObjectRecursive` getrennt.
- Cacheeinträge enthalten nur validierte primitive `string[]`-Arrays.
- IPv4-Adressen werden mit `System.Net.IPAddress.TryParse()` geprüft und kanonisiert.
- MAC-Adressen werden auf sechs Hex-Oktette geprüft und normalisiert.
- Cachetreffer werden auf Felder, Ablaufzeit, primitive Typen und gültige Formate geprüft.
- Beschädigte oder abgelaufene Einträge werden entfernt und sofort neu abgefragt.
- `provider/initialize` prüft einen echten Schreib-/Lese-Rundlauf sowie beschädigte und abgelaufene Einträge.
- Die Wartungs- und RASIMG-Korrekturen aus vNext21.2 und vNext21.3 bleiben erhalten.

## Aktivierung des Netzwerkcaches

```powershell
& '.\Install-Parallels-RAS-Proxmox-vNext21.4.ps1' `
    -EnableNetworkCache `
    -NetworkCacheSeconds 30 `
    -NetworkNegativeCacheSeconds 1
```

Ohne `-EnableNetworkCache` oder `-DisableNetworkCache` bewahrt der Installer die vorhandenen Werte. Beide Schalter gleichzeitig werden abgelehnt.

## Verifikation

```powershell
& '.\Test-Parallels-RAS-Proxmox-vNext21.4.ps1' -ExpectNetworkCacheEnabled
```

Im Providerlog sollten der Implementierungsstand und die effektive Cachekonfiguration erkennbar sein. In neuen vNext21.4-Logzeilen darf `System.Collections.Hashtable` nicht als IPv4- oder MAC-Wert erscheinen.

Bei vorübergehend aktiviertem `debug_logging=true` können erfolgreiche Cache-Speicherungen und Cachetreffer kontrolliert werden. Das Debug-Logging danach wieder deaktivieren.

## Laufzeitgrenze

Der endgültige Integrationstest erfordert den realen `RAS Provider Service`, die Proxmox-API und den QEMU Guest Agent. Der mitgelieferte Selbsttest deckt die Cachetypen und Fehlerfälle ab, ersetzt aber nicht den Test des vollständigen Bereitstellungsablaufs.
