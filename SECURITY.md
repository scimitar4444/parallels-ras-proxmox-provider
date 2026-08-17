# Sicherheitshinweise

## Geheimnisse und Konfigurationsdaten

Keine Proxmox-API-Tokens, Passwörter, produktiven Hostnamen, IP-Adresspläne, Logs, State-Dateien oder Installer-Backups committen. Die Datei `Proxmox-RAS-Provider-vNext21.4.json` enthält ausschließlich Platzhalter und muss lokal an die Zielumgebung angepasst werden.

Die Werte `host`, `username`, `token_name` und `token_secret` werden von Parallels RAS zur Laufzeit übergeben. Der Provider maskiert bekannte Geheimnisfelder beim Logging; Logs sollten dennoch als vertraulich behandelt werden.

## Betrieb

- Dediziertes API-Token mit minimal erforderlichen Proxmox-Rechten verwenden.
- TLS-Zertifikatsprüfung nach Möglichkeit erzwingen.
- Änderungen zuerst in einer isolierten Testfarm prüfen.
- Vor Updates das vom Installer erstellte Backup kontrollieren.
- Provider-State-Dateien und Sicherungsgenerationen regelmäßig sichern.
- `debug_logging` nur für eine begrenzte Diagnosezeit aktivieren.

## Sicherheitsmeldungen

Schwachstellen nicht zusammen mit Tokens, produktiven Logs oder internen Netzdaten in einem öffentlichen Issue melden. Stattdessen die private Sicherheitsmeldung des Repositorys oder einen zuvor vereinbarten vertraulichen Kanal verwenden.
