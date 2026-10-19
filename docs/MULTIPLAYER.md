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

- [x] **S1 Umzug nur für den eingeladenen Gast.** Wer den Link ebenfalls hat, hört im Einladungsraum
      mit und könnte dem Umzug folgen. Lösung: Der Gast schickt beim Beitritt einen frischen
      öffentlichen Schlüssel (P-256); der Host verschlüsselt die neuen Raumdaten per ECDH + HKDF nur
      für diesen Schlüssel. Fremde Geräte im Einladungsraum können sie nicht lesen.
- [x] **S2 Ein Beitritt pro Link.** Fragt schon jemand, werden weitere Anfragen ignoriert (geloggt);
      nach Ja oder Nein ist der Einladungsraum geschlossen.
- [x] **S3 Sir sieht, wer fragt.** Name und Gerät des Gastes in der Anfrage; ein vierstelliger
      Prüfcode, den beide Seiten sehen (aus dem Schlüssel des Gastes abgeleitet), damit Sir am Telefon
      gegenprüfen kann.
- [x] **S4 Keine Identitäts-Täuschung.** Gast-Text wird entschärft: „[Parley]“, „[Nachricht von …]“,
      „[Antwort von …]“ und `<speak` im Text werden neutralisiert, der Name ohne Klammern/Zeilenumbrüche.
- [x] **S5 Strikte Grenzen.** Der Gast erreicht nur: seine Session (Verlauf, Bilder, Nachricht),
      Antworten auf seine Rückfragen, seinen Push-Token. Nichts anderes (Anrufe, Fortsetzen, Zentrale,
      Snapshots, andere Sessions) — geprüft und getestet.
- [x] **S6 Missbrauchsbremse.** Höchstens 10 Nachrichten pro Minute und 8000 Zeichen; Antworten nur auf
      eigene offene Rückfragen.
- [x] **S7 Schlüssel sicher ablegen.** Host: shares.json nur für den Nutzer lesbar (0600) — erledigt;
      Gast: Keychain — erledigt. Nichts Geheimes im Log.
- [x] **S8 Entfernen wirkt sofort.** Sir entfernt den Gast → Ende-Frame, Verbindung zu, Raum aufgegeben,
      Gast löscht Schlüssel. Auch vom Mac-Menü / Windows-Tray aus.

## Rückfragen an den Gast (Teil 2)

- [x] **R1 Adressat.** Die Session schreibt `<speak to="Max">…</speak>`; der Stop-Hook gibt `to` mit.
- [x] **R2 Weiterleitung.** Gilt `to` einem aktiven Gast dieser Session, geht die Rückfrage an ihn statt
      an Sirs Sprachkanal; Sirs Updates anderer Sessions laufen ungestört weiter.
- [x] **R3 Beim Gast.** Push („Rückfrage · Website“) und ein Rückfrage-Bildschirm: die Frage vorgelesen
      und als Text, Antwort per vorhergesagter Antwort, Tippen oder Diktat der Tastatur, „An Sydney abgeben“.
      (Ein Live-Anruf wie bei Sir — CallKit, Stimme des Hosts — ist bewusst nicht Teil davon.)
- [x] **R4 Antwort.** Geht als „[Antwort von Max · Marketing]“ zurück in die Session.
- [x] **R5 Keine Antwort nach 2 min** (oder abgegeben) → die Rückfrage geht an Sir wie ein normales
      Update, mit dem Hinweis, dass Max nicht geantwortet hat.
- [x] **R6 Sichtbar.** Bei Sir zeigt die Session „Rückfrage an Max“; beim Gast die offene Rückfrage.

## Betrieb

- [x] **B1** Abgelaufene Einladungen werden regelmäßig entfernt (alle 30 s geprüft).
- [x] **B2** Toter Einladungslink beim Gast → „Einladung abgelaufen oder schon benutzt“.
- [x] **B3** Mac-Menü und Windows-Tray: geteilte Sessions mit „Entfernen“.
- [x] **B4** Windows-Host 1:1, Android 1:1 (Eigentümer und Gast). Android hat noch keinen Push: Rückfragen
      kommen dort als lokale Mitteilung, solange die Verbindung offen ist (Unterwegs) oder die App läuft.
- [x] **B5** Protokoll in `docs/IPHONE.md` (v7), README-Abschnitt „Session teilen“.
- [x] **B6** Tests: Mac 233, iPhone 102, Android 13, Hook, Mod; Windows kompiliert (CI). TestFlight 57, Mac eingespielt.
- [ ] **Offen:** Live-Test mit zwei echten Geräten; Windows einmal auf einem echten PC; echter Live-Anruf
      beim Gast (CallKit, Stimme) statt Rückfrage-Bildschirm — eigener Schritt, wenn gewünscht.
