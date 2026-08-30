# StylePanda Main

Zentrale Website für StylePanda-Projekte und -Dienste.

## Domain

Die kanonische Adresse ist [https://stylepanda.me/](https://stylepanda.me/).

## Architektur

Die technische Basis ist eine statische Website aus HTML5 und CSS. Sie benötigt kein Framework, Backend, JavaScript, Build-System oder eine Datenbank.

## Struktur

```text
.
├── index.html
├── 404.html
├── robots.txt
├── sitemap.xml
├── assets/
│   ├── css/main.css
│   └── icons/README.md
└── scripts/
    └── deploy.sh
```

Der Icon-Pfad ist für ein später freigegebenes StylePanda-Favicon reserviert. Solange kein echtes Marken-Asset vorliegt, bindet die Website kein Favicon und kein Social-Preview-Bild ein.

## Lokale Vorschau

Die Dateien müssen über einen lokalen statischen HTTP-Server ausgeliefert werden, damit root-relative Pfade wie in Production funktionieren. Beispiel mit einer vorhandenen Python-Installation:

```powershell
python -m http.server 8000
```

Danach ist die Startseite unter `http://localhost:8000/` erreichbar. Es müssen keine Abhängigkeiten installiert werden.

## Deployment

GitHub bleibt die Source of Truth:

```text
PC/Codex -> Git Commit -> GitHub main -> Production Server -> deploy.sh
```

Der manuell auf dem Server gestartete Ablauf liegt versioniert unter `scripts/deploy.sh`. Das Script prüft den dedizierten Checkout, aktualisiert ihn exakt auf `origin/main`, exportiert ausschließlich die öffentlichen Website-Dateien per `git archive`, validiert einen neuen Release, schaltet den `current`-Symlink atomar um und führt Production-Smoke-Checks aus.

Serverstruktur:

```text
/var/www/stylepanda-app/
├── deploy.sh
├── deploy.lock
├── repo/                 # dedizierter Checkout von GitHub main
├── releases/             # YYYYMMDDHHMMSS-<commit>
└── current -> releases/<aktiver-release>
```

Ein normales Deployment wird ausschließlich auf dem Server gestartet:

```bash
sudo /var/www/stylepanda-app/deploy.sh
```

Parallele Deployments werden mit `flock` verhindert. Bei einem Fehler vor dem Umschalten bleibt `current` unverändert; schlägt ein verpflichtender Smoke Check danach fehl, wird auf das zuvor aktive Release zurückgeschaltet. Nach Erfolg bleiben bis zu fünf verwaltete Releases erhalten, wobei der aktuelle und der unmittelbar vorherige Release geschützt sind. Fremd benannte Verzeichnisse unter `releases/` werden nicht gelöscht.

Für statische Releases ist kein nginx-Reload notwendig. Das Script verändert weder nginx noch TLS, DNS, Benutzerrechte oder Eigentümer.

### Einmalige Installation

Nach Prüfung und Merge des Scripts muss der Production-Checkout zunächst kontrolliert auf `origin/main` gebracht werden. Anschließend wird die geprüfte Datei mit Root-Eigentum und ausführbaren, aber nicht global schreibbaren Rechten installiert:

```bash
sudo install --owner=root --group=root --mode=0755 \
  /var/www/stylepanda-app/repo/scripts/deploy.sh \
  /var/www/stylepanda-app/deploy.sh
```

Dieser Installationsschritt startet kein Deployment. Wenn `scripts/deploy.sh` später geändert wird, muss die neue Version erneut geprüft und bewusst installiert werden; das Deployment-Script ersetzt sich nicht selbst.

### Erstes Production-Deployment

1. Lokale Änderungen prüfen, committen und nach `GitHub main` pushen.
2. Auf dem Server sicherstellen, dass `/var/www/stylepanda-app/repo` der dedizierte, saubere Checkout von `StylePanda/StylePanda-Main` ist.
3. Den Checkout einmalig auf den geprüften Stand von `origin/main` bringen.
4. `scripts/deploy.sh` mit dem oben dokumentierten `install`-Befehl installieren.
5. `sudo /var/www/stylepanda-app/deploy.sh` ausführen.
6. Erfolgsstatus, aufgelösten `current`-Pfad und die Website prüfen.

Das Script setzt voraus, dass der Server-Checkout bereits mit GitHub authentifiziert ist. Zugangsdaten gehören weder in das Script noch in dieses Repository.

### Manueller Rollback

Ein Release wird nie geraten oder hartcodiert. Als Root zuerst die vorhandenen verwalteten Releases anzeigen und anschließend bewusst einen Eintrag auswählen:

```bash
sudo -i
APP_ROOT=/var/www/stylepanda-app
RELEASES_DIR=/var/www/stylepanda-app/releases
find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r
read -r -p "Release auswählen: " RELEASE
[[ "$RELEASE" =~ ^[0-9]{14}-[0-9a-f]{7,40}$ ]] || { echo "Ungültiger Release-Name"; exit 1; }
TARGET="$RELEASES_DIR/$RELEASE"
[[ -d "$TARGET" ]] || { echo "Release nicht gefunden"; exit 1; }
TEMP_LINK="$APP_ROOT/.current.rollback.$$"
ln -s -- "$TARGET" "$TEMP_LINK"
mv -Tf -- "$TEMP_LINK" "$APP_ROOT/current"
[[ "$(readlink -f -- "$APP_ROOT/current")" == "$TARGET" ]] || { echo "Symlink-Prüfung fehlgeschlagen"; exit 1; }
curl --fail --silent --show-error https://stylepanda.me/ >/dev/null
exit
```

Danach die sichtbaren Kerninhalte der Website prüfen. Der Rollback verändert nur den `current`-Symlink; er führt keinen nginx-Reload aus und löscht keinen Release.

## Empfohlene nginx-Ergänzungen

Diese Beispiele sind Dokumentation und wurden **nicht** auf Production angewendet. Bestehende TLS- und Server-Blöcke müssen zuerst geprüft werden.

Die `www`-HTTPS-Variante soll mit ihrer vorhandenen Zertifikatskonfiguration ausschließlich umleiten:

```nginx
server_name www.stylepanda.me;
return 301 https://stylepanda.me$request_uri;
```

Für die kanonische HTTPS-Site werden folgende Response-Header empfohlen:

```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header Content-Security-Policy "default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'; img-src 'self' data:; style-src 'self'; script-src 'self'" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header X-Frame-Options "DENY" always;
```

HSTS mit `includeSubDomains` darf erst aktiviert werden, wenn HTTPS für alle betroffenen Subdomains dauerhaft sichergestellt ist. Der CSP muss erneut geprüft werden, sobald externe Ressourcen oder JavaScript hinzukommen.

## Secrets

Secrets gehören nicht in dieses Repository. Lokale `.env`-Dateien sind ignoriert; falls später Konfiguration nötig wird, soll nur eine geheimnisfreie `.env.example` versioniert werden.

