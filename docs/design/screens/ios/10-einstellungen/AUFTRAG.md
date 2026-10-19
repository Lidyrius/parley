# Auftrag: iOS-Einstellungen – Erklärung pro Zeile (Variante A, freigegeben von Sir, 18.10.2026)

Betrifft `ios/ParleyMobile/SettingsView.swift`. Mockup: `01-vorschlag-a.png` (Quelle `vorschlaege.html`).
Ist-Stand: `00-ist-hell.png`, `00-ist-dunkel.png`, `../11-einstellungen-mitte/`.

Ziel: Die Textwand im Footer von „Anrufe“ verschwindet. Jede Zeile erklärt sich selbst in einer kurzen Unterzeile.

## 1. Abschnitt „Unterwegs“ (neu, eigener Abschnitt vor „Anrufe“)

| Symbol | Titel | Unterzeile | Steuerung |
|---|---|---|---|
| `car.fill` | Unterwegs-Modus | Updates klingeln als Anruf auf dem iPhone | Toggle |
| `bell.slash.fill` | Stumm | Statt Anruf eine Mitteilung – schriftlich antworten | Toggle (weiter nur aktiv, wenn Unterwegs an) |
| `moon.fill` | Automatisch mit Fokus | „Fahren“ schaltet Unterwegs ein | NavigationLink |

„Automatisch mit Fokus“ öffnet eine kleine Seite mit der Anleitung aus dem alten Footer:
Einstellungen → Fokus → z. B. „Fahren“ → Fokusfilter → Parley; oder Kurzbefehle → Automation
(CarPlay verbunden, Zuhause verlassen) → Aktion „Unterwegs“.

## 2. Abschnitt „Anrufe“

| Symbol | Titel | Unterzeile | Steuerung |
|---|---|---|---|
| `speaker.wave.2.fill` | Lautsprecher | AirPods und Auto bleiben, wie sie sind | Toggle |
| `phone.down.circle` | Danach auflegen | Musik läuft gleich weiter | Toggle |
| `hand.raised` | Unterbrechen | Reden oder „Stopp“ – Parley hört zu | Toggle |
| `rectangle.stack.badge.person.crop` | Fragerunde | Updates sammeln, solange andere arbeiten | Picker (Wert rechts) |

Footer nur noch ein Satz: „„Hey Siri, Parley anrufen“ geht jederzeit, auch in CarPlay.“

Umsetzung: `Label { VStack(alignment: .leading) { Text(titel); Text(unterzeile).font(.footnote).foregroundStyle(.secondary) } } icon: { Image(systemName:) }`.
Unterzeile darf bei großer Schrift umbrechen.

## 3. Darstellung

- App-Symbol-Zeile zeigt die neuen P-Echo-Icons (Graphit, Porzellan, Indigo, Petrol; Standard Graphit) –
  siehe `docs/logo/final-v2/AUFTRAG.md`, falls noch nicht umgesetzt.
- Rest von „Darstellung“, Verbindung, Entwickler, Version bleibt wie heute.

## 4. App-Symbol: Standard Graphit (alle Plattformen)

Commit `c1da449` hat Porzellan als Standard gesetzt; gewünscht war **Graphit** (`docs/logo/final-v2/AUFTRAG.md`).
- iOS: primäres `AppIcon` = Graphit, Porzellan wird Alternate Icon; `AppIconRow` Standardwahl Graphit.
- macOS: `app/Sources/Parley/AppIcon.swift` `saved … ?? .graphit`, Bundle-Icon (`app/AppIcon/Parley.icon`) = Graphit;
  `applicationIconImage = nil` dann für `.graphit` statt `.porzellan`.
- Windows: Standard Graphit (Tray + `Parley.ico` der .exe).
- Wer schon bewusst etwas gewählt hat, behält seine Wahl.

## 5. Kontrast: aktive Kapseln im Dunkelmodus (Bug, von Sir gemeldet)

„Unterwegs“ und „Stumm“ aktiv zeigen im Dunkelmodus weiße Schrift auf weißem/hellem Grund – wenn die Palette einen
hellen Akzent hat. Ursache: `OverviewView.swift` `PillToggleStyle` setzt `.foregroundStyle(configuration.isOn ? .white : .secondary)`
auf `Theme.claude`.
- Fix: `Theme.onAccent` statt `.white` (gibt es schon, wird in `SessionCard`/`PairingView` genutzt).
- Gleich mitprüfen, harte `.white` auf Akzentflächen: `SnapshotsSheet.swift:254`, `PaletteEditor.swift:157`
  (Scanner/Demo-Titel sind auf Kamera/Bild und bleiben weiß).
- Alle Paletten hell + dunkel durchsehen (Kapseln, Knöpfe „Fortsetzen“/„Rückrufen“, Anrufen, Segment Raster/Liste);
  Android-Pendant (gleiche Kapseln) ebenso.

## Rahmen

- Punkte 1–3 nur iOS; Punkt 4 iOS + macOS + Windows; Punkt 5 iOS + Android.
- Hell und Dunkel prüfen; Screenshots danach hier als `10-umgesetzt-hell.png` / `10-umgesetzt-dunkel.png`.
- Kein Release, bis Sir es sagt.
