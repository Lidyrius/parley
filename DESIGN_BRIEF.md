# Parley — Design Brief (für Grafik / UI-Design)

## Was ist Parley?

Parley ist eine **native macOS-Menüleisten-App** (macOS 26 „Tahoe"), die aus Claude Code eine
gesprochene Unterhaltung macht. Sobald einer von mehreren parallel laufenden Coding-Sessions einen
Arbeitsschritt beendet, **spricht** die App eine kurze Zusammenfassung, **hört** dann per Mikrofon die
gesprochene Antwort des Nutzers und schickt sie zurück an die Session. Es fühlt sich an wie ein
Assistent, der einem freihändig Bescheid gibt, während man nebenbei etwas anderes tut (z. B. YouTube
schaut — das pausiert automatisch, während gesprochen wird).

Charakter: **ruhig, präzise, vertrauenswürdig, „calm technology".** Kein verspieltes Chatbot-Maskottchen.
Eher ein hochwertiges System-Utility im Geist von Apples eigenen Bordmitteln (Spotlight, das
Siri-Panel, Kontrollzentrum). Die App lebt zu 95 % im Hintergrund — sie darf nie aufdringlich sein,
muss aber im richtigen Moment **sofort verständlich** signalisieren, was gerade passiert.

---

## Visuelle Sprache: „Liquid Glass" (macOS 26)

Die App nutzt Apples neues **Liquid Glass** Designsystem (eingeführt 2025). Bitte streng daran halten,
damit sich die App wie ein Erstanbieter-Produkt anfühlt und nicht wie ein Fremdkörper.

- **Material statt Fläche:** Oberflächen sind lichtbrechendes „Glas", das den Desktop dahinter
  aufnimmt (Lensing, nicht simpler Blur). Chrome/Steuerungen schweben als Glas-Ebene *über* dem Inhalt.
- **Glas gehört in die funktionale Ebene** (Panels, Buttons, Toolbar, schwebende Controls) — **nie**
  großflächig auf die Inhaltsebene und **nie** Glas auf Glas stapeln.
- **Weiche, großzügige Rundungen**, „concentric" zueinander (innere Radien folgen dem Gehäuse-Radius).
- **Tiefe durch Licht**, nicht durch harte Schlagschatten: dezente Specular-Highlights an den Kanten.

Referenzen (bitte lesen):
- Apple HIG – **Materials**: https://developer.apple.com/design/human-interface-guidelines/materials
- Apple – **Adopting Liquid Glass**: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- WWDC25 „Meet Liquid Glass" & „Get to know the new design system" (developer.apple.com/videos)

---

## Formfaktor & Screens

### 1. Menüleisten-Icon (Statusleiste, oben rechts)
- Monochrom, Template-Style (nimmt automatisch hell/dunkel an), **SF Symbols**-konform gezeichnet,
  optisch ausbalanciert für 16–18 pt Höhe.
- Muss **Zustände** anzeigen (kleine Variante, nicht bunt-schreiend):
  - **Idle** – ruhiges Basis-Icon (z. B. stilisierte Schallwelle / Sprech-Glyphe).
  - **Speaking** – die App spricht gerade.
  - **Listening** – Mikrofon aktiv, wartet auf Antwort.
  - **Working/Queued** – eine oder mehrere Sessions laufen/warten (dezenter Badge/Punkt).
- Idee: eine Glyphe, deren „Welle" in den Zuständen minimal variiert. Bitte alle Zustände als Set.

### 2. Haupt-Panel (Popover unter dem Menüleisten-Icon)
Ein schwebendes Liquid-Glass-Popover, ähnlich Kontrollzentrum/Siri-Panel. Inhalt:
- **Oben: der „Voice-Orb" / Aktivitätsvisualisierung** — das Herzstück (siehe unten). Zeigt den
  aktuellen Live-Zustand (spricht / hört zu / denkt / still).
- **Darunter: Session-Liste.** Jede Zeile = eine Claude-Code-Session:
  - Projektname (aus dem Ordner), Status-Chip (`arbeitet` / `fertig – spricht gleich` / `wartet auf dich`),
    kleine Zeitangabe („läuft seit 12 min"), dezenter Fortschritts-/Aktivitätsindikator.
  - „Aktive" Session (die gerade bespricht/besprochen wird) klar hervorgehoben.
- **Fuß: schlanke Leiste** — Mute/Pause-Toggle, Zahnrad (Einstellungen), evtl. „alle stumm".

### 3. Einstellungen (eigenes Fenster)
- Standard-macOS-Settings-Look (`Form`/gruppierte Sektionen).
- Felder: ElevenLabs API-Key, Groq API-Key, **Stimme** (Voice-Picker mit Vorschau-Play), Beep an/aus,
  Silence-Empfindlichkeit (Slider), Media-Auto-Pause an/aus, Autostart.
- Ein kleiner Permissions-Bereich (Mikrofon, Bedienungshilfen) mit Status-Häkchen + „Öffnen"-Button.

### 4. Zustands-/Transient-Overlay (optional, „nice to have")
Wenn eine Session fertig wird und die App spricht, während das Panel geschlossen ist: ein kleines,
kurz eingeblendetes Glas-Toast nahe der Menüleiste (Projektname + „…"-Sprechindikator). Verschwindet
von selbst.

---

## Der „Voice-Orb" (zentrales Element)

Die eine Sache, die die App emotional trägt. Eine abstrakte, atmende Form, die den Live-Zustand zeigt —
im Geist der **Siri-Visualisierung** und der Apple-Intelligence-Glow-Sprache, aber eigenständig, in
Liquid Glass gedacht (Licht/Brechung statt platter Gradient-Blob).

Zustände als Bewegungs-/Form-Varianten:
- **Idle/Ready** – ganz ruhiges, langsames Atmen. Kaum Bewegung.
- **Speaking** – Amplitude folgt der Sprachausgabe (Waveform/Puls), warm.
- **Listening** – reagiert auf die Mikrofon-Lautstärke des Nutzers, „hört zu"-Gefühl.
- **Thinking/Working** – sanftes, umlaufendes Fließen (kein Spinner-Klischee).

Bitte als **Motion-Konzept** (Prinzip + Keyframes/Referenz-Clip) liefern, nicht nur ein Standbild.
Umsetzung wird SwiftUI/Canvas/Shader — je einfacher & performanter die Idee, desto besser.

---

## Farbe, Typo, Ikonografie, Motion

- **Typografie:** ausschließlich **SF Pro** (San Francisco), System-Textstyles (Title/Headline/Body/
  Caption) mit Dynamic-Type-Logik. Kein Fremd-Font.
  → https://developer.apple.com/fonts/  ·  HIG Typography:
    https://developer.apple.com/design/human-interface-guidelines/typography
- **Farbe:** primär **System-/semantische Farben** (label, secondaryLabel, separator, System-Accent),
  damit hell/dunkel & Nutzer-Akzentfarbe automatisch passen. **Eine** zurückhaltende Marken-Akzentfarbe
  ist erlaubt, sparsam (Orb-Glow, aktiver Zustand). Kräftige Farben nur als Licht/Glow, nie als Fläche.
  → HIG Color: https://developer.apple.com/design/human-interface-guidelines/color
- **Icons:** **SF Symbols 6+**, durchgängig, richtige Gewichte/Rendering-Modes; eigene Glyphen nur wenn
  nötig und dann im SF-Symbols-Duktus (gleiche Strichstärke/Optik), als Symbol-Template.
  → https://developer.apple.com/sf-symbols/
- **Motion:** ruhig, federnd, sinnvoll (Apples „fluid, deferential"). Keine harten Cuts, keine
  Zappel-Animationen. Zustandswechsel des Orbs weich morphen.
  → HIG Motion: https://developer.apple.com/design/human-interface-guidelines/motion
- **Hell & Dunkel:** beide Modi sind Pflicht und gleichwertig. Glas verhält sich in beiden korrekt.
- **Barrierefreiheit:** ausreichende Kontraste (auch mit „Increase Contrast"/„Reduce Transparency"),
  „Reduce Motion"-Fallback für den Orb (statisch/dezent), sinnvolle VoiceOver-Labels.
  → HIG Accessibility: https://developer.apple.com/design/human-interface-guidelines/accessibility
- **App-Icon:** vollständiges macOS-App-Icon-Set im aktuellen **Icon-Stil (macOS 26, „Icon Composer",
  layered/Liquid-Glass-fähig)**. → HIG App icons:
    https://developer.apple.com/design/human-interface-guidelines/app-icons

Allgemeine Referenz-Startseite: **Apple Human Interface Guidelines** —
https://developer.apple.com/design/human-interface-guidelines/  ·  Speziell **macOS**:
https://developer.apple.com/design/human-interface-guidelines/designing-for-macos

---

## Gewünschte Deliverables

1. **App-Icon** – volles macOS-Set (inkl. neuer Icon-Stil, hell/dunkel/getönt falls zutreffend).
2. **Menüleisten-Icon** – Template-Symbol, alle Zustände (Idle/Speaking/Listening/Working) als Set.
3. **Voice-Orb** – Motion-Konzept + Zustands-Varianten (Referenz-Clip oder Keyframes) und Farb-/Glow-Spec.
4. **Haupt-Panel** – hell + dunkel, mit gefüllter Session-Liste (mehrere Zustände) und leerem Zustand.
5. **Einstellungs-Fenster** – Layout hell + dunkel.
6. **Optional:** Transient-Toast, Onboarding/Permissions-Screen.
7. Als **Figma-Datei** mit sauberen Komponenten/Variants + kurze Spec (Radien, Abstände 8-pt-Raster,
   verwendete SF-Textstyles & SF-Symbols, Akzentfarbe). Assets als PDF/SVG (Symbole) exportierbar.

## Rahmen / Constraints (technisch relevant fürs Design)

- Umsetzung in **SwiftUI**; alles was Standard-Komponenten sind, bekommt Liquid Glass „gratis" — je näher
  am System, desto weniger Custom-Aufwand, desto konsistenter.
- Panel ist **kompakt** (Popover-Größe, kein großes Fenster). Inhalt muss bei 1 bis ~8 Sessions gut
  aussehen und scrollen.
- 8-pt-Raster, System-Metriken für Touch/Klick-Targets.
- Bitte **kein** Custom-Chrome, das gegen die Menüleisten-/Popover-Konvention arbeitet.
