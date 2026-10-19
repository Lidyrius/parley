# Auftrag: Willkommen/Kopplung + Scanner neu (freigegeben von Sir, 19.10.2026)

Betrifft `ios/ParleyMobile/PairingView.swift`, `ScannerView.swift` und das Android-Pendant
(`android/.../ui/PairingScreen.kt`, gleiche Gestaltung). Ist: `00-ist-*.png`. Verlauf: `notizen.md`.

## 1. Willkommen – Variante A2 „Silhouetten-Echo“ (`02-a2.png`, Quelle `a-verfeinert.html?v=1`)

- Statt `AppMark` (Wellen-Symbol auf Clay) das **echte App-Icon** (gewähltes Icon, Standard Graphit), 128 pt,
  Eckradius 22,5 %, Schatten.
- Dahinter 5 Konturen **in Icon-Form** (abgerundetes Quadrat, gleiche Rundung 22,5 %, `.continuous`), zentriert auf
  das Icon: 176 / 232 / 300 / 380 / 470 pt, Clay, Deckkraft .50 / .34 / .22 / .13 / .07, Linie 2 → 1 pt.
  Dürfen über den Rand laufen. Statisch (Bewegung gibt es im Scanner).
- Text zentriert: „Guten Tag, Sir.“ (largeTitle bold), darunter „Ein Code vom Mac, und Ihre Sessions sind hier.“
- Eine Hinweiszeile als Karte: Symbol `desktopcomputer` in Clay-Kachel, „Auf dem Mac“ /
  „Parley-Menü → „Handy verbinden…““. Die alte 3-Schritte-Karte entfällt.
- Knopf „Code scannen“ (`qrcode.viewfinder`, groß, Kapsel, Clay, Text `Theme.onAccent`).
- Darunter Textknopf „Link einfügen“ (`doc.on.clipboard`): liest die Zwischenablage (`PasteButton`/`UIPasteboard`);
  das Textfeld verschwindet aus dem Start-Screen. Fehler wie heute als rote Zeile darunter.
- Fußzeile klein: Schloss + „Verschlüsselt · nur Ihr Mac und Ihr iPhone“.
- Sie-Form überall.

## 2. Scanner – Variante B2 „Kamera als Kachel“ mit Wellen (`04-scanner-b2-final.png`, Quelle `scanner.html?v=2`)

- Kein Vollbild mehr: normaler Screen (`Theme.background`), oben rechts runder Schließen-Knopf (`xmark`).
- Titel links „Code scannen“, Untertitel „Halten Sie das iPhone auf den Code am Mac.“
- Kamera (`DataScanner` / Fallback wie heute) in einer **Kachel in Icon-Form**, ca. 290 pt, Eckradius 22,5 %,
  Rand 2,5 pt Clay, Schatten.
- **Animation:** Die Kachel-Silhouette läuft als Welle nach außen – dieselbe Logik wie die Anruf-Wellen
  (`Ringing.swift`, Stil `.ripples`: zwei Schläge pro Zyklus, Lebensdauer ~2 s, ausbremsend, verblassend,
  dünne Clay-Linie + ganz leichte Fläche), nur mit `RoundedRectangle(cornerRadius: 22,5 %, style: .continuous)` statt
  Kreis; wächst bis ca. 1,6 × und verschwindet. Gern die vorhandenen Ripple-Knobs wiederverwenden.
  Läuft, solange gesucht wird; Reduce Motion → keine Wellen.
- Darunter Karte „Kein Code zu sehen?“ / „Mac: Parley-Menü → „Handy verbinden…““ (`menubar.rectangle`).
- Unten: Kapsel „Link einfügen“ + runder Taschenlampen-Knopf (`flashlight.on.fill`, nur wenn Gerät Licht hat).
- **Erkannt** (Gestaltung wie `02-scanner-erkannt.png`, aber in der Kachel): Rand grün, Häkchen in der Kachel, Wellen
  stoppen, darunter „Verbunden, Sir.“ + Mac-Name · Anzahl Sessions; nach ~1,5 s automatisch zur Übersicht.
- **Ohne Kamera-Erlaubnis** (`02-scanner-ohne-kamera.png`): gestrichelte Kachel mit Kamera-Symbol,
  „Kamera ist aus“ / „Parley braucht sie nur für diesen einen Code.“, Knopf „Kamera erlauben“ (Einstellungen öffnen),
  „Stattdessen Link einfügen“.

## Rahmen

- iOS + Android gleich; Mac/Windows nicht betroffen.
- Hell und Dunkel prüfen (Konturen in Hell etwas kräftiger); Screenshots danach hier als `10-umgesetzt-*.png`.
- Kein Release, bis Sir es sagt.
