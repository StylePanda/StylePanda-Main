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
└── assets/
    ├── css/main.css
    └── icons/README.md
```

Der Icon-Pfad ist für ein später freigegebenes StylePanda-Favicon reserviert. Solange kein echtes Marken-Asset vorliegt, bindet die Website kein Favicon und kein Social-Preview-Bild ein.

## Lokale Vorschau

Die Dateien müssen über einen lokalen statischen HTTP-Server ausgeliefert werden, damit root-relative Pfade wie in Production funktionieren. Beispiel mit einer vorhandenen Python-Installation:

```powershell
python -m http.server 8000
```

Danach ist die Startseite unter `http://localhost:8000/` erreichbar. Es müssen keine Abhängigkeiten installiert werden.

## Deployment-Grundidee

GitHub bleibt die Source of Truth:

```text
PC/Codex -> GitHub -> Production Server
```

Production ist noch nicht automatisch mit diesem Repository verbunden. Ein Deployment-Script wäre ohne bekannte Serveradresse, Zielpfad, Benutzer- und Freigaberegeln nicht sicher reproduzierbar und ist deshalb bewusst nicht enthalten. Der spätere Ablauf soll einen geprüften Stand von `main` serverseitig beziehen, in einen bekannten Document Root veröffentlichen, validieren und nginx nur bei tatsächlich geänderter Konfiguration kontrolliert neu laden. Direkte Deployments vom Entwicklungs-PC an GitHub vorbei sind nicht vorgesehen.

Noch zu klären sind Repository-Zugriff auf dem Server, Document Root, Eigentümer/Rechte, atomarer Release-Ablauf beziehungsweise Rollback und die vorhandene nginx-Konfiguration.

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

