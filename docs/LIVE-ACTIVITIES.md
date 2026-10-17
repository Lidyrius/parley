# Konzept: Parley in Dynamic Island, Live-Aktivitäten, Widgets und Steuerelementen

Status: **Stufe 1 und 2 gebaut** (Steuerelemente; Parley-Aktivität mit Rückruf / Später /
Pausiert, gestartet und aktualisiert per Push vom Mac und von Windows — Protokoll in
docs/IPHONE.md, „Protocol v4“). Offen: Antworten ohne App (4), Widgets (5), Untertitel im
Anruf (6). Apple-Stand: iOS 26 / iOS 27 (geprüft gegen Apples Doku, Oktober 2026).

## Die Idee in einem Satz

Parley ist da, wo du ohnehin hinschaust: oben in der Dynamic Island siehst du, was deine
Sessions gerade tun und ob eine auf dich wartet; auf dem Sperrbildschirm, in der Smart Stack
der Watch, im CarPlay-Dashboard und sogar in der Mac-Menüleiste dasselbe; antworten, fortsetzen
und anrufen geht mit einem Tipp – ohne die App zu öffnen.

## Was Apple anbietet (und wo die Grenzen liegen)

| Fläche | Was geht | Aktualisierung | Grenzen |
|---|---|---|---|
| **Live-Aktivität** (ActivityKit) | Sperrbildschirm/Banner; Dynamic Island *compact* (links + rechts der Kamera, je ~52–62 × 37 pt), *minimal* (Punkt, ~37–45 pt), *expanded* (lang drücken, bis 408 × 160 pt) | lokal aus der App oder per **APNs** `liveactivity`-Push vom Mac – auch ohne laufende App; **Push-to-Start** (iOS 17.2) startet sie ganz ohne App | Inhalt ≤ **4 KB**; **max. 8 h aktiv**, danach bis 4 h nur noch auf dem Sperrbildschirm; kein Netzwerk in der Aktivität; eigene Animationen ≤ 2 s; Island-Hintergrund immer schwarz (nur Randlinie tönbar) |
| **Timer im Text** | `Text(timerInterval:)`, `ProgressView(timerInterval:)` zählen selbst | gar nicht – läuft im System | Breite begrenzen (`.frame`) |
| **Knöpfe** | App Intents; `LiveActivityIntent` läuft im **App-Prozess** (im Hintergrund, ohne UI) und darf sogar eine Aktivität starten | – | nur in *expanded* und Sperrbildschirm; in CarPlay aus; **gesperrtes Gerät: widersprüchliche Doku** → auf dem Gerät testen |
| **Widgets** (WidgetKit) | Home (klein/mittel/groß), Sperrbildschirm (rund, rechteckig, Zeile), StandBy | Timeline, Neuladen aus der App, **Widget-Push** (iOS 26, `widgets`, budgetiert) | keine Live-Animation; Liquid-Glass-Darstellung beachten |
| **Steuerelemente** (iOS 18) | Kontrollzentrum, Sperrbildschirm unten, **Action Button** (mit Symbol in der Island) | Control-Push (`controls`) | ein Knopf oder Schalter |
| **Über das iPhone hinaus** | Watch Smart Stack, **CarPlay**-Dashboard (iOS 26, nur Anzeige), **Mac-Menüleiste** (macOS Tahoe, klickbar über iPhone-Spiegelung) | automatisch; Watch/CarPlay über `.supplementalActivityFamilies([.small])` | eigenes kleines Layout |
| **Geplante Aktivität** (iOS 26) | `request(…, startDate:)` – startet zu einer Uhrzeit | – | braucht eine Mitteilung beim Start |

**Push-Budget:** Priorität 10 zählt gegen ein (unveröffentlichtes) Stundenbudget, **Priorität 5
nicht**. `NSSupportsLiveActivitiesFrequentUpdates` hebt das Budget (abschaltbar durch den Nutzer).

## Parley-Momente und wo sie hingehören

### 1. „Deine Sessions arbeiten“ – die Parley-Aktivität

Eine einzige Live-Aktivität für ganz Parley (nicht eine pro Session), solange Unterwegs an ist
und mindestens eine Session lebt.

- **Compact links:** die Kugel (statisch) in der Farbe des wichtigsten Zustands – Akzent, wenn
  eine Session auf dich wartet; blau, wenn gearbeitet wird; grün, wenn alles bereit ist.
- **Compact rechts:** das Wichtigste in drei Zeichen: `2:18` (Timer der arbeitenden Session)
  oder `3` (aktive Sessions) oder ein Hörer, wenn ein Rückruf aussteht.
- **Minimal:** nur die Kugel in Zustandsfarbe.
- **Expanded:** bis zu drei Sessions als Zeilen (Name · Zustand · Timer), darunter Parleys
  letzte Zeile; unten „Parley anrufen“ und „Stumm“.
- **Sperrbildschirm / Watch / CarPlay / Mac-Menüleiste:** dieselben Kacheln, kompakt.
- **Aktualisierung:** der Mac schickt bei jedem Zustandswechsel einen `liveactivity`-Push mit
  **Priorität 5** (budgetfrei); Priorität 10 nur, wenn eine Session auf dich wartet. Timer laufen
  von allein – keine Pushes im Sekundentakt.
- **8-Stunden-Grenze:** Parley-Tage sind länger. Der Mac beendet die Aktivität nach ~7,5 h und
  startet per Push-to-Start sofort eine neue – für dich sieht es durchgehend aus.
- **Start ohne App:** Push-to-Start, sobald die erste Session arbeitet; Ende, wenn alle fertig
  oder gestoppt sind oder Unterwegs ausgeht.

