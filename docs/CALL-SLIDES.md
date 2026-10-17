# Konzept: Folien im Anruf („Schauen Sie, Sir …“)

Status: **Entwurf zur Besprechung** — nichts davon ist gebaut.

## Idee

Während Parley im Anruf spricht, zeigt die iPhone-App passend zum Gesagten Folien: einen
Screenshot der neuen Ansicht, eine kurze Textkarte („Gebaut: …“), einen Diff, einen Link.
„Hier, Sir, das ist der neue Export-Knopf — so sieht er aus. Und hier die PDF-Variante.
Was meinen Sie?“ Jede Folie erscheint genau in dem Moment, in dem sie erwähnt wird, und Sir
kann auf eine Folie antworten („die zweite gefällt mir nicht“).

## Wie Claude Folien angibt

Im gesprochenen Text, direkt an der Stelle, an der die Folie kommen soll — Parley entfernt die
Marker, bevor es spricht:

```
<speak>Ich habe den Export-Knopf eingebaut, Sir. <slide image="/tmp/export.png" title="Export-Knopf"/>
So sieht er aus. <slide text="Gebaut: CSV, Beträge mit Komma, Spalten wie in der Ansicht"/>
Gefällt Ihnen das?</speak>
```

Folienarten (erste Runde):
- `image` — ein Pfad auf dem Mac/PC (Screenshot, den Claude gerade gemacht hat) oder ein
  Bild aus dem Verlauf der Session (dieselben Bild-Schlüssel wie in der Session-Ansicht).
- `text` — eine kurze Karte (Titel + 1–4 Zeilen, Markdown light).
- später: `diff` (Datei + +/−-Zeilen), `link` (URL mit Vorschau), `code`.

## Timing — dieselbe Technik wie die Live-Untertitel

Die Untertitel kennen schon die Startzeit jedes Wortes (aus dem Audio, siehe
`Captions.swift`). Eine Folie hängt am Wort nach ihrem Marker → sie bekommt dessen Startzeit.
Der Host schickt vor der Zeile **einen** `slides`-Frame (Folien + Zeiten) und danach die Bilder
einzeln (verkleinert wie in der Session-Ansicht, `image`-Frames); das iPhone zeigt jede Folie,
sobald seine Abspiel-Uhr (gespielte Frames) ihre Zeit erreicht. Kein zusätzlicher Netzverkehr
während des Sprechens, kein Versatz durch Netz-Ruckeln.

## Darstellung im Anruf

- Die Folie nimmt die obere Hälfte des Anrufbildschirms ein (statt des großen Rings), die
  Untertitel bleiben darunter, die Wellenform schrumpft.
- Wischen zurück zu früheren Folien dieses Anrufs; Antippen → Vollbild mit Zoom.
- Nach dem Anruf bleiben die Folien in der Session-Ansicht am Verlauf hängen.
- Im Auto (CarPlay) keine Folien — nur Ton; die Folien warten dann in der App.

## Feedback zu einer Folie

- Sprechend: „Die zweite gefällt mir nicht“ → Parley gibt Claude den Hinweis mit, welche Folie
  gerade bzw. als N-te gezeigt wurde (`[Parley: Sir bezieht sich auf Folie 2 „Export-Knopf“]`).
- Tippend: Lange auf eine Folie drücken → „Dazu etwas sagen“ / Daumen hoch/runter → geht als
  getippte Antwort mit Folien-Bezug an die Session.

## Offene Fragen für dich

1. Sollen Folien **nur im Anruf** kommen oder auch, wenn Parley am Mac spricht (z. B. als
   Fenster/Benachrichtigung)?
2. Darf Claude **selbst Screenshots machen**, um sie zu zeigen (Simulator/Browser), oder nur
   vorhandene Bilder verwenden?
3. Wie viele Folien pro Zeile höchstens — eine, oder eine kleine Serie (Karussell)?
4. Soll die App nach dem Anruf eine **Zusammenfassung mit allen Folien** zeigen?
