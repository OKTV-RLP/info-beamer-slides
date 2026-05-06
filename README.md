# Infotext Player für info-beamer hosted

Spielt Folien (`playlist.m3u8` + PNG-Folien mit optionalem Alphakanal)
auf einem info-beamer-hosted-Pi ab. Mit Crossfade, Backup-/
Hintergrund-Layer (Bild oder Video), Live-Uhr-Overlay, Cornerlogo und
optionalem HTTP/Icecast-Audio-Stream als Hintergrundton.

## Architektur

info-beamer-Lua-Knoten haben **kein eingebautes HTTP** und **keine
zuverlässige Wall-Clock-API**. Das Package besteht daher aus zwei
Teilen:

```
service        ← Python-Sidecar:
                   • pollt HTTP, lädt Folien herunter,
                     schreibt manifest.json
                   • berechnet Lokalzeit (pytz) und pusht
                     den Anzeigetext via UDP-IPC
                   • probt regelmäßig die Audio-Stream-URL
                     und pusht ok/fail via UDP-IPC
                       │
                       ▼
                 manifest.json + slide_*.png (Folien-Dateien
                 mit Prefix im Knoten-Wurzelverzeichnis)
                 +  UDP localhost:4444 → "root/time:<text>"
                                       → "root/audio_probe:<ok|fail>:<url>"
                       │
                       ▼
node.lua       ← Renderer:
                   • liest manifest via util.json_watch
                   • empfängt Zeit + Audio-Probe via
                     util.data_mapper{ time, audio_probe }
                   • rendert mit Crossfade-Shader (prämultiplizierter
                     Alpha-Lerp), Zeit-Overlay, Cornerlogo
```

- Der Service pollt regelmäßig (`poll_interval`, Default 60 s) und
  schreibt nur dann ein neues Manifest, wenn sich die Folien-Liste
  ändert.
- Der Renderer wendet ein neues Manifest am **Ende des aktuellen
  Zyklus** an, mit Crossfade von der letzten Folie der alten Liste
  zur ersten Folie der neuen.
- Cache-Identität ist der Basename des Playlist-Eintrags (gleicher
  Basename ⇒ gleicher Inhalt, vom Server zugesichert); der Cache prüft
  daher nur auf Existenz, kein Hash-Vergleich, keine Re-Downloads.
  Vollständige URLs, relative Unterverzeichnisse und reine Dateinamen
  in der Playlist sind alle erlaubt — siehe *Playlist-Format und
  Adressierung*.
- Zeit-Overlay-Updates gehen per UDP an `127.0.0.1:4444` — keine
  SD-Schreibzyklen, sub-Sekunden-Latenz Service → Renderer.

## Features

- HTTP **und** HTTPS, optional mit self-signed-Zertifikaten
  (`allow_insecure_https`).
- Crossfade zwischen Folien innerhalb eines Zyklus **und** über die
  Zyklus-Grenze hinweg, mit Fragment-Shader für mathematisch korrekte
  Alpha-Komposition.
- Backup-Inhalt (Bild oder Video-Loop), wenn die Playlist nicht ladbar
  oder leer ist.
- Optionaler Hintergrund-Inhalt (Bild oder Video-Loop), durch den die
  transparenten Folien durchscheinen.
- Konfigurierbares Zeit-Overlay (Schrift, Größe, Farbe, Position,
  Ausrichtung, Format, Timezone, mehrzeilig, deutsche Wochentag-/
  Monatsnamen).
- Optionales Cornerlogo (transparentes PNG, frei positionierbar oder
  als Vollformat-Vorlage).
- Optionaler HTTP-/Icecast-Audio-Stream als Hintergrundton mit
  konfigurierbarem dB-Pegel und automatischem Reconnect bei Abriss.
- Optionale Jukebox: lokal hochgeladene Audio-Dateien werden als
  Endlos-Playlist (sequenziell oder zufällig) abgespielt — kein
  Netzwerk-Bedarf, läuft auch offline.
- Optionales Audio-Ducking: Stream/Jukebox werden während der
  Wiedergabe einer Vordergrund-Video-Folie um einen konfigurierbaren
  dB-Wert abgesenkt, mit weicher Pegel-Rampe.

## Installation

1. Diesen Ordner als Package nach info-beamer hosted hochladen
   (`Packages → Upload`).
