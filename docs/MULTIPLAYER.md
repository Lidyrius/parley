# Multiplayer — geteilte Sessions

Sir teilt eine Session mit einem Gast. Der Gast folgt ihr auf dem Handy, schreibt mit und bekommt
die Rückfragen seines Bereichs. Entwurf: `docs/design/screens/ios/60-multiplayer/`.
Protokoll: `docs/IPHONE.md` → v7.

## Stand (Teil 1, erledigt)

- [x] Freigabe = eigener Relay-Raum mit eigenem Schlüssel; der Host hält eine Verbindung je Freigabe.
- [x] Einmal-Link (24 h), Gast nennt seinen Namen, Sir lässt ihn herein (Rolle, Lesen/Schreiben oder
      nur zuhören, Verlauf ab Beitritt, eigene Rolle), danach Umzug in einen frischen Raum.
- [x] Gast sieht nur seine Session; Verlauf ab Beitritt; Nachrichten mit Namen markiert.
- [x] Die Session erfährt Teilnehmer, Rollen und dass Freigaben bei Sir bleiben.
- [x] Übersicht „geteilt mit …“, Verlauf mit Sprecher (iPhone).

## Sicherheit — niemand außer dem Gast liest mit

- [ ] **S1 Umzug nur für den eingeladenen Gast.** Wer den Link ebenfalls hat, hört im Einladungsraum
      mit und könnte dem Umzug folgen. Lösung: Der Gast schickt beim Beitritt einen frischen
      öffentlichen Schlüssel (P-256); der Host verschlüsselt die neuen Raumdaten per ECDH + HKDF nur
      für diesen Schlüssel. Fremde Geräte im Einladungsraum können sie nicht lesen.
- [ ] **S2 Ein Beitritt pro Link.** Fragt schon jemand, werden weitere Anfragen ignoriert (geloggt);
      nach Ja oder Nein ist der Einladungsraum geschlossen.
- [ ] **S3 Sir sieht, wer fragt.** Name und Gerät des Gastes in der Anfrage; ein vierstelliger
      Prüfcode, den beide Seiten sehen (aus dem Schlüssel des Gastes abgeleitet), damit Sir am Telefon
      gegenprüfen kann.
- [ ] **S4 Keine Identitäts-Täuschung.** Gast-Text wird entschärft: „[Parley]“, „[Nachricht von …]“,
      „[Antwort von …]“ und `<speak` im Text werden neutralisiert, der Name ohne Klammern/Zeilenumbrüche.
- [ ] **S5 Strikte Grenzen.** Der Gast erreicht nur: seine Session (Verlauf, Bilder, Nachricht),
      Antworten auf seine Rückfragen, seinen Push-Token. Nichts anderes (Anrufe, Fortsetzen, Zentrale,
      Snapshots, andere Sessions) — geprüft und getestet.
- [ ] **S6 Missbrauchsbremse.** Höchstens eine Nachricht pro 2 s und 8000 Zeichen; Rückfragen-Antworten
      nur auf offene Rückfragen.
- [ ] **S7 Schlüssel sicher ablegen.** Host: shares.json nur für den Nutzer lesbar (0600) — erledigt;
      Gast: Keychain — erledigt. Nichts Geheimes im Log.
- [ ] **S8 Entfernen wirkt sofort.** Sir entfernt den Gast → Ende-Frame, Verbindung zu, Raum aufgegeben,
      Gast löscht Schlüssel. Auch vom Mac-Menü / Windows-Tray aus.

## Rückfragen an den Gast (Teil 2)

- [ ] **R1 Adressat.** Die Session schreibt `<speak to="Max">…</speak>`; der Stop-Hook gibt `to` mit.
- [ ] **R2 Weiterleitung.** Gilt `to` einem aktiven Gast dieser Session, geht die Rückfrage an ihn statt
      an Sirs Sprachkanal; Sirs Updates anderer Sessions laufen ungestört weiter.
- [ ] **R3 Beim Gast.** Push („Rückfrage · Website“) und ein Rückfrage-Bildschirm: die Frage vorgelesen
      und als Text, Antwort per Sprache (auf dem Gerät erkannt) oder Text, „An Sydney abgeben“.
- [ ] **R4 Antwort.** Geht als „[Antwort von Max · Marketing]“ zurück in die Session.
- [ ] **R5 Keine Antwort nach 2 min** (oder abgegeben) → die Rückfrage geht an Sir wie ein normales
      Update, mit dem Hinweis, dass Max nicht geantwortet hat.
- [ ] **R6 Sichtbar.** Bei Sir zeigt die Session „Rückfrage an Max“; beim Gast die offene Rückfrage.

## Betrieb

- [ ] **B1** Abgelaufene Einladungen werden regelmäßig entfernt (alle 30 s geprüft).
- [ ] **B2** Toter Einladungslink beim Gast → „Einladung abgelaufen oder schon benutzt“.
- [ ] **B3** Mac-Menü und Windows-Tray: geteilte Sessions mit „Entfernen“.
- [ ] **B4** Windows-Host 1:1, Android 1:1 (Eigentümer und Gast).
- [ ] **B5** Protokoll in `docs/IPHONE.md` (v7), README-Abschnitt „Session teilen“.
- [ ] **B6** Tests auf allen Seiten; Build, TestFlight, Mac einspielen.
