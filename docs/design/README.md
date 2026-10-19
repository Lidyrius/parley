# Parley Design

Arbeitsordner für die Design-Iteration.

## Struktur

```
design/
  bestandsaufnahme-2026-10-18/   Collagen des Ist-Stands (ios-hell.png, ios-dunkel.png)
  screens/<plattform>/<NN-screen>/
    00-ist-hell.png              Ist-Stand, hell
    00-ist-dunkel.png            Ist-Stand, dunkel
    01-…, 02-…                   Entwürfe/Iterationen, fortlaufend nummeriert
    notizen.md                   Feedback und Entscheidungen (bei Bedarf)
```

Logos und App-Icons liegen unter `../logo/` (aktuell `final-v2`).

## Stand

- **iOS**: 19 Screens, hell + dunkel, aus dem Demo-Modus (`-demo`, `-demoCall <zustand>`) im Simulator
  „Parley Design“ per UI-Test aufgenommen. Index: `screens/ios/index.txt`.
- **macOS**: offen. Braucht Bildschirmaufnahme- und Bedienungshilfen-Freigabe für das Terminal.
- **Windows**: offen, nur auf einem Windows-Rechner möglich.
- Nicht erfasst: Live Activity / Sperrbildschirm, Widgets, QR-Scanner (Kamera).