2. Auf Basis des Packages ein Setup anlegen.
3. **Quelle**: `Playlist-URL` und `Folien-Basis-URL` des Infotext-
   Servers eintragen. Bei selbstsigniertem Zertifikat *Self-signed-
   HTTPS akzeptieren* einschalten.
4. **Optional Backup/Hintergrund**: eigenes Bild- oder Video-Asset
   hochladen und im Setup auswählen.
5. **Optional Zeit-Overlay**: aktivieren, Format und Position einstellen.
6. **Optional Cornerlogo**: aktivieren und Asset wählen.
7. **Optional Audio-Stream**: aktivieren und Stream-URL eintragen
   (siehe Voraussetzungen unten).
8. **Optional Audio-Jukebox**: Audio-Dateien als Resources hochladen,
   in der Setup-Liste *Jukebox-Playlist* in gewünschter Reihenfolge
   eintragen, ggf. *Zufällige Reihenfolge* aktivieren.
9. Setup einem Device zuweisen.

## Konfigurationsoptionen

### Quelle

| Option | Default | Beschreibung |
|---|---|---|
| Playlist-URL | – | M3U8-Playlist-URL (http:// oder https://) |
| Folien-Basis-URL | – | Verzeichnis-URL der Folien-Bilder |
| Self-signed-HTTPS akzeptieren | false | TLS-Prüfung deaktivieren |
| Polling-Intervall | 60 s | Wie oft der Service die Playlist prüft |
| Wiederholversuch | 30 s | Pause nach HTTP-Fehler oder leerer Playlist |

### Wiedergabe

| Option | Default | Beschreibung |
|---|---|---|
| Fade-Dauer | 500 ms | Crossfade-Dauer |
| Standard-Anzeigedauer | 10 s | Fallback wenn `#EXTINF` fehlt |

### Backup & Hintergrund

| Option | Default | Beschreibung |
|---|---|---|
| Backup-Inhalt | empty.png | Bild oder Video bei Fehler/leerer Playlist |
| Hintergrund-Inhalt | empty.png | Bild oder Video hinter den Folien |

### Zeit-Overlay

| Option | Default | Beschreibung |
|---|---|---|
| Anzeigen | false | Live-Uhr aktivieren |
| Zeit-Format | `%H:%M` | strftime, mehrzeilig per Enter im Eingabefeld |
| Zeitzone | `Europe/Berlin` | IANA-Zeitzone (Sommer-/Winterzeit automatisch) |
| Zeit-Sprache | `de` | Deutsche Wochentag-/Monatsnamen, sonst Englisch |
| Schrift | `DejaVuSans.ttf` | TTF-Asset (DejaVu Sans im Package gebündelt) |
| Schriftgröße | 80 px | |
| Farbe | weiß | RGBA |
| Position X / Y | 1820 / 980 | Pixel von links oben |
| Ausrichtung | rechts | links / zentriert / rechts |

### Cornerlogo

| Option | Default | Beschreibung |
|---|---|---|
| Anzeigen | false | Logo aktivieren |
| Bild | 1x1trans.png | PNG mit Alphakanal |
| Position X / Y | 0 / 0 | Pixel von links oben (linke Kante des Logos) |

### Hintergrund-Audio (Stream)

| Option | Default | Beschreibung |
|---|---|---|
| Aktivieren | false | Audio-Stream einschalten |
| Stream-URL | – | z. B. `http://stream.example.com:8000/radio.mp3` |
| Lautstärke | 0 dB | dB-Pegel (0 = voll, –20 dB = leise, ≤ –60 dB = stumm) |

### Hintergrund-Audio (Jukebox)

| Option | Default | Beschreibung |
|---|---|---|
| Aktivieren | false | Jukebox einschalten |
| Jukebox-Playlist | leer | Liste von Audio-Resources (MP3/AAC), wird in Reihenfolge abgespielt. Neue Einträge sind mit `idle.mp3` (CC0, Brandon Morris, im Package gebündelt) vorbelegt |
| Zufällige Reihenfolge | false | Beim Start und nach jedem kompletten Durchlauf neu mischen |
| Lautstärke | 0 dB | dB-Pegel (gleiche Skala wie Stream) |

### Audio-Ducking

| Option | Default | Beschreibung |
|---|---|---|
| Ducking-Absenkung | 0 dB | Pegelabsenkung während FG-Video; 0 = aus, –12 dB ≈ ¼ Lautstärke, ≤ –60 dB stumm |
| Ducking-Übergang | 250 ms | Ramp-Dauer für Ein-/Ausblenden des Duckings |

## HTTP/HTTPS und self-signed-Zertifikate

Der Python-Service nutzt die `requests`-Library. Standardmäßig wird
die TLS-Zertifikatskette gegen die System-CA validiert.

- **Reguläre Zertifikate** (Let's Encrypt etc.): einfach
  `https://`-URL eintragen, fertig.
- **Self-signed-Zertifikate**: Option *Self-signed-HTTPS akzeptieren*
  einschalten. Das setzt `verify=False` in `requests.get()` und
  unterdrückt die `InsecureRequestWarning`-Logs. **Schutz vor MITM
  entfällt** — nur in vertrauenswürdigen Netzen verwenden.
- **Reines HTTP**: einfach `http://`-URL eintragen.

## Backup- und Hintergrund-Inhalt

Beide Slots akzeptieren entweder ein Bild (PNG/JPG) oder ein Video-Loop
(MP4/WebM/MOV/MKV). Der Player erkennt den Typ automatisch über die
Asset-Metadaten von info-beamer hosted bzw. die Datei­endung und lädt
entsprechend `resource.load_image` oder `resource.load_video`.

**Bild:** funktioniert auf jeder Pi-Generation. Wird auf den vollen
Bildschirm gestreckt — bei abweichendem Seitenverhältnis verzerrt es,
also in nativer Display-Auflösung (z. B. 1920×1080) liefern.

**Video-Loop:** wird mit `raw = true` in die GL-Pipeline geladen, damit
es sich mit anderen Layern mischen lässt. Das setzt **Raspberry Pi 4
oder neuer** voraus. Auf Pi 3 schlägt der Load fehl, der Player loggt
eine Warnung und arbeitet ohne den betroffenen Slot weiter.

## Zeit-Overlay

Optionale Live-Uhr, gerendert über den Folien (im Backup-Zustand
verdeckt). Format und Timezone werden vom Python-Service ausgewertet
(via `pytz`); der Renderer empfängt nur den fertigen Anzeigetext per
UDP — kein Disk-IO, ~1 Update/Sekunde.

**Timezone-Behandlung:** info-beamer-Lua hat bewusst keine zuverlässige
Wall-Clock-API. Daher rechnet der Service. Der Default `Europe/Berlin`
wechselt automatisch zwischen MEZ und MESZ. Andere IANA-Zonen wie
`UTC`, `America/New_York` etc. funktionieren auch.

**Mehrzeilige Anzeige:** Zeilenumbrüche im *Zeit-Format*-Eingabefeld
werden zu echten Zeilenumbrüchen in der Ausgabe. Beispiel-Format mit
Enter zwischen den Tokens:

```
%H:%M
%d.%m.%Y
```

ergibt zwei Zeilen Anzeige:

```
16:42
30.04.2026
```

**Lokalisierung:** info-beamers C-Locale liefert `%A` (Wochentag) und
`%B` (Monat) auf Englisch. Bei *Zeit-Sprache = Deutsch* (Default)
ersetzt der Renderer Englisch → Deutsch nachträglich (`Wednesday` →
`Mittwoch`, `April` → `April`, `Mar` → `Mär` usw.). Frontier-Patterns
verhindern Falsch-Substitutionen wie `Mon` in `Montag`.

**Schrift:** im Package ist `DejaVuSans.ttf` (757 KB, public-domain-
permissiv) gebündelt. Eigene TTF-Assets können hochgeladen und über
das Setup-Feld ausgewählt werden.

## Cornerlogo

Optionales transparentes PNG, das **immer ganz oben** liegt — auch im
Backup-Zustand sichtbar. Im PLAYING-Zustand zwischen Folien und Zeit-
Overlay platziert (s. Render-Reihenfolge im Code).

Das Asset wird in seiner Original­größe bei `(logo_x, logo_y)`
gezeichnet. Zwei Verwendungs­muster:

- **Klein, positioniert**: kompaktes PNG (z. B. 200×100 px), `logo_x` /
  `logo_y` definiert die Top-Left-Pixel-Position.
- **Vollformat-Vorlage**: PNG in Display-Auflösung mit Logo via
  Transparenz positioniert, `logo_x` / `logo_y` auf 0/0 lassen — füllt
  den ganzen Bildschirm.

Default ist ein 1×1-transparentes PNG, das faktisch unsichtbar ist —
wer das Logo nutzen will, lädt sein eigenes Asset hoch.

## Hintergrund-Audio (Icecast/HTTP-Stream)

Optionaler Audio-Stream als Hintergrundton, geladen via
`resource.load_audio`. MP3/AAC-Icecast-Streams sind zuverlässig;
HLS oder andere Container und Codecs sollten ebenfalls funktionieren.

**Voraussetzungen:**
- `runtime.outside_sources = true` in `package.json` (im Package
  bereits gesetzt) — erlaubt info-beamer das Laden externer URLs.
- `sys.provides("audio") == true` auf der Hardware — Pi-Build mit
  Audio-Support.

**Pegel-Anpassung:** dB-Skala für den Stream — `0` ist volle
Lautstärke, `-20 dB` ein angenehmes Hintergrund-Niveau, `≤ -60 dB`
praktisch stumm. Werte > 0 werden auf 0 begrenzt (info-beamers
`:volume()` kann nur absenken, nicht verstärken).

**Reconnect:** Wenn der Stream abreißt, erkennt der Watchdog den
Decoder-State (`error`/`finished`) und versucht nach 5 s eine
Neuverbindung. Kein dynamischer Audio-Fallback auf Hintergrund-Video.

**Crash-Schutz (Sidecar-Probe):** Der `service`-Sidecar fragt die
Stream-URL per Range-GET ab und meldet das Ergebnis (`ok` / `fail`)
zusammen mit der gepruften URL per UDP-IPC an den Renderer. Probe-
Takt nominal 3–5 s (`ok`-Fall 5 s, `fail`-Fall 3 s); zwischen den
Folien-Downloads wird zusätzlich getickt, sodass der Heartbeat
auch unter Last meist regelmäßig kommt. Best-effort: solange ein
einzelner Folien-Download laeuft (Timeout bis 30 s), pausiert der
Heartbeat. Lua akzeptiert eine Probe als gültig, wenn sie nicht
älter als 60 s ist und die mitgesendete URL der aktuell konfigurierten
entspricht — `resource.load_audio` läuft nur dann.

Hintergrund: in info-beamer hosted (stable-0016) gibt es einen
reproduzierbaren SIGSEGV im Audio-Worker, sobald
`resource.load_audio` mit einer URL aufgerufen wird, die der
Server gerade nicht bedient (4xx/5xx, DNS-Fehler, Conn-Refused,
Timeout). Der Crash nimmt den ganzen Prozess mit, der Watchdog
startet neu, und solange die URL kaputt bleibt, entsteht eine
Restart-Schleife im Sekundentakt — Bildschirm permanent schwarz,
auch andere Slides werden nicht mehr gerendert. Aus Lua nicht
abfangbar (nativer Worker-Thread). Mit der Probe sieht der Worker
nie eine kaputte URL; bei Stream-Ausfall bleibt das Audio einfach
stumm, alle anderen Inhalte (BG-Video, Slides, Logo, Zeit) laufen
ungestört weiter.

## Hintergrund-Audio (Jukebox)

Lokal gespeicherte Audio-Dateien als Dauerhintergrundmusik — Alternative
zum Streaming, läuft auch ohne Netz. Tracks werden als info-beamer-
Resources hochgeladen und über die Setup-Liste *Jukebox-Playlist* in der
gewünschten Reihenfolge zusammengestellt.

**Wiedergabe-Logik:** genau ein Track ist gleichzeitig per
`resource.load_audio` geladen. Sobald `:state()` `finished` liefert,
disposed der Watchdog ihn und lädt den nächsten Eintrag der Reihenfolge.
Liefert ein einzelner Track `error`, springt die Logik direkt zum
nächsten Eintrag — ein einzelnes kaputtes File blockiert nicht die ganze
Playlist.

**Reihenfolge:** standardmäßig sequenziell von oben nach unten. Mit
*Zufällige Reihenfolge* wird beim ersten Start und nach jedem kompletten
Durchlauf per Fisher-Yates neu gemischt — innerhalb eines Durchlaufs
spielt jeder Track genau einmal, bevor der nächste Mix beginnt.

**Live-Edit-Verhalten:** wird die Playlist im Setup geändert, läuft der
gerade spielende Track weiter, wenn er noch in der Liste enthalten ist.
Andernfalls wird er sofort disposed und der nächste Track aus der neuen
Reihenfolge gestartet. Toggle der Shuffle-Option mischt die Reihenfolge
neu, ohne den aktuellen Track zu unterbrechen.

**Voraussetzungen:** identisch zum Stream — `sys.provides("audio")` auf
der Hardware. Da nur lokale Files gelesen werden, ist
`runtime.outside_sources` für die Jukebox nicht nötig (für den Stream
ist es bereits gesetzt).

## Audio-Ducking

Während eine Vordergrund-Video-Folie spielt, kann die laufende
Hintergrundmusik (Stream oder Jukebox) automatisch um einen
konfigurierbaren dB-Wert abgesenkt werden, damit die Tonspur des Videos
hörbar bleibt. Default `0 dB` lässt das Feature inaktiv — typische
Werte sind `–10` bis `–18 dB`.

**Wirkung:** Die Absenkung gilt **additiv** zum jeweils eingestellten
Basispegel der Quelle. Beispiel: Stream-Lautstärke `–6 dB`, Ducking
`–12 dB` → effektiv `–18 dB` während FG-Video läuft.

**Übergang:** Amplituden-linearer Fade über *Ducking-Übergang*
Millisekunden (Default 250 ms). 0 = harter Sprung. Die Pegel-Bewegung
verteilt sich gleichmäßig über die ganze Fade-Dauer, statt — wie
bei einer dB-linearen Rampe — vorne aggressiv abzufallen und hinten
unhörbar auszutrudeln. Insbesondere bei Fade-zu-Stumm (`-60 dB`)
fühlt sich die Bewegung dadurch durchgängig an.

**Trigger:** Der Fade startet im selben Frame, in dem die Video-Folie
geladen wird (also synchron zum visuellen Wechsel auf den FG-Video-
Layer); der Fade-Up beginnt beim Verlassen der Video-Folie.

**Geltungsbereich:** Wirkt nur auf Stream und Jukebox. Hintergrund-
Video-Audio entfällt während einer FG-Video-Folie ohnehin (BG-Video
wird via `background_yield()` für den Decoder-Slot disposed); Backup-
Video-Audio existiert nur im IDLE-Zustand und ist von einer
laufenden FG-Video-Folie definitionsgemäß nicht betroffen.

## Audio-Routing-Prioritäten

Audio kommt von genau einer Quelle gleichzeitig. Priorität:

1. **Backup-Video** (im IDLE-Zustand mit Backup als Video) — höchste
   Priorität.
2. **Audio-Stream** (wenn aktiviert + Verbindung steht).
3. **Audio-Jukebox** (wenn aktiviert + Track geladen).
4. **Hintergrund-Video** (Default-Quelle, wenn obige aus oder nicht
   anwendbar).

Kein dynamischer Fallback zwischen Stream/Jukebox/BG bei Ausfall der
höher priorisierten Quelle: ist Stream konfiguriert, aber gerade nicht
ladbar, bleibt's stumm — die Jukebox übernimmt **nicht** automatisch.
Wer ohne Netzverbindung Musik hören will, deaktiviert den Stream und
nutzt die Jukebox.

**Toggle-Verhalten Stream/Jukebox:** beim Ein-/Ausschalten von Stream
**oder** Jukebox wird das Hintergrund-Video disposed und mit passendem
Audio-Modus neu geladen (kurzer visueller Glitch von Bruchteilen einer
Sekunde):

- Stream **und** Jukebox **aus** → BG-Video lädt mit `audio = true`,
  kann Audio liefern.
- Stream **oder** Jukebox **an** → BG-Video lädt mit `audio = false` und
  läuft visuell durchgehend; Audio kommt von der höher priorisierten
  Quelle. Grund: info-beamers `:stop()` pausiert Video- und Audio-
  Decoder gemeinsam — wir können nicht gezielt nur den Audio-Track
  muten.

## Voraussetzungen

- info-beamer hosted Runtime mit Python 2.7 + `requests` + `pytz`
  (Standard).
- `runtime.outside_sources = true` in `package.json` (im Package
  bereits gesetzt) — für Audio-Stream-Loading.
- Erreichbarkeit des Quell-Servers per HTTP/HTTPS vom Pi aus.
- Folien-Filenames müssen content-addressed sein (gleicher Name ⇒
  gleicher Inhalt).
- Für Video-Loops: Raspberry Pi 4 oder neuer.
- Für Audio-Stream: Pi-Build mit `sys.provides("audio")`.

## Playlist-Format und Adressierung

Die M3U/M3U8-Playlist kann pro Eintrag drei Schreibweisen enthalten:

| Schreibweise | Beispiel | Download-URL |
|---|---|---|
| Reiner Dateiname | `clip.mp4` | `<folien_base_url>/clip.mp4` |
| Relativer Pfad | `videos/clip.mp4` | `<folien_base_url>/videos/clip.mp4` |
| Vollständige URL | `https://cdn.example.com/v/clip.mp4` | wird so wie angegeben gezogen |

Server-absolute Pfade (`/abs/clip.mp4`) werden gegen die Host-Wurzel der
`folien_base_url` aufgelöst. Query-Strings und Fragmente in URLs werden
beim Download mitgesendet, fließen aber nicht in den Cache-Filename ein.

**Cache-Identität ist immer der Basename**: `clip.mp4` aus `cdn.example.com`
und `clip.mp4` aus `<folien_base_url>` würden auf denselben Cache-Slot
fallen — die ausliefernden Server müssen daher die Invariante "gleicher
Basename = gleicher Inhalt" einhalten. Wechsel des Hosts oder Pfads sind
unkritisch, solange diese Invariante gilt.

Percent-Encoding im Basename (`cl%C3%A4p.mp4` → `cläp.mp4`) wird beim
Erzeugen des Cache-Filenames aufgelöst, sodass URL-encoded und direkt
UTF-8 angegebene Einträge auf denselben Slot abbilden.

## Caching-Verhalten

- **Cache-Ort**: Folien werden mit `slide_`-Prefix direkt im Knoten-
  Wurzelverzeichnis abgelegt (kein Subverzeichnis — info-beamer
  behandelt Subdirs als Child-Nodes und findet zur Laufzeit befüllte
  Dateien dort nicht zuverlässig).
- **Download nur bei Bedarf**: der Cache-Filename ist der Basename des
  Playlist-Eintrags (s. *Playlist-Format und Adressierung*); der
  Service prüft vor jedem Download nur, ob die Datei existiert.
- **Cache-GC**: nach jedem erfolgreichen Playlist-Fetch löscht der
  Service alle Files mit `slide_`-Prefix, die nicht mehr in der
  aktuellen Playlist stehen, sowie `.tmp`-Reste abgebrochener
  Downloads. Wird bei HTTP-Fehler oder leerer Playlist übersprungen,
  damit ein Server-Ausfall nicht den Cache wegwirft.
- **Cache-Wipe bei Service-Update**: info-beamer entfernt alle vom
  Service erzeugten Files (außer `SCRATCH/`), wenn das Service-Skript
  aktualisiert wird. Folien werden dann beim ersten Polling neu
  heruntergeladen. Reine `node.lua`/`node.json`-Updates lassen den
  Cache intakt.

## Lokales Testen mit info-beamer pi

Falls du auf einem Pi außerhalb der Hosted-Plattform testen willst:

```bash
# config.json manuell anlegen:
cat > config.json <<EOF
{
    "playlist_url": "https://dein-server/slides/playlist.m3u8",
    "folien_base_url": "https://dein-server/slides/",
    "allow_insecure_https": false,
    "poll_interval": 60,
    "retry_interval": 30,
    "fade_duration": 500,
    "default_duration": 10,
    "backup_media": "empty.png",
    "background_media": "empty.png",
    "time_enabled": false,
    "time_format": "%H:%M",
    "time_timezone": "Europe/Berlin",
    "time_locale": "de",
    "time_font": "DejaVuSans.ttf",
    "time_size": 80,
    "time_color": {"r":1, "g":1, "b":1, "a":1},
    "time_x": 1820,
    "time_y": 980,
    "time_align": "right",
    "logo_enabled": false,
    "logo_image": "1x1trans.png",
    "logo_x": 0,
    "logo_y": 0,
    "audio_stream_enabled": false,
    "audio_stream_url": "",
    "audio_stream_volume_db": 0,
    "audio_jukebox_enabled": false,
    "audio_jukebox_playlist": [],
    "audio_jukebox_shuffle": false,
    "audio_jukebox_volume_db": 0,
    "audio_ducking_db": 0,
    "audio_ducking_fade": 250
}
EOF

# Service im Hintergrund starten
# (lädt Folien & schreibt manifest.json, pusht Zeit per UDP):
./service &

# Renderer starten:
INFOBEAMER_STREAMING=1 info-beamer .
```

`INFOBEAMER_STREAMING=1` ist auf dem Pi-Standalone-Player nötig, um
HTTP-URLs in `resource.load_audio` zu erlauben — auf info-beamer
hosted aktiviert das `runtime.outside_sources` in `package.json` das
gleiche Verhalten.
