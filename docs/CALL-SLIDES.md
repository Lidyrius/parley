# Konzept: Folien im Anruf („Schauen Sie, Sir …“)

Status: **v1 gebaut** (Bild, Diagramm, Kennzahl, Textkarte; Timing über die Untertitel-Uhr).
Alles unter „Später“ ist noch Entwurf zur Besprechung.

## Idee

Während Parley im Anruf spricht, zeigt die iPhone-App passend zum Gesagten Folien: einen
Screenshot der neuen Ansicht, eine kurze Textkarte („Gebaut: …“), einen Diff, einen Link.
„Hier, Sir, das ist der neue Export-Knopf — so sieht er aus. Und hier die PDF-Variante.
Was meinen Sie?“ Jede Folie erscheint genau in dem Moment, in dem sie erwähnt wird, und Sir
kann auf eine Folie antworten („die zweite gefällt mir nicht“).

## Durchgespielt: wann Folien wirklich helfen

1. **„So sieht es aus“** — Claude hat eine Ansicht gebaut und im Simulator/Browser einen
   Screenshot gemacht. `image="last"` zeigt genau diesen, ohne Pfad-Gefummel. Der häufigste Fall.
2. **Zahlen, die man nicht hören will** — Testergebnisse, Ladezeiten vorher/nachher, Kosten der
   Woche, Fehler pro Tag. Gesprochen nervt eine Zahlenreihe; als Balken/Linie ist sie in einer
   Sekunde klar. → `chart`.
3. **Die eine Zahl** — „24 von 24 Tests grün“, „Antwortzeit 180 ms (−40 %)“. Groß, sofort lesbar
   auch im Augenwinkel. → `metric`.
4. **Zusammenfassung zum Mitlesen** — drei Punkte, was gebaut wurde; die Stimme bleibt kurz,
   die Karte hält die Details. → `text`.
5. **Entscheidungen** („A oder B?“) — zwei Screenshots nacheinander, dann die Frage. Später mit
   Antippen der Variante als Antwort.

Wo es nicht hilft: im Auto ohne Blick aufs Display (CarPlay), bei reinen Rückfragen ohne Inhalt,
und wenn der Satz ohne die Folie keinen Sinn mehr ergibt — die Stimme muss allein tragen.

## Wie Claude Folien angibt

Im gesprochenen Text, direkt an der Stelle, an der die Folie kommen soll — Parley entfernt die
Marker, bevor es spricht:

```
<speak>Ich habe den Export-Knopf eingebaut, Sir. <slide image="last" title="Export-Knopf"/>
So sieht er aus. <slide chart="bar" labels="Mo,Di,Mi" values="12,18,9" title="Exporte"/>
Und so oft wurde er schon benutzt. Gefällt Ihnen das?</speak>
```

Folienarten (v1, gebaut):
- `image` — `last` / `last-2` = neuestes Bild im Verlauf der Session (Screenshots), oder ein
  Bildpfad auf dem Mac/PC. Verkleinert wie in der Session-Ansicht; Antippen = Vollbild.
- `chart` — `bar`, `line`, `pie` mit `labels`, `values`, optional `unit` (Swift Charts).
- `metric` — eine große Zahl plus `note`.
- `text` — kurze Karte (Titel + Text, Inline-Markdown).

Später: `diff` (Datei + +/−-Zeilen), `link` (URL mit Vorschau), `code`, Auswahl-Karten.

Technik v1: Der Stop-Hook schneidet die Marker aus dem Sprechtext und merkt sich das Wort
dahinter; der Host gibt jeder Folie dessen Startzeit aus den Untertiteln und schickt vor der
Zeile einen `slides`-Frame, die Bilder danach als `image`-Frames (Schlüssel = Folien-ID). Das
iPhone zeigt die fällige Folie an Stelle des großen Rings, über Wellenform und Untertiteln; sie
bleibt stehen, bis die nächste Zeile beginnt.

## Timing — dieselbe Technik wie die Live-Untertitel

Die Untertitel kennen schon die Startzeit jedes Wortes (aus dem Audio, siehe
`Captions.swift`). Eine Folie hängt am Wort nach ihrem Marker → sie bekommt dessen Startzeit.
Der Host schickt vor der Zeile **einen** `slides`-Frame (Folien + Zeiten) und danach die Bilder
einzeln (verkleinert wie in der Session-Ansicht, `image`-Frames); das iPhone zeigt jede Folie,
sobald seine Abspiel-Uhr (gespielte Frames) ihre Zeit erreicht. Kein zusätzlicher Netzverkehr
während des Sprechens, kein Versatz durch Netz-Ruckeln.

## Darstellung im Anruf

- v1: Die Folie nimmt den Platz des großen Rings ein, Wellenform und Untertitel bleiben
  darunter; Antippen eines Bildes → Vollbild mit Zoom.
- Später: Wischen zurück zu früheren Folien dieses Anrufs; nach dem Anruf hängen die Folien in
  der Session-Ansicht am Verlauf; im Auto (CarPlay) nur Ton, die Folien warten in der App.

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