### 2. „Parley möchte etwas wissen“ – Antworten ohne die App (Stumm-Modus)

Die Frage erscheint als Update mit Hinweis (Island fährt kurz auf, Sperrbildschirm-Banner) – mit
**Antwort-Knöpfen aus den Vorhersagen** (`<reply>`): „Ja, taggen“, „Anders“ … Ein Tipp schickt
die Antwort (`say`) über einen `LiveActivityIntent` aus dem App-Prozess an die Session;
„Antworten…“ öffnet die Session zum Tippen. Dafür schickt der Mac die Vorhersagen mit (heute
bleiben sie auf dem Mac). **Offen:** ob die Knöpfe bei gesperrtem iPhone sofort gehen oder erst
nach Face ID – Apples Doku widerspricht sich, das testen wir auf dem Gerät.

### 3. Rückruf und „später“

- „Rückruf in 0:45“ als Countdown in der Island (zählt selbst), Knöpfe „Jetzt anrufen“ /
  „Ich rufe zurück“.
- „Wartet auf deinen Rückruf“ mit Knopf „Rückrufen“ – auch auf Watch, CarPlay, Mac sichtbar.
- „Pausiert · noch 4:07“ für „Warte X Minuten“.

### 4. Während eines Anrufs

Ein CallKit-Anruf belegt die Island selbst (grüner Hörer). Unsere Aktivität könnte im
Sperrbildschirm und im *expanded*-Zustand die **Live-Untertitel** und den Folientitel zeigen –
lokal aus der App, die während des Anrufs ohnehin läuft. **Nicht dokumentiert:** wie das System
Anruf und eigene Aktivität anordnet – erst ein Gerätetest, dann entscheiden.

### 5. Widgets

- **Klein:** Kugel + „3 aktiv“ + der dringendste Zustand („Shirts wartet“).
- **Mittel:** vier Session-Kacheln mit Zustand und Timer, Knopf „Fortsetzen“ an pausierten.
- **Groß:** Kacheln + „Heute“ (Kosten, Updates, 5-h-Limit) + „Parley anrufen“.
- **Sperrbildschirm:** rund = Ring mit 5-h-Limit oder Anzahl aktiver Sessions, rechteckig =
  „Shirts · arbeitet 2:18“, Zeile = „3 aktiv · 42 % Limit“.
- **StandBy** (nachts quer am Ladegerät): das große Widget, ruhig.
- Aktualisiert über Widget-Push vom Mac (budgetiert, „irgendwann bald“) plus Neuladen, wenn die
  App ohnehin Daten bekommt.

### 6. Steuerelemente – der schnellste Weg

- **„Parley anrufen“** im Kontrollzentrum, unten auf dem Sperrbildschirm und auf dem **Action
  Button** (die Island zeigt dabei das Symbol): ein Druck, und du sprichst mit Parley.
- **„Unterwegs“** und **„Stumm“** als Schalter; ein Umschalten kann über `LiveActivityIntent`
  gleich die Parley-Aktivität starten oder beenden.

## Technik

- **Neues Ziel:** Widget-Extension `ParleyWidgets` (WidgetKit + ActivityKit + Controls) im
  `ios/project.yml`; gemeinsamer Code: Palette/Farben, Session-Modell, Kugel als statisches Bild
  (Island und Widgets können keine Dauer-Animation).
- **App-Gruppe** `group.de.developaway.parley`: die App legt den letzten Session-Stand und die
  Palette dort ab, Widgets lesen ihn; `WidgetCenter.reloadTimelines` bei jedem neuen Stand.
- **ActivityAttributes** `ParleyActivity` mit `ContentState` (≤ 4 KB, Standard-JSON): Sessions
  (Name, Zustand, seit/bis), Fokus-Session, letzte Zeile, Rückruf, Modus, Vorhersagen.
- **Push-Tokens:** die App meldet Push-to-Start-Token (`pushToStartTokenUpdates`) und je
  Aktivität den Update-Token (`pushTokenUpdates`, kann wechseln) über das Relay an den Mac
  (neue `push`-Arten). Mac und Windows senden `apns-push-type: liveactivity` an
  `de.developaway.parley.mobile.push-type.liveactivity` (`event` start/update/end, `timestamp`,
  `content-state`) – derselbe APNs-Schlüssel wie heute. Broadcast-Kanäle brauchen wir nicht
  (ein Nutzer, ein Gerät).
- **Knöpfe:** `LiveActivityIntent`s im App-Prozess, schicken die bekannten Relay-Frames (`say`,
  `resume`, Anruf starten).
- **Info.plist:** `NSSupportsLiveActivities`, `NSSupportsLiveActivitiesFrequentUpdates`;
  Push-Fähigkeit auch für die Extension (Widget-Push).
- **Testen:** Live-Aktivitäten laufen im Simulator, Pushes dorthin gehen auf Apple-Silicon-Macs;
  Konsole: `liveactivitiesd`, `apsd`, `chronod`. CarPlay über den CarPlay-Simulator.

## Vorschlag zur Reihenfolge

1. **Steuerelemente** (Anrufen, Unterwegs, Stumm; Action Button) – klein, sofort nützlich.
2. **Parley-Aktivität** (Moment 1) mit Push vom Mac und von Windows – das Herzstück, inklusive
   der 8-Stunden-Ablösung.
3. **Rückruf/Später/Pausiert** in derselben Aktivität (Moment 3).
4. **Antworten ohne App** im Stumm-Modus (Moment 2) – nach dem Sperr-Test der Knöpfe.
5. **Widgets** (Moment 5).
6. **Untertitel im Anruf** (Moment 4), nach einem Test, wie sich Anruf und Aktivität vertragen.
