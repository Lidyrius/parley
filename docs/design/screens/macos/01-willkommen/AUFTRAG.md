# Auftrag: Onboarding neu im Stil „Logo mit Echo“ (freigegeben von Sir, 19.10.2026)

Betrifft `app/Sources/Parley/Onboarding.swift` (+ `TutorialClips.swift`) und **das Windows-Pendant im selben Change**
(Cross-platform-Regel). Mockups: `a-alle-schritte.html`, Bilder `03-schritt-01.png` … `03-schritt-10.png`,
Übersicht `03-alle-schritte.png`. Logo: `docs/logo/final-v2/` (Graphit, Dark-Rendering).

## Gestaltung (alle Schritte)

- Echo-Motiv: Kopf-Symbol in einem runden Badge mit drei konzentrischen Ringen (Clay, abnehmende Deckkraft),
  ersetzt das heutige 60-pt-Quadrat. Schritt 1 und 10 zeigen statt Symbol das App-Icon groß.
- Untertitel höchstens eine Zeile, Sie-Form / „Sir“ wie JARVIS.
- Fortschritt: 10 Punkte, erledigte in gedämpftem Clay.

## Ablauf (10 Schritte)

1. **Willkommen** – Icon mit Ringen, „Guten Tag, Sir.“, „Parley spricht Claude Codes Antworten – und hört Ihre.“,
   Knopf „Einrichten · 2 Min.“
2. **Wo soll Parley laufen?** – Claude Code / Codex als Karten, erkannte vorausgewählt, Badge „erkannt“.
3. **Zwei Schlüssel** – je Karte: Name, Hinweis, „Konsole öffnen“, Feld. **Prüfen automatisch beim Einfügen**
   (Debounce), eigener Prüfen-Knopf entfällt; Status „gültig“ grün.
4. **Sprache & Stimme** – zwei Picker, darunter Hörprobe mit Play + Wellenform.
5. **Benachrichtigungen** – drei Karten (Pill / Mitteilung / Keine) mit Mini-Vorschau.
6. **Berechtigungen (neu, ersetzt „Mikrofon“)** – eine Liste, jede Zeile mit Live-Status (erlaubt / „macOS fragt …“ / Erlauben):
   - Mikrofon (Pflicht)
   - Spracherkennung – für Reinreden/Barge-in (`SFSpeechRecognizer`)
   - Mitteilungen (nur wenn in Schritt 5 nicht „Keine“)
   - Terminal steuern – Automation/Apple Events für „Terminal“ (Zentrale startet/schließt Sessions)
   - Musik pausieren – optional
   Knopf **„Alle erlauben“** ruft die Abfragen nacheinander auf. Abgelehnte Zeile: „Systemeinstellungen öffnen“
   (Deep-Link in die passende Datenschutz-Seite). Weiter erst, wenn Mikrofon erlaubt.
   Windows: Mikrofon + Benachrichtigungen; die übrigen Zeilen entfallen dort.
7. **Parley aufs Handy – Relais (neu, überspringbar mit „Später“)** – zwei Karten:
   - **Eigenes Relais · 1 Klick**: Parley führt `wrangler login` aus (Browser, Sir bestätigt nur), dann
     `wrangler deploy` für `relay/`, liest die Worker-URL aus, schreibt `relayUrl` in `credentials.json` und prüft
     „parley relay ok“. Fortschritt als Häkchen-Liste (angemeldet → bereitgestellt → geprüft).
     Ohne Node.js: Hinweis + Rückfall auf „Deploy to Cloudflare“-Link und Adressfeld.
   - **Adresse einfügen**: Feld für eine vorhandene Relay-URL, gleiche Prüfung.
8. **iPhone koppeln (neu)** – QR-Code **im Fenster** (nicht im Browser) aus `RelayLink`/Pairing; Hinweise
   „Öffnet Parley oder lädt es“, „Verschlüsselt, nur Ihr Raum“, „Android genauso“. Status „Warte auf Ihr Handy …“;
   sobald das Handy im Raum ist → „Verbunden mit <Gerät>“ und automatisch weiter. Ein Code für beides wäre ideal
   (Seite am Relay: App installiert → `parley://pair…`, sonst TestFlight/APK) – falls zu aufwendig, erst nur Koppeln.
   Wenn Schritt 7 übersprungen wurde, entfällt 8.
9. **Kurze Probe** (Tutorial) – Zitat des gesprochenen Satzes, „Probe n von m · Titel“, Ausprobieren + Ergebniszeile.
   Vorschlag: Tutorial um **Wiedervorlage** („ruf mich in zwei Minuten zurück“) ergänzen, und – wenn gekoppelt –
   **Unterwegs** kurz erklären. `TutorialClips.version` erhöhen.
10. **Bereit, Sir.** – Icon mit Ringen, Befehle `/parley:voice` / `$parley-voice` mit „Kopieren“.

## Rahmen

- macOS bauen und durchklicken (Onboarding erzwingen über DevTools/„Onboarding neu starten“); Windows-Code dazu,
  per `windows-build`-CI kompilieren.
- Screenshots danach hier als `10-umgesetzt-*.png`.
- Kein Release, bis Sir es sagt.
