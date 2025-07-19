# Proxmox LXC Container Creator

Interaktives Bash-Skript zur automatisierten und sicheren Erstellung von LXC-Containern auf einem Proxmox VE-Host. Unterstützt Mehrsprachigkeit (Deutsch/Englisch), SSH-Key-Integration, automatisches Systemupdate, regionale Einstellungen und einfache Bedienung über TUI (whiptail).

## Eigenschaften

- **Mehrsprachiges Benutzer-Interface** (Deutsch und Englisch)
- **Interaktive Menüführung** via whiptail
- **Sichere Validierung** sämtlicher Benutzereingaben
- **Automatische CT-ID-Vergabe**
- **SSH-Key-Integration** mittels Kommentar-Suche im authorized_keys
- **Automatische Konfiguration** von Lokalisierung (de_DE.UTF-8 als Standard) und Zeitzone (Europe/Berlin)
- **APT-Systemupdate** des frisch erstellten Containers
- **Robustes Logging** aller Vorgänge in Datei
- Unterstützt **dry-run** (Vorschau ohne Erstellung)

## Voraussetzungen

- Proxmox VE mit funktionsfähigen LXC-Befehlen (`pct`)
- Bash ≥ 4.2
- whiptail
- Container-Templates liegen im gewünschten Verzeichnis (Standard: `/mnt/FP1000GB/template/cache`)
- SSH-Key für Integration im Proxmox-root-Account (`/root/.ssh/authorized_keys`)

## Installation

1. **Repository auf den Proxmox-Host klonen**

   ```bash
   git clone https://github.com//.git /opt/scripts/proxmox
   cd /opt/scripts/proxmox
   ```

2. **Skripte ausführbar machen**  
   ```bash
   chmod +x create_ct_install.sh
   ```

3. **Prüfen, ob alle Voraussetzungen installiert sind**  
   ```bash
   apt install whiptail
   ```

## Nutzung

### Interaktive Erstellung eines Containers

```bash
sudo ./create_ct_install.sh
```

Das Skript führt dich durch alle notwendigen Schritte per Dialog. Du findest das Logfile unter `/opt/scripts/proxmox/lxc_create_YYYYMMDD_HHMMSS.log`.

### Vorschau (Dry-Run, es wird kein Container erstellt)

```bash
sudo ./create_ct_install.sh --dry-run
```

## Feature-Highlights

- **Sprachauswahl** beim Start
- **Auswahl und Validierung** von Hostname, Passwort, Ressourcen
- **Automatische Auswahl freier Container-ID**
- **Auswahl eines Templates aus Dateiliste**
- **Erkennung des Betriebssystems per Dateiname**
- **SSH-Key durch Kommentar-Auswahl im authorized_keys**
- **Automatisierte Einrichtung von Locales und Zeitzone**
- **Direktes Sicherheitsupdate des Containers nach Erzeugung**

## Ordnerstruktur

```
/opt/scripts/proxmox/
 ├─ create_ct_install.sh
 ├─ translation.func
 └─ [weitere Skripte/Module]
```

## Hinweise & Empfohlene Praxis

- Füge `.log`-Dateien zur `.gitignore` hinzu, um Logfiles nicht ins Repo zu committen.
- Lokale Anpassungen stets mit eigenem Commit einchecken.
- Nach Änderungen an der Vorlage immer per `git pull` aktualisieren!
- Optimale Nutzung im Root-Kontext (`sudo ...`).

## Anpassung & Erweiterung

- Für Batch-Erstellung oder CLI-Automatisierung ist eine spätere Erweiterung vorgesehen.
- Das Skript ist als Basis gedacht und kann nach eigenen Bedürfnissen modular angepasst werden.

## Lizenz

Dieses Tool kann nach Belieben angepasst und frei verwendet werden, sofern Hinweise zum Ursprung erhalten bleiben. Für produktive Umgebungen stets an lokale Gegebenheiten und Sicherheitsanforderungen anpassen.

**Fragen, Beiträge oder Vorschläge?**
→ Bitte Issues oder Pull Requests direkt im GitHub-Repo einreichen.