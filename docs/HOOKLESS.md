# Ohne Stop-Hook — die Mod trägt den Zug (Claude Code)

Bisher hält `plugin/scripts/stop-hook.sh` den Zug offen, solange er in der Warteschlange steht,
gesprochen wird, wartet oder geparkt ist. Claude Code zeigt die Session dann als „arbeitet“ und
nimmt keine Eingabe an. Mit der Mod (plugin-ui) läuft der Zug jetzt ohne Blockieren: die Mod
schickt ihn ab, kehrt sofort zurück, und die Antwort kommt später als Eingabe. Codex (keine Mods)
und eine Session ohne Mod behalten den Hook unverändert.

## Vertrag (macOS und Windows gleich)

- `GET /health` → `{"ok":true,"async":1}`. Ohne `async` nimmt die Mod den alten Weg (`next(e)`).
- `POST /turn` mit `"async":true` und `"turn_id":"<session>:<n>"` (sonst wie bisher): der Host
  reiht den Zug ein und antwortet sofort `{"queued":true}`. Was danach herauskommt:
  - Transkript → eine Zustellung (siehe /presence),
  - `wait` → `waitUntil`/`waitResume` wie bisher; ein Timer im Host macht `waitResume` bei Ablauf
    zur Zustellung („Fortsetzen“ vorher: der endWait-Text),
  - `park` → nichts (eine ruhende Session mit frischer Presence gilt als geparkt und fortsetzbar),
  - leer (`<speak-end>`, Stille) → nichts.
  Ein neuer `/turn` derselben Session verwirft ihre älteren, noch wartenden Züge.
- `POST /presence` (alle 2 s, während `awaiting` oder einer offenen Zustellung alle 0,5 s):
  - Body neu: `"async":1` (diese Mod trägt Züge selbst), `"awaiting":"<turn_id>"` (falls offen),
    `"ack":"<delivery_id>"` (die zuletzt eingespeiste Zustellung).
  - Antwort: `{"instruction":"…","delivery_id":"…"}` solange eine Zustellung offen ist. Sie bleibt
    offen, bis ihr `ack` kommt; ohne ack nach 10 s erneut. Die Mod speist jede `delivery_id` nur
    einmal ein. `{"unknown_turn":true}`, wenn `awaiting` dem Host unbekannt ist (Neustart) — die
    Mod gibt das Warten dann auf.
- `POST /turn/cancel` `{"session_id","turn_id"}`: Sir hat selbst getippt, bevor die Sprachantwort
  da war — der Zug fliegt aus der Warteschlange; läuft er schon, wird die Aufnahme verworfen und
  nichts zugestellt.
- `POST /close` `{"session_id"}` beim Ende der Session (Mod, `session.end`): Warteschlange und
  Zustellungen dieser Session weg.
- `GET /mod?session_id=…` → `{"live":true}`, wenn diese Session eine Mod mit `async` hat und ihre
  Presence jünger als 5 s ist. `stop-hook.sh` fragt das zuerst und tritt dann sofort zur Seite
  (exit 0) — falls Claude Code den Hook trotz der Mod aufruft.

## Mod

- `classic.Stop`: `<speak>` erkannt, Host kann `async` → `/turn` mit `async`, `awaiting` setzen,
  Phase „queued“, sofort `{}` zurück (kein `next`). Sonst wie bisher `next(e)`.
- Ohne Eingabefeld (`-p`, SDK) → `next(e)`: der Prozess endet nach dem Stop.
- Zustellung → `$.prompt.submit({text, asUser:true})`, einmal je `delivery_id`, dann `ack`.
- Sir tippt (`prompt.submit` vom Nutzer) während `awaiting` → `/turn/cancel`.
- `session.end` → `/close`. Die Presence-Schleife lebt nach einem Hot-Reload wieder auf.

## Präzisierungen (aus der macOS-Umsetzung — Windows bitte gleich)

- `POST /close`: nur `{"session_id"}` (ohne `id`/`ids`/`project`) ist das `session.end` der Mod —
  der Prozess wird nicht angefasst. `{"id"}`/`{"ids"}`/`{"project"}` beenden wie bisher die Session.
- `delivery_id` geht nur an eine Presence mit `"async":1`; eine ältere Mod (ohne `async`) bekommt
  `{"instruction"}` wie bisher genau einmal. Alles, was bisher per Presence zugestellt wurde
  (Fortsetzen, geroutete Nachrichten, Gäste, Wachhund, Wiedervorlage, `/dispatch` per Ordner),
  läuft über denselben Zustellweg.
- Während `wait` bleibt die `turn_id` bekannt (kein `unknown_turn`); `/turn/cancel` in der
  Wartezeit beendet sie ohne Zustellung. Bei `transcript`, `park`, leer ist sie danach unbekannt
  (die Antwort mit der Zustellung trägt dann auch `unknown_turn`).
- `/turn/cancel` → `{"ok":true}`, oder 404, wenn der Zug nicht (mehr) offen ist. Läuft er schon,
  spricht/hört der Dialog zu Ende; nur sein Ergebnis wird verworfen.
- Ein async-Zug mit `park` setzt kein `parked` für `/wake` (kein Hook pollt): die Session ist über
  ihre Presence geparkt, Fortsetzen geht an die Mod.
- `GET /mod` → `{"live":true}` oder `{"live":false}`. `stop-hook.sh` fragt erst, wenn es ein
  `<speak>` gefunden hat (ohne Tag ruft es die App weiterhin nicht).
- Die Mod meldet `async:1` nur mit Eingabefeld (`session.start` → `isInteractive`) und wenn
  `/health` `async:1` sagt; sonst `next(e)`. `<speak-end>` ohne Close nimmt sie wie der Hook.
