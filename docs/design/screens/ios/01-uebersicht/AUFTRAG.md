# Auftrag: iOS-Übersicht neu (Design freigegeben von Sir, 18.10.2026)

Betrifft `ios/ParleyMobile/OverviewView.swift` und `SessionCard.swift`. Nur iOS (Mac/Windows haben keine Übersicht dieser Art).
Mockups liegen hier im Ordner; Ist-Stand: `00-ist-hell.png`, `00-ist-dunkel.png`.

## 1. Kopfzeile in einer Reihe (`05-kopfzeile-final.png`)

- Status-Kapsel sagt im verbundenen Zustand nur „Verbunden“ statt „Mac verbunden“.
- Rechts daneben „Unterwegs“ und, wenn Unterwegs an ist, „Stumm“ – beide mit Text, Symbole wie heute
  (`car.fill`, `bell.slash.fill`), `PillToggleStyle` bleibt.
- Mit beiden Schaltern ~360 pt von 370 pt. Der vorhandene `ViewThatFits`-Rückfall (zweite Reihe) bleibt für
  große Systemschrift.

## 2. Kennzahlen als eine Karte (C2, `03-c2-raster-liste.png`)

- Eine Karte: Kosten heute · Updates · gesprochen als große Zahlen nebeneinander.
- Darunter 5-h-Limit und Woche als schmale Balken mit Prozent rechts.
- Ersetzt die heutige Textzeile „Heute $13.61 Kosten · …“.

## 3. Sessions: Raster oder Liste umschaltbar

- Kopf: „Sessions“ + Anzahl, daneben ein kleines Segment (Raster/Liste, SF Symbols `square.grid.2x2` / `list.bullet`),
  rechts „Anrufen“. Wahl per `@AppStorage` merken; Standard: Raster.
- **Raster**: zwei Spalten, alle Karten gleich hoch. Inhalt: Zustandssymbol + Zeit, letzter Satz (2 Zeilen, kursiv),
  Name, Zustand in Zustandsfarbe, höchstens ein Knopf (Fortsetzen/Rückrufen) in eigener Zeile.
  Sprechende Session zeigt statt Satz eine kleine Wellenform.
- **Liste**: eine Zeile pro Session: Symbol, Name, Zustand, Zeit rechts, letzter Satz einzeilig, Knopf nur wenn nötig.

## 4. Karten-Zustände (`02-c-details.png`, links)

Alle acht Zustände (spricht, wartet auf Rückruf, pausiert, arbeitet, Hintergrund, geparkt, bereit, gestoppt) in
gleicher Kartenhöhe; unterschieden nur über Symbol, Farbe und höchstens eine Aktion.

## 5. Blatt statt Aufklappen (`02-c-details.png`, rechts)

Tippen auf eine Karte öffnet ein Sheet (mittlere Höhe) statt sie im Raster aufzuklappen:
Kopf mit Symbol, Name, Zustand · seit; Agent-Aufgabe (falls vorhanden); Kacheln Laufzeit, Kosten,
Updates · Antworten, Kontext mit Balken; „Zuletzt gesagt“; Knöpfe „Verlauf öffnen“ (bisherige SessionView) und
„Nachricht“.

## Rahmen

- Großer „Parley anrufen“-Knopf entfällt; „Anrufen“ sitzt im Sessions-Kopf.
- Farben/Paletten wie bisher über `Theme`; Hell und Dunkel prüfen (Mockups zeigen beide).
- Demo-Modus (`-demo`) muss alle Zustände weiter zeigen – Screenshots danach in diesen Ordner als `10-umgesetzt-*.png`.
- Kein Release, bis Sir es sagt.
