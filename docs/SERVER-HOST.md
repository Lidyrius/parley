# Server-Host — Parley ohne Laptop

**Plan mit Pilot.** Stand 13.11.2026. Umgesetzt sind nur zwei Dinge, beide von Sir freigegeben:
neu Erzeugbares auf dem Big Boy geräumt und ein Wegwerf-Container als Pilot (siehe „Pilot").
Nichts bestellt, kein Update, kein Neustart, keine Profile oder Kundendaten übertragen.
Dieses Repo ist öffentlich: Server-Inventar, Kundennamen und Sicherheitsbefunde stehen im privaten
Anhang `docs/SERVER-HOST.privat.md` (lokal, nicht in Git). Der Code in `linux/` ist Pilot-Stand,
nicht committet.

## Ziel

Sir arbeitet unterwegs per iPhone (App und Anruf) an allen Projekten, auch wenn der Laptop aus ist.
Dafür läuft auf einem Server, was heute auf dem Mac läuft: Claude-Code-Sessions, Parley als Host
(Dispatch, Sessions, Überwachungsmodus, Wiedervorlagen, Anruf), der Workspace, MCPs und Connectoren
und ein Browser mit Sirs Logins.

## Kurzfassung

1. **Machbar, und der Kern ist schon da.** Antworten gehen per HTTP in die Session, nicht per
   Tastendruck. Im Anruf fasst der Host kein Audiogerät an. Der Relay verlangt keinen offenen Port.
2. **Linux-Variante aus dem Windows-Code bauen**, nicht aus dem Mac-Code: 72 % der C#-Dateien laufen
   unverändert oder mit dünner Naht, und .NET 8 bringt WebSocket, HTTP/2 und AES-GCM auf Linux mit.
3. **Sessions laufen in tmux.** Start, Bildschirm lesen, tippen, schließen sind in beiden Ports schon
   austauschbare Stellen.
4. **Das iPhone kennt heute genau einen Host.** Der Server bekommt einen eigenen Relay-Raum; für den
   Piloten wird umgekoppelt, danach lernt die App mehrere Hosts.
5. **Chrome-Profile nicht kopieren.** Die Logins kämen ohnehin nicht mit (Cookies hängen am
   macOS-Schlüsselbund), und beim Kunden sähe ein Umweg aus wie Token-Diebstahl. Stattdessen:
   Connectoren, wo es sie gibt; sonst frischer Login in einem sichtbaren Chrome auf dem Server.
6. **Workspace: Code reist per Commit, lose Dateien per Syncthing, Build-Ergebnisse gar nicht.**
   61 GB auf dem Mac, davon müssen rund 36 GB wirklich hinüber.
7. **Ort: der Big Boy trägt es.** Leistung ist frei, Platz lässt sich schaffen, eine verschlüsselte
   Zusatzplatte kostet ab 11 €/Monat. Ein eigener Host (27–152 €/Monat) trennt sauberer von den
   vielen öffentlich erreichbaren Diensten dort — das ist die eigentliche Entscheidung (E1).
8. **Ein Kipp-Risiko bleibt:** die Kunden-IT muss den Zugriff von einem Server erlauben. Das zweite
   ist entschärft: Groq antwortet der Big-Boy-IP (Probe vom 13.11.: HTTP 401, kein 403).

## Pilot auf dem Big Boy (13.11.2026)

Ein Container `parley-pilot`: nichts am Host installiert, keine Ports veröffentlicht, auf 12 GB und
sechs Kerne begrenzt, Daten außerhalb des Backup-Laufs. Darin .NET 8, tmux, Node, Chrome,
Claude Code und der Linux-Daemon aus `linux/`.

| Geprüft | Ergebnis |
|---|---|
| Aufräumen, nur neu Erzeugbares | 361 → 305 GB belegt, 54 → 109 GB frei; alle Container liefen durch |
| Verbindung übers Tailnet | SSH über die Tailnet-Adresse |
| Claude Code ohne Bildschirm | Anmeldung per Link und Code; Session in tmux, gleicher Pfad wie am Mac |
| Linux-Daemon aus dem C#-Code | 1.213 neue Zeilen in `linux/`, 139 geänderte in sieben gemeinsamen Dateien, jede hinter einer Betriebssystem-Prüfung; 0 Fehler |
| Windows-App danach | kompiliert unverändert — erstmals ohne CI prüfbar, auf Linux mit `-p:EnableWindowsTargeting=true -r win-x64` |
| Dispatch | der Daemon startet eine echte Claude-Session in tmux (`claude '/parley:voice'`); der Auftrag kommt über das parley-ui-Mod an |
| Relay vom Rechenzentrum aus | ein simuliertes Handy koppelt, sieht die Sessionliste; eine getippte Nachricht landet in der Session |
| Sprache hin | Google-TTS vom Server; 10 bis 21 Sekunden Stimme und Untertitel kommen über den Relay an |
| Sprache zurück | Mikro-Frames → Sprechpausen-Erkennung → Groq mit echtem Schlüssel von der Server-IP: Satz wörtlich erkannt, 0,2 s |
| Ganzer Zug | Antwort vom Handy → die Session legt eine Datei an → der Server ruft an und spricht das Ergebnis |
| Wiedervorlage, Startprüfung, Schließen, Neustart | in Ordnung |
| Browser | Chrome sichtbar auf virtuellem Display; eine echte Session steuert ihn über Playwright-MCP (CDP nur auf `127.0.0.1`) |
| Last | drei Claude-Sessions, Chrome und Daemon zusammen: 1,6 GB RAM, 2 % CPU |

**Nicht geprüft**

- Das echte iPhone: Umkoppeln nur auf Sirs Wort. Damit auch kein Push, kein CallKit, keine Live Activity.
- Funkloch-Schutz (v8): das simulierte Handy spricht das ältere, gestreamte Verfahren.
- Überwachungsmodus und Zentrale auf dem Server, Freigaben und Gäste.
- Claude in Chrome; jede Anmeldung an Agentur- oder Kundendiensten.
- Betrieb über Tage.

**Was der Pilot gezeigt hat**

1. **Chromes Sandbox braucht im Container ein eigenes seccomp-Profil.** Mit Dockers Standardprofil
   startet Chrome nur ohne Sandbox; so lief der erste Browser-Test, nur auf öffentlichen Seiten. Mit
   dem Standardprofil plus vier Systemaufrufen (`clone`, `unshare`, `setns`, `chroot`) läuft Chrome
   **mit** Sandbox, kopflos und sichtbar: Renderer im eigenen PID- und Nutzer-Namensraum,
   seccomp-Filter aktiv, keine Rechte. AppArmor bleibt dabei an. Nachgeprüft am 13.11.
   bubblewrap, also die Sandbox von Claude Code, läuft im Container auch damit nicht.
2. **Ein unbeantwortetes Klingeln hält alle Sessions auf.** Ein Host, der immer „Unterwegs" ist,
   klingelt bei jedem Turn 45 Sekunden und wartet danach bis zu 30 Minuten auf einen Rückruf. Im Pilot
   per Schalter (`PARLEY_CALLBACK_WAIT_SECONDS`) verkürzt; die Regel dafür ist offen (E10).
3. **Connectoren kommen nicht von selbst mit.** Die Konto-Plugins erscheinen nach der Anmeldung, jeder
   ihrer MCP-Server verlangt aber eine neue Anmeldung auf dieser Maschine. Gmail und Docs erschienen
   gar nicht. Eigene MCP-Server müssen neu eingetragen werden (Playwright: ein Befehl).
4. **Das Tailnet hat weitere Mitglieder.** Der Arbeits-Host braucht eine Regel, die nur Sirs Geräte durchlässt.
5. **Rückfragen ohne Bildschirm:** bleibt eine Erlaubnis-Frage ohne klare Sprachantwort, sagt der
   Linux-Host „nein", statt am Bildschirm zu hängen.
6. **Bilder fehlen noch:** Verlaufsbilder und Folien brauchen JPEG ohne `System.Drawing`.
7. **Eine Beobachtung, nicht untersucht:** die gesprochene Antwort auf die Begrüßung kam nicht als
   Eingabe in der Session an; im selben Moment lief der Dispatch-Auftrag ein.

## Befunde

### Parley-Code

| Frage | Befund | Beleg |
|---|---|---|
| Wie kommt die Antwort in die Session? | Drei HTTP-Wege: Stop-Hook pollt `/turn`, geparkter Hook pollt `/wake`, das parley-ui-Mod holt sie über `/presence`. Keine Tastendrücke, kein Accessibility. | `app/…/Server.swift:170-183,826-851,1106-1133`, `windows/Server.cs:187,241,277` |
| Braucht der Host Mikro oder Lautsprecher? | Nein, solange „Unterwegs" gilt. Im Anruf: Google-TTS → PCM-Frames → Relay; Mikro-Frames vom Handy → Groq. | `docs/IPHONE.md:151-152`, `windows/AudioOut.cs:71-83`, `windows/MicCapture.cs:31-42` |
| Was hängt am Mac/Windows-Desktop? | Session starten, Startprüfung, schließen: `osascript` → Terminal.app bzw. `wt.exe`. | `app/…/Zentrale.swift:96-127`, `app/…/StartWatch.swift:76-115`, `windows/Zentrale.cs:263-291` |
| Sind diese Stellen austauschbar? | Ja. Mac: Closures `starter`, `tabScreen`, `tabType`, `closer`. Windows: `Delivery` nimmt eine Start-Funktion, `Server.Closer` ist tauschbar. | `app/…/Server.swift:46-56`, `windows/Zentrale.cs:406-410`, `windows/Server.cs:1100` |
| Funktioniert das Plugin auf Linux? | Der Hook-Weg ja (bash, curl, jq, perl gegen `127.0.0.1:8787`). `greet.sh` und das Zentrale-Handbuch lesen die Sprache nur aus Mac-/Windows-Pfaden; `install.sh` lehnt Nicht-macOS ab. | `plugin/scripts/greet.sh:79-85`, `zentrale/CLAUDE.md:62-65`, `install.sh:15` |

**Swift oder C# als Basis?**

| | Swift (`app/`, 14.791 Zeilen) | C# (`windows/`, 15.921 Zeilen) |
|---|---|---|
| Unverändert portabel | 32 % | 48 % (24 Dateien) |
| Portabel mit dünner Naht | 26 % | 24 % (11 Dateien, ca. 600 Zeilen plattformgebunden) |
| Neu zu hosten | `AppController` (1.763 Zeilen, `@MainActor`, einziger Ort der Pipeline) | ca. 380 Zeilen Verdrahtung aus `TrayApp` (`Program.cs`) |
| Unsicherheiten auf Linux | `URLSessionWebSocketTask`, HTTP/2 für APNs, `URLSession.bytes`, Network.framework → SwiftNIO (alles ungetestet) | `System.Drawing` (JPEG) ersetzen, Pfad-Normalisierung, Dateirechte |
| Abhängigkeiten | keine SwiftPM-Pakete, aber CryptoKit → swift-crypto | NAudio (nur `WaveFormat` gebraucht), SoundTouch.Net (läuft) |

→ C#. Die Linux-Variante teilt sich die Quelldateien mit Windows; die 1:1-Regel kostet dann wenig.

Fallen im C#-Code, die der Port lösen muss:

- `CwdPath.Normalize` macht aus `/` ein `\` und vergleicht ohne Groß-/Kleinschreibung (19 Stellen, `windows/Zentrale.cs:18-40`).
- `Config.Dir` liefert auf Unix einen leeren Pfad, wenn `~/.config` fehlt (`windows/Config.cs:55-56`).
- `credentials.json` und `shares.json` werden ohne Unix-Dateimodus geschrieben (`windows/Config.cs:146-147`).
- Die Loopback-API hat keine Anmeldung (`windows/Server.cs:133-160`). Auf einem Rechner mit mehreren
  Nutzern oder Containern darf jeder lokale Prozess `/dispatch` rufen.
- Rückfragen, die heute „dem Bildschirm überlassen" werden (`windows/TurnPipeline.cs:198,205,212`),
  sieht auf dem Server niemand. Sie müssen ans Handy oder werden abgelehnt.
- Fehler erscheinen nur als Desktop-Meldung (`Notifier`). Headless: Log und Push ans Handy.
- Groq antwortet VPN- und Rechenzentrums-IPs mit 403 (`windows/Groq.cs:108`,
  `app/…/AppController.swift:1673`). Betrifft STT, Klassifizierung und Wake-Routing.

### Verbindung

- Der Relay ist ein Cloudflare Worker, ein Durable Object je Raum. Host und Handy wählen beide per
  `wss` hinaus; jeder Frame ist mit AES-256-GCM versiegelt, der Relay sieht nur den Typ
  (`relay/src/index.ts:41-100`, `docs/IPHONE.md:33-95`). **Kein offener Port, kein VPN am Handy.**
- Ein Raum trägt genau einen Host; ein zweiter wirft den ersten hinaus (`relay/src/index.ts:62-65`).
- Das iPhone hält genau eine Kopplung (`ios/ParleyMobile/Pairing.swift:81-102`).
- Push-Tokens gelten fürs ganze Gerät, nicht für die Kopplung. Jeder Host hält sie in seiner
  `credentials.json`; ein alter Host kann das Handy weiter klingeln lassen.
- APNs schickt der Host selbst (`.p8`-Schlüssel, HTTP/2), nicht der Relay (`app/…/APNs.swift:24-29`).
- Multiplayer (v7) zeigt den Weg: je Freigabe ein eigener Raum, das Handy hält dafür eine weitere
  Verbindung, „der Relay braucht nichts Neues" (`docs/IPHONE.md:366-368`).
- Live Activity und Widget gibt es einmal pro Gerät. Zwei Hosts würden sie sich gegenseitig beenden.

### Server (Details im privaten Anhang)

- Hetzner **Dedicated**, kein Cloud-Server: i7-8700 (6 Kerne/12 Threads), 62 GiB RAM, davon 33 frei,
  2× 477 GB NVMe im RAID1. Cloud-Volumes lassen sich an diese Maschine nicht anhängen.
- **Platte:** vor dem Aufräumen 88 % belegt und 54 GB frei, danach 74 % und 109 GB (Build-Cache,
  Logs, Editor-Caches). Weitere rund 115 GB sind Altlasten, die Sir ausdrücklich nicht angefasst haben
  will (Gameserver, Backups, Images). Liste mit Größen im Anhang.
- Gut zwei Drittel der Nutzdaten dort gehören Gameservern, nicht Kundensystemen.
- Eine Zusatzplatte ist möglich: Hetzner baut bei diesem Modell eine NVMe (512 GB bis 2 TB) oder
  zwei SATA-SSDs ein, per Ticket, 30–60 Minuten Ausfall nach Termin.
- Die Maschine trägt viele weitere Dienste, darunter Produktivsysteme; alles läuft als root;
  keine Plattenverschlüsselung. Der Pflegestand steht im Anhang.
- Ein Tailnet gibt es schon (selbst gehostetes headscale), das iPhone ist noch nicht darin.
- Es fehlen: Claude Code, Node, .NET, Chrome. Vorhanden: Docker, tmux, git, rsync, restic, KVM.

### Leistungsbedarf (am Mac gemessen, 13.11.)

| | |
|---|---|
| 21 laufende Claude-Code-Prozesse | 2,2 GB zusammen; im Schnitt 104 MB, Spitze 365 MB |
| MCP-Hilfsprozesse | 0,2 GB |
| Chrome, mehrere Profile, 109 Prozesse | 4,5 GB |
| Der Mac selbst | 18 GB RAM, 11 Kerne — und trägt das alles |

macOS komprimiert Speicher; auf Linux eher das Doppelte ansetzen. Für den Server: zehn Sessions
2–4 GB, Chrome mit Display 4–6 GB, Builds 4–8 GB, System und Daemon 2 GB.
**16 GB reichen, 32 GB sind bequem; 6–8 Kerne; 150 GB Platte.** Der Big Boy hat 33 GB RAM frei
und 12 Threads bei 93 % Leerlauf.

### Workspace (auf dem Mac gemessen)

| | |
|---|---|
| Gesamt | 61 GB, 1,58 Mio. Dateien |
| Neu erzeugbar (`node_modules`, `.next`, `vendor`, `.venv`, `build` …) | 18,9 GB |
| `.git` | 6,1 GB, fast alles von den Remotes holbar |
| **Netto** | **36 GB** |
| Davon ohne Git-Weg (muss per Datei-Sync reisen) | ca. 25–28 GB |
| Repos | 155, dazu 104 Worktrees |
| ohne Remote | 43 |
| mit ungespeicherten Änderungen | 84 |
| mit ungepushten Commits | 13 |
| mit Stashes | 13 |
| Ordner ohne Git | 299 (14 GB) |
| `.env`-Dateien | 207, davon 97 ohne Git-Weg |
| `~/.claude` | 10 GB, davon 9,4 GB Transkripte; die Memory-Ordner zusammen 1,1 MB |

Bedarf auf dem Server: 36 GB netto + 6 GB `.git` + bis 19 GB neu gebaute Abhängigkeiten + `~/.claude`
≈ 70 GB, mit Luft **150 GB**.

### Claude Code auf einem Server

- **Anmeldung:** `/login` über SSH (URL kopieren, Code einfügen). Das Token aus `claude setup-token`
  reicht nicht: damit gibt es weder Connectoren noch Remote Control noch Chrome-Anbindung.
- Zugangsdaten liegen auf Linux in `~/.claude/.credentials.json` (0600, kein Schlüsselbund).
- Läuft der Login ab, stehen alle unbeaufsichtigten Sessions, bis neu angemeldet wird.
- **Connectoren** (Gmail, Kalender …) holt Claude Code nach `/login` selbst. Neu-Anmeldung eines
  Connectors ohne Browser: `claude mcp login "<name>"`, URL am Handy öffnen, Redirect-URL einfügen.
- **Pfad-Schlüssel:** Transkripte und Memory liegen unter `~/.claude/projects/<Pfad>`. Liegt der
  Workspace auf dem Server unter demselben absoluten Pfad wie auf dem Mac, bleiben die Schlüssel
  gleich. Ein Symlink reicht dafür vermutlich nicht (ungetestet); ein echter Ordner oder Mountpunkt schon.
- **Remote Control** (`claude remote-control`) ist bereits vorhanden: Sessions auf dem Server, vom
  Handy über die Claude-App gesteuert, nur ausgehendes HTTPS. Ohne Anruf, Zentrale und Überwachung,
  aber ohne eine Zeile eigenen Code.
- Die **Sandbox** deckt nur Bash. MCP-Server und Hooks laufen mit vollem Zugriff des Nutzers.
- Nicht dokumentiert: ob ein Abo auf zwei Rechnern gleichzeitig angemeldet sein darf. Die
  Nutzungsgrenzen gelten in jedem Fall fürs Konto, Mac und Server teilen sie sich.

### Browser

- **Profil kopieren trägt die Logins nicht.** Cookies und Passwörter sind mit einem Schlüssel aus dem
  macOS-Schlüsselbund verschlüsselt; Linux kann sie nicht lesen. Teams legt seine Tokens zusätzlich
  verschlüsselt ab, der Schlüssel dazu steckt in einem Sitzungs-Cookie.
- Die Technik, das zu umgehen (Cookies entschlüsseln und wieder einspielen), ist dieselbe, die
  Schadsoftware nutzt. Microsoft Entra meldet so etwas als „anomalous token"; die Folge reicht von
  erzwungener Neuanmeldung bis zur Sperre und einem Vorfall beim Sicherheitsteam des Kunden.
- Ein **frischer Login mit MFA** von einer Server-IP klappt meist, außer der Kunde verlangt ein
  verwaltetes Gerät oder sperrt Standorte. Auffallen kann er trotzdem.
- **Claude in Chrome** ist für Linux dokumentiert, verlangt ein sichtbares Fenster und `/login`.
  Ob es unter einem virtuellen Display läuft, sagt keine offizielle Quelle. **Playwright-MCP**
  an einem laufenden Chrome (CDP nur auf `127.0.0.1`) ist der robustere Weg.
- Wo der Browser entfallen kann: Outlook/Kalender über den Microsoft-365-Connector (braucht einmal
  Admin-Zustimmung im jeweiligen Tenant), monday über dessen MCP, Jira über den Atlassian-MCP
  (wenn der Kunde es erlaubt), Gmail über den Connector. Ein Lieferantenportal ohne Nutzer-API braucht
  einen Browser.
- Sitzungsdauer bei Entra: bis etwa 90 Tage rollierend, wenn der Kunde nichts Engeres setzt.

## Zielbild

```
 iPhone (App, Anruf)                              Mac (bleibt eigener Host)
      │ wss, versiegelt                                │ wss
      ▼                                                ▼
   Relay (Cloudflare Worker) ─ ein Raum je Host ───────┘
      ▲
      │ wss, ausgehend — kein offener Port
 ┌────┴──────────────────── Arbeits-Host (Linux) ─────────────────────┐
 │ parley (systemd, eigener Nutzer)                                   │
 │   Relay · Anruf · APNs · TTS/STT · Zentrale · Überwachung ·        │
 │   Wiedervorlagen            127.0.0.1:8787 ◄── Stop-Hook, parley-ui│
 │ tmux: je Session ein Fenster → claude '/parley:voice'              │
 │ /Users/sydney/workspace und ~/.claude auf verschlüsseltem Volume   │
 │ Chrome, sichtbar auf virtuellem Display ◄── Playwright-MCP (CDP    │
 │   nur 127.0.0.1); je Profil ein eigener Unix-Nutzer                │
 └────────────────────────────────────────────────────────────────────┘
      ▲ Tailnet (headscale): SSH, Remote-Desktop, Syncthing
      ▲ Git-Remotes: Code                ▼ restic → Storage Box: Backup
```

Was wo entlangläuft:

| Verkehr | Weg | Offener Port |
|---|---|---|
| Sprache, Sessions, Verlauf, Folien, Anruf | Relay | keiner |
| Push, Klingeln, Live Activity | Host → APNs | keiner |
| SSH, Remote-Desktop (für Logins), Syncthing | Tailnet | keiner |
| Code | Git-Remotes | keiner |
| Notzugang | Hetzner-Konsole mit 2FA | — |

## Bausteine

### 1. Host-Daemon `linux/`

- `linux/Parley.Linux.csproj` (`net8.0`, `Exe`) bindet `../windows/*.cs` ein und schließt die
  UI-Dateien aus. Getrennte Dateien statt `#if`, weil lokal niemand kompiliert.
- Die Verdrahtung aus `TrayApp` (Pipeline, Server, Relay, Timer für Wiedervorlagen und Watchdog,
  Telefon-Kommandos) wandert in eine gemeinsame Datei. Das ist der heikelste Schritt: Windows wird
  nur per CI kompiliert.
- Neu für Linux: tmux-Starter, -Schließer und -Startprüfung (`capture-pane`, `send-keys`). Damit
  erfüllt Linux den Mac-Vertrag der Startprüfung, nicht den schmaleren von Windows.
- „Unterwegs" ist fest an (`PhoneCall.SetLockedAway(true)`), sonst spricht der Host ins Leere.
- Bedienung ohne Tray: `credentials.json` ist schon die Konfiguration. Dazu die Befehle `pair`
  (Link und QR im Terminal), `push-key <p8>`, `status`, `doctor`, `mute`.
- Pfade, Konfig-Ordner, Dateimodus 0600, JPEG ohne `System.Drawing`, Zeitzone und `de-DE`.
- Rückfragen ohne Bildschirm gehen ans Handy; Fehler ins Log und als Push.
- Loopback-API bekommt ein Token (gilt dann für alle drei Ports).
- Plugin: Linux-Pfad in `greet.sh` und im Zentrale-Handbuch, `install.sh` für Linux, systemd-Unit.
- CI: zweiter Job auf `ubuntu-latest`, `linux-x64`, `tar.gz`, Tag `linux-v*`; Pfadfilter so, dass
  `windows/**` beide Builds auslöst. `CLAUDE.md` nennt danach drei Ports.

### 2. Zweiter Host im iPhone

- **Pilot ohne App-Änderung:** das Handy wird auf den Server umgekoppelt. Hosts sind dann nie
  gleichzeitig da, und der alte Host kann weiter klingeln.
- **Danach Mehr-Host:** Kopplungsliste statt einer Kopplung (Vorlage: `loadGuests`), Tokens und
  Schalter an alle Hosts, Klingeln und Anruf nach Host, Sessionliste und Zentrale-Karte je Host,
  eine Regel, wem Live Activity und Widget gehören. Protokoll nur additiv: Hostname im
  Kopplungslink, Host-Kennung im VoIP-Push. Mac und Windows schicken die Kennung ebenfalls.
- Offen: eine Zentrale je Host oder eine über alle. `/dispatch` ist lokal; eine Zentrale erreicht
  nur Sessions ihres eigenen Hosts.

### 3. Workspace und Sync

Merksatz: **Code reist per Commit. Lose Dateien reisen von selbst. Build-Ergebnisse reisen nie.**

- Server-Nutzer mit Home `/Users/sydney`, Workspace als echter Ordner am selben Pfad wie auf dem Mac.
- Repos: der Server klont von den Remotes; kein Repo wird dateiweise synchronisiert. Server-Sessions
  arbeiten in Worktrees auf `claude/<aufgabe>` und pushen; `main` zieht der Server nur per
  `pull --ff-only`. Die 43 Repos ohne Remote bekommen ein Bare-Remote auf dem Server.
- Alles außerhalb von Git: Syncthing, ein Ordner in beide Richtungen, übers Tailnet. Ausgeschlossen
  sind Repo-Wurzeln, alles neu Erzeugbare und Caches; `.env*` ist ausdrücklich eingeschlossen.
- Konflikte: in Git als Merge-Konflikt am Laptop; bei Syncthing gewinnt die neuere Datei, die
  ältere bleibt als `.sync-conflict`-Kopie. Ein täglicher Lauf meldet solche Kopien.
  `.env` schreibt nur der Laptop.
- `~/.claude`: nur die Memory-Ordner (1,1 MB) synchronisieren, Transkripte nicht.
- Abhängigkeiten baut jede Maschine selbst (darwin-arm64 gegen linux-x64). Xcode-Builds bleiben am Mac.
- **Vor dem Start aufräumen:** 84 Repos mit offenen Änderungen, 13 mit ungepushten Commits,
  13 mit Stashes. Was nicht committet ist, kommt nicht an.
- Backup: restic nachts auf eine Storage Box, clientseitig verschlüsselt. Syncthing ist kein Backup.
- Erstbefüllung: ca. 25–28 GB vom Laptop, bei 20 Mbit/s Upload rund 3 Stunden.

### 4. Claude Code, MCPs, Connectoren

- Installieren, `/login`, Plugins aus ihren Marktplätzen neu installieren (nicht kopieren).
- Kopieren: `settings.json`, `CLAUDE.md`, `skills/`, `agents/`, `commands/`. **Nicht** kopieren:
  `.credentials.json`, `~/.claude.json`, Transkripte, `history.jsonl`.
- MCP-Server neu eintragen (`claude mcp add --scope user`); Connectoren kommen mit dem Login.
- Unbeaufsichtigte Sessions: kein `--dangerously-skip-permissions`. Erlaubnisliste plus Sandbox;
  senden, pushen, deployen bleibt eine Rückfrage ans Handy.

### 5. Browser

1. Connectoren und MCPs zuerst (Agentur-Outlook und -Kalender, monday, Gmail; Jira, wenn erlaubt).
2. Für den Rest: **je Chrome-Profil ein eigener Container** mit kleinem Linux-Desktop. Sir meldet
   sich einmal über den Web-Desktop frisch an, erreichbar nur im Tailnet. Claude steuert über
   Playwright-MCP. Einzelheiten im nächsten Abschnitt.
3. Das Agentur-Profil kann sofort. **Das Kundenprofil erst nach schriftlicher Freigabe der Kunden-IT.**
4. Ausweg, falls der Kunde ablehnt: ein immer laufender Rechner zu Hause oder im Büro behält das
   bekannte Gerät und die bekannte IP.

### 6. Browser-Container (Empfehlung)

Ein Container je Profil, nicht ein Desktop mit vielen Profilen. Ein Desktop für alle wäre bequemer,
aber dann teilen sich Agentur- und Kundensitzungen einen Nutzer und ein Dateisystem; ein Vorfall in
einem Profil träfe alle.

| Frage | Empfehlung |
|---|---|
| Was läuft im Container | virtuelles Display (Xvfb), ein schlichter Fenstermanager, Google Chrome, ein VNC-Server mit Web-Zugang (noVNC oder KasmVNC). Kein vollständiger Desktop nötig |
| Image | das eigene Pilot-Image als Grundlage (`linux/pilot/Dockerfile`) plus VNC. Fertige Desktop-Images sind bequem, starten Chrome aber oft ohne Sandbox — vor Gebrauch prüfen |
| Sandbox | seccomp-Profil = Docker-Standard + `clone`, `unshare`, `setns`, `chroot`. **Nicht:** `--no-sandbox`, `--privileged`, `SYS_ADMIN`, `seccomp=unconfined` |
| Profil-Daten | je Container ein eigenes Volume auf der verschlüsselten Platte; kein Chrome-Sync, keine gespeicherten Passwörter |
| Anmelden | frisch, über den Web-Desktop, vom Mac oder iPhone. Profile werden nie kopiert |
| Zugang zum Web-Desktop | Port nur an die Tailnet-Adresse oder `127.0.0.1` binden, nie an alle Schnittstellen — von Docker veröffentlichte Ports umgehen die Firewall. Eigenes Passwort, Tailnet-Regel nur für Sirs Geräte |
| Zugang für Claude | Playwright-MCP je Profil mit `--cdp-endpoint`. Der CDP-Port wird nicht veröffentlicht; er liegt in einem privaten Docker-Netz, das nur Browser- und Session-Container teilen |
| Grenzen | je Container 2 GB RAM, `--shm-size 1g`, kein automatischer Neustart ohne entsperrtes Volume |
| Not-Aus | Container stoppen, Volume schließen; beim Anbieter „überall abmelden" |
| Pflege | Chrome altert im Image: wöchentlich neu bauen. Schriften für CJK nachinstallieren, sonst Kästchen |

Offen: Claude in Chrome (die Erweiterung) im Container ist ungeprüft; Playwright-MCP ist geprüft.
Wer eine härtere Grenze will als einen Container, nimmt je Profil eine kleine VM oder den eigenen Host.

## Sicherheitskonzept

Der Arbeits-Host wird das wertvollste Ziel in Sirs Umgebung: alle Kunden-Repos, alle `.env`, die
Claude-Anmeldung, Mail-Zugriff, angemeldete Browser und ein Agent, der unbeaufsichtigt handelt.

**Browser-Sitzungen**

- Keine Profil-Kopie, kein Cookie-Export. Nur frische Logins auf dem Server.
- Profile liegen auf einem LUKS-Volume, das nach einem Neustart von Hand entsperrt wird. Das schützt
  vor Plattenabzug, Snapshot und Ausmusterung — **nicht** vor einem Einbruch in den laufenden Server.
- Je Profil ein Container mit eigenem Volume, Chrome nie als root. Ein Vorfall im Kundenprofil
  erreicht so das Agentur-Profil nicht.
- CDP nie veröffentlicht, nur im privaten Docker-Netz. Wer den Debug-Port erreicht, besitzt jedes
  Konto in diesem Browser.
- Remote-Desktop nur übers Tailnet und mit eigener Anmeldung.
- Verboten: `--no-sandbox`, `--disable-web-security`, `--remote-allow-origins=*`,
  `--password-store=basic`, Tarn-Flags. Kein Chrome-Sync, keine gespeicherten Passwörter.
- Not-Aus: ein Befehl beendet Chrome und schließt das Volume. Dazu beim Anbieter „überall abmelden"
  (Microsoft, Atlassian); bei Gastkonten gilt die Abmeldung im Heimat-Tenant.
- Protokoll: was der Agent im Browser getan hat, wird mitgeschrieben und vom Server weg gesichert.
- Prompt-Injection: Teams-Nachrichten, Jira-Tickets und Mails kann ein Angreifer schreiben.
  Sessions, die solche Inhalte lesen, bekommen keine Schreibrechte ohne Rückfrage.

**Firmen-Richtlinien.** Üblich sind: Zugriff nur von freigegebenen Geräten, persönliche Konten
nicht übertragbar, kein automatisierter Zugriff ohne Zustimmung, Unterauftragnehmer nur mit
Freigabe. Hetzner und Anthropic werden zu weiteren Auftragsverarbeitern. Fragen an die Kunden-IT:

1. Darf das Konto von einem nicht verwalteten Server genutzt werden, und von welcher IP?
2. Darf ein KI-Agent unter dem Konto handeln, oder soll er eine eigene Identität bekommen?
3. Stimmt der Admin dem Microsoft-365-Connector zu? Sind Atlassian-MCP oder API-Tokens erlaubt?
4. Welche Zugriffsregeln gelten (Gerät, Standort, Anmeldehäufigkeit)?
5. Sind Hetzner und Anthropic als Unterauftragnehmer in Ordnung?
6. Welche Protokolle und welchen Ansprechpartner für Vorfälle erwarten sie?

**Host**

- Öffentlich keine neuen Ports. SSH nur übers Tailnet, nur Schlüssel, nicht als root.
- Eigener Nutzer für Parley und die Sessions, nicht in der Docker-Gruppe.
- LUKS für Workspace, Profile und `~/.claude`. Automatischer Neustart aus, weil das Volume danach
  von Hand entsperrt werden muss.
- Geheimnisse: `credentials.json` 0600 auf dem verschlüsselten Volume; der Server bekommt eigene
  Relay-Schlüssel und eine eigene Kopie des APNs-Schlüssels.
- Meldung bei jedem Login, bei neuem Tailnet-Gerät, bei fehlgeschlagenem Backup, vor Ablauf der
  Claude-Anmeldung.
- Das Tailnet hängt an headscale auf dem Big Boy. Fällt der aus, bleibt die Hetzner-Konsole.

**Wenn das Handy weg ist:** Gerät orten oder löschen → aus dem Tailnet entfernen → Kopplung am Host
widerrufen → Claude abmelden → OAuth-Freigaben widerrufen → Firmenkonten überall abmelden, Kunden
informieren → SSH-Schlüssel tauschen. Bei Verdacht auf den Server: Snapshot, ausschalten, neu
aufsetzen, alle Geheimnisse tauschen.

## Phasen

Aufwand ist geschätzt. „Claude" = reine Arbeitszeit von Sessions, „Sir" = Review, Logins, Tests.

| Phase | Inhalt | Claude | Sir | Ergebnis |
|---|---|---|---|---|
| 0 | Entscheidungen E1–E9; vier Proben (siehe unten) | 2–3 h | 1 h | Die beiden Kipp-Risiken sind geklärt |
| 1 | Host aufsetzen und härten, Nutzer, LUKS, Tailnet, Claude Code, Plugins, MCPs, Remote Control als Dienst | 3–5 h | 1–2 h | Sir steuert Server-Sessions vom Handy über die Claude-App |
| 2 | Aufräumen der Repos, Klonen, Bare-Remotes, Syncthing, Backup | 4–6 h | 1–2 h | Workspace vollständig und aktuell auf dem Server |
| 3 | `linux/`-Daemon: **Pilot steht.** Offen: Host-Verdrahtung in eine gemeinsame Datei heben, Bilder, QR im Terminal, systemd, CI-Job, Plugin-Pfade, Test mit echtem iPhone | 6–10 h | 2–3 h | Anruf, Dispatch, Zentrale, Wiedervorlagen ohne Laptop |
| 4 | Mehrere Hosts in iPhone (und Android), Host-Kennung in Mac und Windows | 14–22 h | 3–4 h | Mac und Server nebeneinander in der App |
| 5 | Connectoren, Chrome mit Agentur-Profil; Kundenprofil nach Freigabe | 4–7 h | 1–2 h | Mail, Kalender, Aufgaben, Browser wie lokal |
| 6 | Zentrale zieht um, Überwachungsrunde ohne Claude in Chrome, Meldungen, Notfall-Liste, Restore-Probe | 4–6 h | 1–2 h | Dauerbetrieb |
| | **Summe, noch offen** | **37–59 h** | **10–16 h** | |

Kalenderzeit: zwei bis vier Wochen. Sie hängt an der App-Prüfung (Phase 4) und an der Antwort der
Kunden-IT (Phase 5). Phase 1 und 2 liefern schon für sich einen Nutzen; Phase 4 kann warten.

**Proben in Phase 0** (jede braucht Sirs Freigabe, weil sie Server oder CI berührt):

1. **Groq von der Server-IP — erledigt am 13.11.:** eine Anfrage ohne Schlüssel vom Big Boy ergab
   401 „Invalid API Key", also erreichbar. Mit echtem Schlüssel und auf einem neuen Host wiederholen.
2. **C#-Kern auf Linux:** ein CI-Job kompiliert die 24 unveränderten Dateien für `linux-x64`.
3. **Claude-Anmeldung auf zwei Rechnern** und Remote Control ohne Terminal.
4. **Claude in Chrome auf virtuellem Display** — nur falls Playwright-MCP allein nicht reicht.

## Kosten

Preise ohne MwSt., inkl. IPv4, am 13.11.2026 aus Hetzners öffentlicher Preis-API und den
Produktseiten. Abrechnung stündlich mit Monatsdeckel, keine Mindestlaufzeit.

**Auf dem Big Boy**

| Variante | Monat | Einmalig | Platz für den Workspace |
|---|---|---|---|
| Nur gefahrlos aufräumen + Storage Box | 3,20 € | — | ca. 108 GB frei: reicht für den Bestand (70 GB), nicht für 150 GB |
| Aufräumen samt Altlasten + Storage Box | 3,20 € | — | ca. 220 GB frei: reicht, die Platte steht danach wieder bei rund 84 % |
| **Zusatz-NVMe 512 GB, verschlüsselt** + Storage Box | **14,20 €** | 30–60 min Ausfall | eigene Platte, dreifacher Bedarf |
| Zusatz-NVMe 1 TB + Storage Box | 33,20 € | 30–60 min Ausfall | reichlich |

- Die Zusatzplatte ist einzeln, also ohne Spiegel. Vertretbar: Code liegt in Git, der Rest im
  nächtlichen Backup. Gespiegelt wären es zwei SATA-SSDs ab 82 €/Monat.
- Hetzner sichert die Verträglichkeit nicht zu. Die Platte hängt am Server und endet mit ihm.
- Eine Storage Box taugt zum Auslagern kalter Backups, nicht als Arbeitsverzeichnis: Festplatten
  übers Netz, jeder Dateizugriff ein Umlauf, keine Änderungsmeldungen. Hetzner rät selbst davon ab.

**Eigener Arbeits-Host**

| Variante | Maschine | Monat mit Storage Box | Einmalig |
|---|---|---|---|
| Sparsam | Cloud CPX42, Helsinki: 8 vCPU geteilt, 16 GB, 320 GB | 62,69 € (Nürnberg 73,19 €) | — |
| **Empfohlen** | Dedicated AX42-1: Ryzen 7 8700GE, 8 Kerne, 64 GB, 2× 512 GB NVMe | **102,20 €** | 49 € |
| Komfortabel | Dedicated EX63-1: Core Ultra 7 265, 20 Kerne, 64 GB, 2× 1 TB NVMe | 152,20 € | 74 € |
| Cloud statt Blech | CCX33, Helsinki: 8 vCPU dediziert, 32 GB, 240 GB | 121,19 € (Nürnberg 142,19 €) | — |
| Serverbörse | z. B. i7-8700, 64 GB, 2× 1 TB NVMe | ab ca. 107 € | — |

- Die günstige CX-Reihe (CX53: 32 GB für 29,99 €) ist derzeit nicht bestellbar; Hetzner beschränkt
  neue Cloud-Server seit Juni 2026 teilweise.
- Helsinki ist bei CPX und CCX seit dem 10.11.2026 um 15 % günstiger als Deutschland.
- Der AX42-1 unterbietet jede bestellbare 32-GB-Cloud-Maschine und hat doppelt so viel RAM. Cloud
  bietet dafür Snapshots, Größenwechsel und Kündigung zur Stunde.
- Cloud-Volume 0,0572 €/GB (150 GB = 8,58 €); Cloud-Backups +20 %, ohne Volumes; Firewall kostenlos.
  Verkehr: Cloud 20–30 TB inklusive, Dedicated unbegrenzt.

**Andere Anbieter** (13.11.2026, ohne MwSt., monatlich kündbar, wenn nicht anders vermerkt)

| Größe | netcup | OVHcloud | IONOS | Contabo |
|---|---|---|---|---|
| 16–24 GB | VPS 2000, 8 geteilte Kerne, 16 GB, 256 GB: 26,02 € | VPS-4, 8 Kerne, 24 GB, 200 GB, Frankfurt, tägliches Backup: 23,49 € | VPS XL+, 16 GB, 480 GB: 34,45 € nach Lockpreis | VPS 8, 24 GB, 300 GB: 14,00 € |
| 32 GB | RS 4000, 12 dedizierte Kerne, 512 GB NVMe: 75,21 € | So you Start, 6 Kerne Blech, 2× 512 GB: 50,41 € + 50,41 € einmalig | Cube L, 8 geteilte vCPU, 480 GB: 43,92 €, stündlich | VDS M, 8 dedizierte Kerne: 68,00 € |
| 64 GB | RS 8000, 16 dedizierte Kerne, 1 TB: 143,44 € | So you Start, 8 Kerne Blech, 2× 960 GB: 65,54 € + 65,54 € einmalig | AR8-64, 8 Kerne Blech: 96,64 € + Einrichtung, 12 Monate | VDS XL: 129,00 € |

- **Fallen:** netcup wird erst mit 12 oder 24 Monaten Vorauszahlung günstiger (RS 4000 dann 55,60 €) und
  kostet am Standort Nürnberg 15 % mehr. OVH nimmt eine Monatsmiete Einrichtung, außer bei
  Vorauszahlung; der Bestand an Blech schwankt täglich. IONOS lockt mit Einstiegspreisen und bindet
  bei Blech 12 Monate. Contabo teilt die Kerne und stellt neue Server eher in Frankreich auf.
- **Günstiger als Hetzner:** kleine VPS bei OVH und netcup (23–26 € gegen 62,69 €), 32 GB mit
  dedizierten Kernen bei netcup (75,21 € gegen 117,99 €), 64 GB Blech bei OVH (65,54 € gegen 99 €,
  ältere CPU).
- **Für Hetzner spricht:** kein weiterer Vertragspartner und kein weiterer Unterauftragnehmer
  gegenüber den Kunden, keine Vorauszahlung, keine Mindestlaufzeit.

**Drei Varianten für einen eigenen Host**

| | Bei Hetzner | Günstigste ernsthafte Alternative |
|---|---|---|
| Sparsam | CPX42 Helsinki, 16 GB: 62,69 € | OVH VPS-4, 24 GB: ca. 27 € mit Backup-Speicher |
| **Empfohlen** | **AX42-1, 64 GB Blech: 102,20 € + 49 € einmalig** | netcup RS 4000, 32 GB, dedizierte Kerne, Snapshots: ca. 78 € |
| Komfortabel | EX63-1, 20 Kerne, 2× 1 TB: 152,20 € + 74 € einmalig | — |

**Unverändert:** Tailnet 0 € (headscale), Relay 0 € (zweiter Raum, derselbe Worker), Groq und
Google-TTS nach Nutzung, Claude-Abo (Mac und Server teilen sich die Grenzen).

Also: **3–33 €/Monat auf dem Big Boy, 27–152 €/Monat mit eigenem Host.**

## Risiken

| Risiko | Folge | Gegenmittel |
|---|---|---|
| Groq sperrt Rechenzentrums-IPs | Kein STT, keine Sprachsteuerung vom Server | Vom Big Boy erreichbar (Probe 13.11.). Ein neuer Host hat eine andere IP: dort wiederholen. Ausweg: anderer STT-Anbieter oder Whisper auf dem Server |
| Kunde erlaubt Server-Zugriff nicht | Teams/Lieferantenportal des Kunden bleiben am Laptop | Früh fragen; Ausweg Heim-Rechner |
| Ein Einbruch trifft alles auf einmal | Alle Kunden betroffen | Eigener Host, keine offenen Ports, getrennte Nutzer, Not-Aus, Backups |
| Prompt-Injection über Mail, Teams, Jira | Agent verschickt oder verändert etwas | Lesen ohne Schreibrechte, Rückfrage bei jeder Außenwirkung |
| Claude-Anmeldung läuft ab | Alle Sessions stehen | Meldung drei Tage vorher, Neuanmeldung vom Handy |
| Nutzungsgrenzen | Server-Sessions bremsen die Arbeit am Mac | Zahl der Dauer-Sessions begrenzen; ggf. höhere Stufe |
| Umbau von `TrayApp` bricht Windows | Windows-Version fehlerhaft, fällt spät auf | Kleiner Schritt, eigener CI-Lauf, Test auf echtem Windows vor dem Release |
| Drei Ports auseinanderlaufen | Linux weicht ab | Linux teilt die Dateien mit Windows |
| Zwei Hosts, ein Gerät | Falscher Host klingelt, Live Activity flackert | Pilot mit einem Host; Phase 4 regelt Besitz |
| Platte auf dem Big Boy läuft voll | Alle Dienste dort fallen aus | Variante C, oder vorher Platz schaffen |
| Sync-Konflikte | Verlorene Änderungen | Server nur auf `claude/*`; Konfliktkopien werden gemeldet |
| Nutzungsbedingungen für Dauerbetrieb mit Abo | Unklar | Vor Phase 1 prüfen |

## Entscheidungen für Sir

- **E1 — Ort.**
  A: Big Boy, eigener Nutzer, Workspace auf verschlüsselter Zusatzplatte. Ab 14 €/Monat. Leistung
  und Platz reichen. Schwäche: ein Kernel mit vielen öffentlich erreichbaren Diensten, die als root
  laufen; wer dort ausbricht, erreicht alles.
  B: wie A, aber in einer virtuellen Maschine (KVM ist da). Eigener Kernel; wer auf dem Host root
  wird, liest die VM trotzdem. Eingriff in eine Produktivmaschine.
  C: eigener Arbeits-Host, 27–152 €/Monat. Sauber getrennt.
  **Nach dem Pilot:** Daemon, Sessions, Workspace und auch der Browser laufen auf dem Big Boy in
  Containern, ohne Eingriff in den Host — gezeigt, der Browser mit Sandbox über ein eigenes
  seccomp-Profil. Was A nicht löst: die Maschine teilt sich den Kernel mit vielen öffentlich
  erreichbaren Diensten, und die Sandbox von Claude Code läuft im Container nicht.
  **Empfehlung:** A mit Zusatzplatte (14 €/Monat) für eigene und Agentur-Arbeit samt Agentur-Browser.
  Bevor Kunden-Logins dazukommen, entscheiden, ob die Trennung einen eigenen Host wert ist (C);
  der Umzug der Container kostet etwa einen halben Tag.
  Voraussetzung für A auf Dauer: Updates und Neustart nachholen; der Einbau der Platte bringt den Ausfall ohnehin.
- **E2 — Basis des Daemons.** C# (geteilt mit Windows) oder Swift. **Empfehlung: C#.**
- **E3 — Hosts im iPhone.** Erst umkoppeln (Pilot), dann Mehr-Host-App. **Empfehlung: in dieser Reihenfolge.**
- **E4 — Browser.** Profile werden nicht kopiert; Connectoren zuerst; Agentur-Profil frisch anmelden.
  **Sirs Entscheidung:** Kunden-IT fragen — ja oder Kundenprofil bleibt am Laptop.
- **E5 — Umfang.** Alle Projekte sofort oder Pilot. **Empfehlung:** Pilot mit eigenen und
  Agentur-Projekten; Kundenprojekte nach Blick in die Verträge (Speicherort von Code und Zugangsdaten,
  KI-Nutzung, Unterauftragnehmer).
- **E6 — Sync.** Git plus Syncthing, gleicher Pfad `/Users/sydney/workspace`, Server schreibt nur
  `claude/*`. Vorher räumt jemand die 84 offenen Repos auf — Sir selbst oder Sessions mit Rückfrage.
- **E7 — Was darf eine Session ohne Rückfrage?** **Empfehlung:** lesen, bauen, testen, committen auf
  `claude/*`. Nie ohne Rückfrage: senden, pushen auf `main`, deployen, löschen.
- **E8 — Zentrale.** Zieht sie auf den Server (immer erreichbar), und bleibt am Mac eine zweite?
- **E9 — Remote Control** in Phase 1 als Zwischenlösung nutzen? **Empfehlung: ja**, kostet nichts.
- **E10 — Klingeln auf dem Server.** Soll ein Host, an dem nie jemand sitzt, bei jedem Turn anrufen
  und auf Rückruf warten? **Empfehlung:** auf dem Server gilt immer der Überwachungsmodus (nur die
  Zentrale ruft an), und das Rückruf-Warten ist kurz.
- **E11 — Pilot-Container.** Er läuft weiter, mit Sirs Claude-Anmeldung und den beiden Sprachschlüsseln.
  Stehen lassen für den Test mit dem echten iPhone, oder abbauen?

## Nicht geprüft

- Alles unter „Nicht geprüft" im Abschnitt Pilot.
- Claude in Chrome unter einem virtuellen Display.
- Symlink statt echtem Pfad. (Gleichzeitige Claude-Anmeldung auf Mac und Server: im Pilot gelaufen,
  ohne dass eine Seite abgemeldet wurde; über Tage nicht beobachtet.)
- Ob das Gehäuse des Big Boy die Zusatzplatte aufnimmt; was die Console diesem Konto anbietet.
- Ob die Altlasten auf dem Big Boy wirklich entbehrlich sind (nur Größen gemessen, nichts geöffnet).
- Verträge und Zugriffsregeln der Kunden.

## Quellen

- Claude Code: `code.claude.com/docs/en/` → `authentication`, `remote-control`, `agent-view`, `headless`,
  `hooks`, `mcp`, `sessions`, `permission-modes`, `sandboxing`, `chrome`, `claude-directory`
- Microsoft Entra: `learn.microsoft.com/en-us/entra/` → `identity/conditional-access/concept-token-protection`,
  `…/concept-session-lifetime`, `…/concept-continuous-access-evaluation`, `id-protection/concept-identity-protection-risks`
- Connectoren: `claude.com/docs/connectors/microsoft/365`, `developer.monday.com/api-reference/docs/mondaycom-mcp`,
  `support.atlassian.com/security-and-access-policies/docs/understand-atlassian-rovo-mcp-server/`
- Browser: `developer.chrome.com/blog/remote-debugging-port`, `github.com/microsoft/playwright-mcp`,
  `support.claude.com/en/articles/12902428-use-claude-in-chrome-safely`
- Hetzner-Preise: `website-price-api.hetzner.com/api/docs`, `hetzner.com/dedicated-rootserver/matrix-ax/`,
  `hetzner.com/dedicated-rootserver/matrix-ex/`, `hetzner.com/sb`,
  `docs.hetzner.com/robot/dedicated-server/dedicated-server-hardware/price-server-addons/`,
  `docs.hetzner.com/storage/general/which-storage-is-right-for-me/`
- Hetzner: `hetzner.com/cloud/`, `hetzner.com/storage/storage-box/`, `docs.hetzner.com/cloud/volumes/overview/`,
  `docs.hetzner.com/robot/dedicated-server/firewall/`,
  `hetzner.com/pressroom/standardization-and-price-adjustment-of-our-server-products/`
- Sync: `docs.syncthing.net/users/syncing.html`, `docs.syncthing.net/users/ignoring.html`
