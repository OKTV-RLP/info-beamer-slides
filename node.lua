-- Infotext Player für info-beamer hosted
--
-- Reiner Renderer: HTTP-Fetching erfolgt im Python-Service-Sidecar
-- (siehe ./service), der Folien herunterlädt und manifest.json schreibt.
-- Diese Datei wird via util.json_watch beobachtet — bei Änderung wird
-- zum nächsten Zyklus-Ende auf die neue Folge geswitcht.
--
-- Crossfade zwischen Folien innerhalb eines Zyklus UND über die
-- Zyklus-Grenze hinweg (letzte Folie alt → erste Folie neu, ggf. nach
-- Manifest-Update).
--
-- Backup- und Hintergrund-Slot akzeptieren je ein Bild ODER ein Video.
-- Folien selbst koennen Bilder (PNG) ODER H.264-Videos (MP4) sein,
-- in beliebiger Mischung in der Playlist. Video-Folien werden in voller
-- Dateilaenge ausgespielt (Manifest-duration wird ignoriert) und mit
-- Hard-Cut an Image- bzw. anderen Video-Folien angeschlossen — der
-- Crossfade-Shader kann nur GL-Texturen samplen, nicht raw-Videos.
--
-- Bilder funktionieren auf jedem von info-beamer hosted unterstuetzten
-- Pi (JPEG/PNG, max. 2048x2048 wegen GL-Texture-Limit). Video-Wiedergabe
-- laeuft via raw=true GL-Pipeline:
--   * Pi 3 / 3B / 3B+ / Zero 2 W / Pi 4 / CM4: H.264 hardware-beschleunigt
--   * Pi 4+ zusaetzlich HEVC hardware-beschleunigt (info-beamer hosted v10+)
--   * Pi 5: H.264 in Software (kein HW-Decoder mehr in der VPU);
--     funktioniert, kostet aber spuerbar mehr CPU. HEVC bleibt HW.
-- Pi 3 / 3B / Zero 2 W haben nur EINEN H.264-Hardware-Decoder-Slot. BG-
-- und FG-Video koennen nicht gleichzeitig HW-decodiert laufen — das
-- BG-Video wird daher fuer die Dauer einer Video-Folie via
-- background_yield() komplett freigegeben und mit background_resume()
-- wieder geladen. Auf Pi 4/5 ist diese Yield-Strategie konservativ
-- aber unschaedlich.
--
-- Layer-Stack (negativ = hinter GL-Surface):
--   -3: Hintergrund-Video (background_slot)
--   -2: Backup-Video      (backup_slot)
--   -1: Foreground-Video  (fg_video, nur waehrend Video-Folien aktiv)
--    0: GL-Surface mit Folien-Image, Cornerlogo, Zeit-Overlay
-- Cornerlogo + Zeit liegen damit auch ueber laufenden Video-Folien.
--
-- Audio (info-beamer mischt automatisch alle :start()-aktiven Quellen):
--   * Normalbetrieb (PLAYING): Audio des Hintergrund-Videos.
--   * Backup-Zustand (IDLE) mit Backup-VIDEO: Audio des Backup-Videos.
--   * Backup-Zustand mit Backup-BILD: Audio des Hintergrund-Videos
--     laeuft weiter, das Backup-Bild liegt nur visuell darueber.
--   * Video-Folie (PLAYING): FG-Audio mischt sich mit der bisherigen
--     Quelle (Stream/Jukebox); BG-Audio entfaellt, weil BG fuer den
--     Decoder-Slot weichen muss.
--
-- Single-Video-Playlist (#slides == 1, einziger Slot ist Video): das
-- Video wird mit looped=true geladen — Decoder-internes nahtloses
-- Looping, frame-genau, ohne Dispose+Reload-Luecke. Das bleibt fuer
-- die gesamte Standzeit der Playlist so, bis ein Manifest-Update
-- ueber den Sidecar eine neue Liste liefert (force-Advance via
-- pending_slides bricht den Loop fuer den swap_slides-Pfad).

gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

util.no_globals()

local json = require "json"

------------------------------------------------------------
-- Konfiguration
------------------------------------------------------------

-- fade_duration und audio_ducking_fade sind im Setup in Millisekunden
-- konfiguriert (UI-Skala) und werden hier in Sekunden gehalten —
-- file_watch dividiert beim Read durch 1000. Sekunden passen direkt
-- zu sys.now()-Differenzen, die in den Render-Loops gerechnet werden.
local CONFIG = {
    fade_duration       = 0.5,
    default_duration    = 10,
    audio_ducking_db    = 0,     -- Absenkung waehrend FG-Video (<= 0)
    audio_ducking_fade  = 0.25,  -- Rampe in Sekunden (= 250 ms im Setup)
}

-- Raw-Videos rendern in info-beamer auf einer eigenen Ebene außerhalb
-- der GL-Pipeline. layer < 0 platziert das Video HINTER der GL-Surface,
-- sodass transparente Folien-Pixel via gl.clear(_, _, _, 0) und
-- transparenten Folien-PNG-Bereichen das Video durchscheinen lassen.
-- Reihenfolge der negativen Layer (siehe Datei-Header): BG (-3),
-- Backup (-2), Foreground-Video-Folie (-1, dynamisch). Backup auf
-- hoeherer (= weniger negativer) Ebene als BG, damit es im IDLE-
-- Zustand das BG-Video ueberdeckt; FG-Video wiederum oberhalb von
-- Backup, damit eine Video-Folie BG/Backup ueberblendet.
-- slot.audio steuert, ob die Resource mit Audio-Track geladen wird.
-- Backup-Video: immer mit Audio (Audio-Quelle nur waehrend IDLE+
-- backup-video sichtbar; Pause durch :stop() in anderen States ist
-- ok, weil das Video dann ohnehin off-screen ge:place't ist).
-- Background-Video: dynamisch, abhaengig von audio_stream.enabled.
--   Stream aus → audio=true  (BG-Video kann Audio-Quelle sein)
--   Stream an  → audio=false (BG-Video laeuft visuell durchgehend
--                             und wird vom Routing nicht :stop()ed)
-- Bei Toggle des Stream-Zustands forciert update_media_slot ueber
-- den slot.audio_loaded-Vergleich einen Reload des BG-Videos.
local backup_slot     = { res = nil, kind = nil, file = nil, label = "Backup-Inhalt",     layer = -2, audio = true }
local background_slot = { res = nil, kind = nil, file = nil, label = "Hintergrund-Inhalt", layer = -3, audio = true }

-- Foreground-Video-Slot fuer Video-Folien. Nur eine Resource gleichzeitig
-- (Lazy-Load beim Eintritt in eine Video-Folie, Dispose beim Verlassen).
-- BG-Video MUSS vor dem Load via background_yield() freigegeben werden,
-- weil Pi 3B nur einen H.264-Decoder hat. looped=false → das Video laeuft
-- bis :state() == "finished", dann advanced der Render-Loop.
local fg_video = {
    res   = nil,
    file  = nil,
    layer = -1,
}

-- Optionales Zeit-Overlay. Wird im PLAYING-Zustand über den Folien
-- gezeichnet, im IDLE-Zustand vom Backup-Layer überdeckt (durch
-- Render-Reihenfolge). Erfordert ein per Setup hochgeladenes Font-
-- Asset; ohne Schrift wird das Overlay übersprungen.
local time_overlay = {
    enabled   = false,
    -- text wird vom service-Sidecar (mit korrekter Timezone) per
    -- UDP-IPC zugestellt und via util.data_mapper{ time = … }
    -- eingespielt. Kein Disk-IO.
    text      = "",
    locale    = "de",
    font_res  = nil,
    font_file = nil,
    size      = 80,
    color     = { r = 1, g = 1, b = 1, a = 1 },
    x         = 1820,
    y         = 980,
    align     = "right",
}

-- Optionales Cornerlogo: PNG mit Alphakanal, in Originalgröße bei
-- (x, y) gezeichnet.
-- Wird IMMER zuletzt gezeichnet, liegt also auch im Backup-Zustand
-- sichtbar oben drüber.
local corner_logo = {
    enabled = false,
    res     = nil,
    file    = nil,
    x       = 0,
    y       = 0,
}

------------------------------------------------------------
-- Player-State
------------------------------------------------------------

local STATE_IDLE    = "idle"      -- keine Folien aktiv → backup_slot
local STATE_PLAYING = "playing"

local state          = STATE_IDLE
local slides         = {}     -- [{file, kind, duration, res}, ...]
local current_idx    = 1
local slide_started  = 0
local pending_slides = nil    -- nächste Liste, swap am Zyklus-Ende
local last_cur       = nil    -- zuletzt gerenderte Folie (Slide-Wechsel-Hook)

-- Watchdog gegen Dauer-Fail aller Folien einer Playlist: Render setzt
-- slide_drew=true, sobald die aktuelle Folie tatsaechlich gezeichnet
-- wurde (Image-Decode fertig + non-failed bzw. FG-Video placeable).
-- Beim Slide-Advance wird ausgewertet: war ueber die gesamte Lebenszeit
-- der Folie kein einziger Frame zeichenbar (slide_drew bleibt false),
-- inkrementiert consecutive_failed_slides; andernfalls Reset auf 0.
-- slide_drew wird im selben Schritt zurueckgesetzt, sodass die
-- naechste Folie wieder bei false startet. Erreicht der Counter
-- #slides (kompletter Cycle ohne sichtbaren Frame), wechselt der
-- Player nach IDLE und zeigt das Backup. Zusaetzliche Resets beim
-- IDLE->PLAYING-Uebergang und nach jedem Manifest-Update am Cycle-
-- Ende (s. swap_slides-Aufrufer im Advance-Pfad bzw. IDLE-Branch).
local slide_drew                = false
local consecutive_failed_slides = 0

-- Zyklus-Crossfade (letzte Folie alt → erste Folie neu).
local outgoing         = nil   -- nil oder {res, dispose_after}
local cycle_fade_start = 0

-- Visuelle Synchronisierung GL-Surface (Layer 0) <-> Raw-Video-Layer
-- (-3/-1) bei Wechseln zwischen Image+BG-Video und FG-Video. Raw-Videos
-- werden vom Compositor unabhaengig von der GL-Pipeline gepostet —
-- :dispose() schlaegt typisch erst einen Compositor-Frame spaeter durch,
-- :load_video braucht Decoder-Spinup. Ohne Korrektur:
--   * Image+BG -> FG-Video: Image weg in Frame N+1 (GL-clear sofort),
--     BG erst in N+2 weg (Compositor-Lag). 1 Frame "nur BG".
--   * FG-Video -> Image+BG: FG weg in N+1, Image sofort gezeichnet,
--     BG-Video poppt in N+k rein (loading->playing).
-- Image-Hold beim Image->Video-Wechsel mit Video-BG: das alte Image
-- wird auf der GL-Surface weiter gezeichnet, bis das neue FG-Video
-- placeable ist (oder die Hold-Deadline erreicht). Vorher war das ein
-- 1-Frame-Hold gegen den Compositor-Lag des BG-Dispose; reicht aber
-- nicht, wenn der FG-Decoder mehrere Frames im "loading"-State braucht
-- (Pi 3B: typisch 200-400 ms). Multi-Frame-Hold haelt bis zum ersten
-- placeable-Frame oder bis zum Timeout — danach wird die Resource ggf.
-- disposed (s. dispose_after-Flag).
--
-- Felder:
--   res           = Image-Resource (Userdata)
--   deadline      = sys.now()-Zeitpunkt fuer Sicherheits-Timeout
--   dispose_after = true, sobald reconcile_window oder swap_slides
--                   die Resource aus ihrem urspruenglichen Slot
--                   entfernen wuerden — der Hold uebernimmt dann die
--                   Disposal-Verantwortung beim Aufloesen
--                   (analog zum outgoing-Mechanismus).
local pending_image_hold = nil
local PENDING_IMAGE_HOLD_TIMEOUT = 1.0  -- s, deutlich groesser als
                                        -- typische FG-Video-Loading-
                                        -- Zeiten auf Pi 3B
local bg_resume_gate         = nil  -- {deadline,last_tick}. Solange
                                    -- gesetzt: Image-Pfad zeichnet die
                                    -- Folie nicht (Time-Overlay und
                                    -- Cornerlogo laufen weiter), bis
                                    -- das resumte BG-Video state==
                                    -- "playing" liefert.
local BG_RESUME_GATE_TIMEOUT = 0.5  -- Sicherheits-Fallback (Sek.) gegen
                                    -- kaputtes BG-Video, das nie
                                    -- "playing" erreicht.

-- Audio-Routing-Status: "background" | "backup" | "stream" | "jukebox" | nil
local audio_active = nil

-- Optionaler HTTP-/Icecast-Audio-Stream via resource.load_audio;
-- Aktivierung verlangt zusätzlich
-- runtime.outside_sources=true in package.json (für HTTP-URLs) und
-- die "audio"-Capability auf der Hardware (sys.provides "audio").
-- Pegel wird zur Laufzeit per :volume(0..1) gesteuert (Berechnung in
-- apply_audio_levels: db_to_linear(volume_db + ducking-Offset)). Watchdog
-- disposed bei state="error"/"finished" und reconnectet nach retry_after Sekunden.
local audio_stream = {
    enabled      = false,
    url          = "",
    volume_db    = 0,    -- Basispegel in dB (0 = unity, <= -60 = stumm)
    res          = nil,
    loaded_url   = nil,
    last_attempt = -math.huge,
    retry_after  = 5,
    buffer       = 5,    -- Sekunden Pre-Buffer
    available    = sys.provides and sys.provides("audio") or false,
}

-- Erreichbarkeits-Probe vom Sidecar (UDP-IPC, Path "audio_probe").
-- Schickt im 3..5-s-Takt "ok" oder "fail", je nachdem ob ein
-- HTTP-GET an audio_stream.url einen Status < 400 zurueckliefert.
-- Solange ok ~= true (Probe-Resultat fail oder noch keine Probe
-- empfangen), unterdrueckt check_audio_stream_health jeden
-- (Re)load-Versuch. Hintergrund: ein bekannter SIGSEGV im info-
-- beamer-Audio-Worker beim Verarbeiten unerreichbarer URLs (404,
-- DNS-Fail, Conn-Refused, Timeout) reisst ohne diesen Schutz den
-- gesamten Knoten samt Watchdog im Sekundentakt mit. Aus Lua
-- nicht abfangbar (Crash im nativen Worker-Thread).
--
-- url: die URL, fuer die das letzte Probe-Resultat galt (vom
-- Sidecar im IPC-Payload mitgesendet). Reload-Gate akzeptiert ein
-- "ok" nur, wenn diese URL == audio_stream.url — andernfalls
-- koennte ein frisches "ok" der alten Konfig-URL versehentlich
-- den Load einer gerade geaenderten neuen URL freischalten,
-- bevor der Sidecar sie ueberhaupt geprobt hat.
--
-- stale_after = 60 s: laeuft die Probe aus (Sidecar tot/haengt
-- oder steckt in einem langen Folien-Download), prueft der
-- Reload-Gate via (now - last_msg_at) und blockt — sicherer
-- Default. Lieber stumm als Crash-Loop. Wert groesser als der
-- single-Download-Timeout im Sidecar (30 s) gewaehlt, damit ein
-- einzelner langer Download zwischen den Probe-Ticks die Probe
-- nicht knapp ueber die Schwelle drueckt.
local audio_probe = {
    ok           = nil,
    url          = nil,
    last_msg_at  = -math.huge,
    stale_after  = 60,
}

-- Optionale Jukebox: lokal gespeicherte Audio-Files (per Setup als
-- Resources hochgeladen) werden sequenziell oder zufaellig nacheinander
-- abgespielt. Genau ein Track ist gleichzeitig geladen. Sobald
-- :state() == "finished" liefert, disposed der Health-Check ihn und
-- laedt den naechsten Track der Reihenfolge. Bei "error" wird der
-- gleiche Track nicht endlos retried — wir wechseln direkt zum
-- naechsten der Liste, sonst koennte ein einzelnes kaputtes File die
-- gesamte Wiedergabe blockieren.
--
-- Reihenfolge: order ist eine Permutation von 1..#files (Sequenz oder
-- Fisher-Yates-Shuffle). order_pos zeigt auf den zuletzt geladenen
-- Eintrag. Nach dem Ende der Liste mischt sich order bei shuffle=true
-- neu — sonst startet sie wieder bei 1.
local audio_jukebox = {
    enabled       = false,
    shuffle       = false,
    volume_db     = 0,      -- Basispegel in dB (0 = unity, <= -60 = stumm)
    files         = {},     -- {dateiname, ...}
    order         = {},     -- Indizes in files (Sequenz oder Shuffle)
    order_pos     = 0,
    res           = nil,
    loaded_file   = nil,
    last_state    = nil,
    last_attempt  = -math.huge,
    retry_after   = 2,      -- Cooldown zwischen Load-Versuchen (Schutz
                            -- gegen Reload-Sturm bei wiederholten
                            -- Fehlern; bei normalen Track-Wechseln
                            -- vernachlaessigbar, weil last_attempt nur
                            -- im load_jukebox_track() gesetzt wird)
    available     = sys.provides and sys.provides("audio") or false,
}

-- Ducking: senkt den Pegel der aktiven Hintergrund-Quelle (Stream/
-- Jukebox) waehrend der Wiedergabe einer Vordergrund-Video-Folie um
-- CONFIG.audio_ducking_db ab. Trigger ist fg_video.res ~= nil — kein
-- separater Hook in fg_video_load/unload noetig.
--
-- Rampen-Modell: factor ∈ [0, 1] interpoliert linear in der Zeit
-- (1/fade pro Sekunde) zwischen 0 (kein Ducking) und 1 (volles
-- Ducking). apply_audio_levels mischt daraus den Pegel als
-- amplituden-lineare Interpolation zwischen base_lin und ducked_lin
-- (beide ueber db_to_linear gerechnet) — d.h. der Linear-Faktor
-- :volume() bewegt sich gleichmaessig, statt wie bei einer dB-
-- linearen Rampe vorne aggressiv zu fallen und hinten ins Stumme
-- zu trudeln. Wirkt insbesondere bei Fade-zu-(-60 dB) hoerbar
-- gleichmaessiger.
local audio_ducking = {
    factor = 0,
    last_t = nil,    -- sys.now() der letzten Rampen-Anwendung
}

-- Math-RNG einmalig seeden, damit Shuffle nicht in jeder Session
-- identisch laeuft. sys.now() liefert eine Float-Sekunde seit
-- Knoten-Start; das genuegt fuer die Audio-Reihenfolge (kein
-- Krypto-Bedarf).
math.randomseed(math.floor((sys.now() or 0) * 1000) + 1)

------------------------------------------------------------
-- Hilfsfunktionen
------------------------------------------------------------

local function now() return sys.now() end

-- Hosted gibt resource-Optionen je nach Runtime-Version mal als String,
-- mal als Tabelle mit asset_name/filename zurück. Beide Formen abdecken.
local function resolve_resource(value)
    if type(value) == "string" then
        return (value ~= "" and value) or nil
    end
    if type(value) == "table" then
        local n = value.asset_name or value.filename or value.file
        return (n and n ~= "" and n) or nil
    end
    return nil
end

-- Typ eines Media-Assets bestimmen: zuerst Hosted-Metadaten, sonst über
-- die Endung erraten. Default ist "image" — funktioniert auf jedem Pi.
-- Endungs-Whitelist konservativ: info-beamer dokumentiert nur MP4 als
-- Video-Container; m4v ist Suffix-Variante, mov teilt das ISO-BMFF-
-- Layout und wird vom MMAL-Demuxer in der Praxis akzeptiert. webm/
-- mkv/avi sind nicht als unterstuetzt dokumentiert — solche Dateien
-- werden als "image" eingestuft und scheitern beim Image-Load mit
-- klarer Fehlermeldung, statt im Video-Pfad undefiniert wegzubrechen.
-- Identische Liste wie VIDEO_EXTENSIONS im service-Sidecar.
local function media_type_for(value, name)
    if type(value) == "table" then
        if value.type == "video" then return "video" end
        if value.type == "image" then return "image" end
    end
    if name then
        local ext = name:lower():match("%.([%w]+)$") or ""
        if ext == "mp4" or ext == "m4v" or ext == "mov" then
            return "video"
        end
    end
    return "image"
end

-- Lädt ein Media-Asset entsprechend seines Typs. Videos werden mit
-- raw=true (GL-Pipeline) geladen. with_audio steuert pro Slot, ob
-- ein Audio-Track mitgeladen wird — das Hintergrund-Video bekommt
-- audio=false, weil sein Frame-Strom durchgehend visuell laufen muss
-- und info-beamers :stop() Audio nicht ohne Video muten kann. paused
-- =true, weil update_media_slot direkt nach load :start() aufruft
-- (so beginnt der Decoder unter unserer Kontrolle). Der pcall faengt
-- generische Lade-Fehler ab (Codec/Container nicht verarbeitbar,
-- Datei kaputt, Decoder-Slot anderweitig belegt) — auf Pi 5 wird
-- H.264 in Software dekodiert (kein HW-Decoder mehr in der VPU),
-- funktioniert aber, nur mit hoeherer CPU-Last.
local function load_media(name, kind, with_audio)
    if kind == "video" then
        return pcall(resource.load_video, {
            file   = name,
            looped = true,
            raw    = true,
            audio  = with_audio and true or false,
            paused = true,
        })
    end
    return pcall(resource.load_image, {file = name})
end

local function dispose_list(list)
    for _, s in ipairs(list or {}) do
        if s.res then
            pcall(function() s.res:dispose() end)
        end
    end
end

-- Sliding-Window fuer Image-Slide-Preload. Auf Pi 3B (256 MiB CMA) hat
-- jede 1920x1080-RGBA-Textur ~8 MB GPU-RAM Footprint; lange Playlists
-- vollstaendig vorzuladen sprengt das CMA und triggert "Cannot alloc
-- texture: out of memory" mit Watchdog-Reboot. Stattdessen: nur
-- current_idx + (SLIDE_WINDOW-1) Folgefolien als Texturen halten, der
-- Rest bleibt Metadaten-only. Reconcile laeuft am Frame-Ende.
--
-- Das Window ist zyklisch: am Playlist-Ende wrappt es zu slides[1]
-- zurueck, sodass am letzten Slide schon der naechste Cycle-Wrap-
-- Target im Vorrat liegt. Ohne Wrap-Around muesste slides[1] am
-- Cycle-Ende per Transition-Gate "kalt" geladen werden — das wuerde
-- nicht nur einen sichtbaren Delay produzieren, sondern auch die
-- Sequentialitaets-Garantie brechen, weil ein ausserhalb des
-- linearen Windows gestarteter Decode von any_image_in_flight()
-- nicht gesehen wuerde und reconcile_window-Phase 2 parallel
-- pending_slides[1] anstossen koennte.
--
-- Window-Groesse 5: deckt sicher auch laengere Ketten kurzer
-- Slide-Dauern ab (Transition-Gate verzoegert ohnehin, falls die
-- Naechste noch nicht ready ist; das Window dient als Vorrat).
-- Peak-GPU-Footprint bleibt mit 5 × 8 MB = 40 MB weit unter dem
-- CMA-Budget.
local SLIDE_WINDOW = 5

-- Liefert die zyklischen Indizes des aktuellen Sliding-Windows.
-- Bei n < SLIDE_WINDOW wird nur n-mal iteriert (kein doppelter
-- Slot). Reihenfolge: current_idx zuerst, dann monoton steigend
-- mit Wrap-Around.
local function window_indices(start_idx, n)
    local count = math.min(SLIDE_WINDOW, n)
    local start = math.max(1, start_idx or 1)
    local indices = {}
    for i = 0, count - 1 do
        indices[i + 1] = ((start - 1 + i) % n) + 1
    end
    return indices
end

-- Image-Resource eines Slots freigeben, mit Handoff fuer
-- weiterlaufende Referenzen:
--   * outgoing            : Cycle-Crossfade-Quelle
--   * pending_image_hold  : Multi-Frame-Hold beim Image->Video-Wechsel
-- In beiden Faellen markieren wir dispose_after, statt direkt zu
-- disposen — der jeweilige Aufloeser uebernimmt die Verantwortung,
-- sobald die Referenz nicht mehr gebraucht wird. Sonst wuerde der
-- laufende Cycle-Fade bzw. der noch zu zeichnende Hold ploetzlich
-- auf eine disposede Textur greifen.
local function dispose_slot_resource(slot)
    if not slot or not slot.res then return end
    if outgoing and outgoing.res == slot.res then
        outgoing.dispose_after = true
    elseif pending_image_hold and pending_image_hold.res == slot.res then
        pending_image_hold.dispose_after = true
    else
        pcall(function() slot.res:dispose() end)
    end
    slot.res = nil
end

-- Image-Hold aufloesen. Disposed die Resource nur, wenn die
-- Disposal-Verantwortung im Verlauf an den Hold uebergegangen ist
-- (dispose_after=true) — ansonsten gehoert die Resource weiter dem
-- urspruenglichen Slot bzw. wurde dort schon freigegeben.
local function clear_pending_image_hold()
    if not pending_image_hold then return end
    if pending_image_hold.dispose_after then
        pcall(function() pending_image_hold.res:dispose() end)
    end
    pending_image_hold = nil
end

-- Image-Resource ist draw-ready, sobald der async Decoder fertig ist.
-- info-beamer 2.x liefert :state() == "loaded" fuer Image-Resources;
-- als Fallback (aeltere Builds, fehlende Methode) prueft :size() — eine
-- nicht dekodierte Textur meldet 0x0. Bei Lade-Fehlern (slot.failed)
-- gilt der Slot als "ready", damit der Render-Loop ueber kaputte
-- Folien nicht endlos haengt — draw_fit(nil) faellt dann auf reines
-- BG zurueck.
--
-- :state() == "error" (Decode-Fehler nach erfolgreichem Load-Aufruf,
-- z.B. korrupte Datei, unsupported PNG-Variante) markiert den Slot
-- als failed, gibt die GPU-Resource sofort frei (sonst weiter
-- belegtes GPU-RAM und Render-Pfade wuerden gegen die kaputte
-- Textur zeichnen) und liefert true zurueck — andernfalls bliebe der
-- Slot permanent "not ready" und wuerde den globalen
-- any_image_in_flight()-Gate dauerhaft blockieren.
-- Unbekannte States (zukuenftige info-beamer-Versionen, Race-
-- Conditions) fallen auf den :size()-Heuristik-Pfad zurueck, statt
-- fix mit false zu antworten.
local function image_ready(slot)
    if not slot then return false end
    if slot.failed then return true end
    local res = slot.res
    if not res then return false end
    local ok, st = pcall(function() return res:state() end)
    if ok and type(st) == "string" then
        if st == "loaded" then return true end
        if st == "error"  then
            slot.failed = true
            print("Folie nicht dekodierbar: " .. tostring(slot.file))
            dispose_slot_resource(slot)
            return true
        end
        if st == "loading" then return false end
        -- unbekannter State: defensiver Fallback ueber :size()
    end
    local ok2, w, h = pcall(function() return res:size() end)
    return ok2
       and (tonumber(w) or 0) > 0
       and (tonumber(h) or 0) > 0
end

-- Reine Resource-Drawable-Pruefung ohne Slot-Bezug — fuer Stellen,
-- an denen wir nur ein nacktes resource-Handle haben (z.B.
-- outgoing.res im Cycle-Crossfade, das nach set_outgoing nicht mehr
-- mit einem Slot verknuepft ist). Im Gegensatz zu image_ready/
-- image_drawable: keine Seiteneffekte (kein slot.failed-Setting,
-- kein dispose). Logik mirror't den loaded/size-Pfad aus image_ready.
local function resource_drawable(res)
    if not res then return false end
    local ok, st = pcall(function() return res:state() end)
    if ok and type(st) == "string" then
        return st == "loaded"
    end
    local ok2, w, h = pcall(function() return res:size() end)
    return ok2
       and (tonumber(w) or 0) > 0
       and (tonumber(h) or 0) > 0
end

-- Image-Slot ist konkret zeichenbar: Resource existiert, ist
-- erfolgreich dekodiert und nicht als failed markiert. Strenger
-- als image_ready() — letztere liefert aus Gate-Sicht true fuer
-- failed-Slots, damit der globale In-Flight-Gate nicht permanent
-- blockt; im Render-Pfad ist diese Sicht falsch, weil ein failed-
-- Slot keinen halben Crossfade zeigen soll, sondern auf
-- draw_fit(nil) -> reines BG zurueckfaellt. Wird bei Crossfade-
-- Entscheidungen genutzt (Cycle-Fade can_fade, Out-Fade-Branch).
--
-- Reihenfolge: image_ready ZUERST aufrufen — der Aufruf kann
-- slot.failed=true setzen und slot.res=nil disposen (state()=="error"-
-- Branch). Wenn wir failed/res VOR image_ready pruefen, sehen wir
-- den State VOR dem Uebergang und liefern faelschlich true; das
-- wuerde draw_crossfade mit nil-Resource aufrufen.
local function image_drawable(slot)
    if not slot or slot.kind ~= "image" then return false end
    if not image_ready(slot) then return false end
    return slot.res ~= nil and not slot.failed
end

-- Asynchron einen Image-Slot laden. Idempotent: wiederholte Aufrufe
-- waehrend des Decodes sind no-ops. Video-Slots sind explizit
-- ausgenommen — sie laufen ueber fg_video_load (eigener Lifecycle,
-- nur ein Decoder gleichzeitig auf Pi 3B).
local function preload_slot(slot)
    if not slot                    then return end
    if slot.kind ~= "image"        then return end
    if slot.res or slot.failed     then return end
    local ok, res = pcall(resource.load_image, {file = slot.file})
    if ok and res then
        slot.res = res
    else
        slot.failed = true
        print("Folie nicht ladbar: " .. tostring(slot.file))
    end
end

-- Image-Slot disposen, wenn er aus dem Vorlade-Fenster faellt.
-- dispose_slot_resource uebernimmt das Outgoing-Handoff fuer
-- Resources, die gerade vom Cycle-Crossfade gehalten werden.
local function unload_slot(slot)
    if not slot or not slot.res    then return end
    if slot.kind ~= "image"        then return end
    dispose_slot_resource(slot)
end

-- Returns true wenn aktuell irgendwo ein Image-Decode in Flight ist
-- (s.res gesetzt, aber noch nicht "loaded"). Geprueft wird sowohl
-- das aktuelle (zyklische) slides-Window als auch pending_slides[1]
-- — beide teilen sich den globalen In-Flight-Gate, damit auf Pi 3B
-- nie zwei PNG-Decodes parallel laufen.
local function any_image_in_flight(start_idx)
    local n = #slides
    if n == 0 then
        if pending_slides and pending_slides[1] then
            local p = pending_slides[1]
            if p.kind == "image" and p.res and not image_ready(p) then
                return true
            end
        end
        return false
    end
    for _, idx in ipairs(window_indices(start_idx, n)) do
        local s = slides[idx]
        if s and s.kind == "image" and s.res and not image_ready(s) then
            return true
        end
    end
    if pending_slides and pending_slides[1] then
        local p = pending_slides[1]
        if p.kind == "image" and p.res and not image_ready(p) then
            return true
        end
    end
    return false
end

-- Stellt sicher, dass das zyklische Window geladen ist und alle
-- anderen Slots disposed. Aufruf am Frame-Ende.
--
-- Loads laufen sequenziell: pro Aufruf wird hoechstens EIN neuer
-- Decode-Task an den Threadpool gegeben, und nur wenn weder im
-- Window noch in pending_slides[1] ein Decode in Flight ist.
-- Reihenfolge: aktuelles Window zuerst (sichtbarer Bedarf in
-- monotoner Slide-Reihenfolge inkl. Wrap-Around), dann
-- pending_slides[1] (wird erst beim naechsten Cycle-Wrap als
-- Crossfade-Target gebraucht). Auf Pi 3B verhindert das
-- Lastpeaks (parallele PNG-Decodes konkurrieren um CPU, RAM und
-- GEM-Allokationen — derselbe Druck, der den urspruenglichen OOM
-- ausgeloest hat).
--
-- Performance: die Unload-Phase iteriert ueber alle n Slides und
-- aendert sich nur, wenn sich das Window (start, n) oder die
-- slides-Liste selbst aendern. Bei langer Playlist und 50 fps
-- waere O(n) pro Frame unnoetig teuer auf Pi 3B — daher cachen
-- wir (start, n, slides_id) und ueberspringen die Unload-Phase,
-- wenn sich nichts geaendert hat. swap_slides invalidiert den
-- Cache via reconcile_window_invalidate().
local last_window_start, last_window_n, last_window_id = nil, nil, nil

local function reconcile_window_invalidate()
    last_window_start, last_window_n, last_window_id = nil, nil, nil
end

-- Pendant zum normalen Window-Reconcile fuer den IDLE-State: laedt
-- ausschliesslich pending_slides[1], damit der IDLE->PLAYING-
-- Uebergang ohne sichtbare Decode-Pause erfolgen kann. Bewusst KEINE
-- Phase-1-Preloads fuer das alte slides-Window — slides wird in IDLE
-- ohnehin nicht gerendert; ein Phase-1-Decode wuerde via globalem
-- In-Flight-Gate den pending[1]-Decode aufschieben (auf Pi 3B
-- mehrere Frames pro Slot) und damit den Uebergang verzoegern.
-- Auch keine Unload-Phase: bestehendes slides-Window bleibt geladen,
-- damit ein spaeteres Re-PLAYING ueber swap_slides via File-Keyed-
-- Cache effizient bleibt.
--
-- any_image_in_flight deckt sowohl bereits-laufende slides- als auch
-- pending-Decodes ab — damit bleibt die Sequentialitaets-Garantie
-- (kein paralleler Decode auf Pi 3B) auch dann erhalten, wenn slides
-- aus einer vorigen PLAYING-Phase noch einen Decode in Flight hat.
local function preload_pending_first()
    if not pending_slides or not pending_slides[1] then return end
    local p = pending_slides[1]
    if p.kind ~= "image"           then return end
    if p.res or p.failed           then return end
    if any_image_in_flight(1)      then return end
    preload_slot(p)
end

local function reconcile_window(start_idx)
    local n = #slides
    if n == 0 then
        reconcile_window_invalidate()
        -- Keine slides → ausschliesslich pending_slides[1] preloaden.
        preload_pending_first()
        return
    end
    local start = math.max(1, start_idx or 1)
    local indices = window_indices(start, n)
    if last_window_start ~= start or last_window_n ~= n
       or last_window_id ~= slides then
        local in_window = {}
        for _, idx in ipairs(indices) do in_window[idx] = true end
        for i = 1, n do
            if not in_window[i] then
                unload_slot(slides[i])
            end
        end
        last_window_start, last_window_n, last_window_id = start, n, slides
    end
    if any_image_in_flight(start_idx) then return end
    -- Phase 1: Aktuelles Window auffuellen (sichtbarer Bedarf zuerst,
    -- in monotoner Slide-Reihenfolge mit Wrap-Around).
    for _, idx in ipairs(indices) do
        local s = slides[idx]
        if s and s.kind == "image" and not s.res and not s.failed then
            preload_slot(s)
            return
        end
    end
    -- Phase 2: pending_slides[1] vorladen — wird beim naechsten
    -- Cycle-Wrap als Crossfade-Target gebraucht (nur wenn ein
    -- Manifest-Update aktiv ist; sonst greift der Wrap-Around des
    -- aktiven Windows). Erst hier, weil der aktuelle Bedarf Vorrang
    -- hat. Slot 2..N von pending werden erst nach dem Swap durch
    -- reconcile in Folgeframes nachgezogen.
    if pending_slides and pending_slides[1] then
        local p = pending_slides[1]
        if p.kind == "image" and not p.res and not p.failed then
            preload_slot(p)
        end
    end
end

-- Dezibel → linearer Faktor [0..1] für info-beamers :volume()-API.
-- 0 dB = 1.0 (unity), -6 dB ≈ 0.5 (halbe Amplitude), -20 dB = 0.1.
-- Werte ≤ -60 dB auf 0 clampen (praktisch stumm), Werte ≥ 0 dB auf
-- 1 (Stream-Audio kann von info-beamer nicht verstärkt, nur
-- abgesenkt werden).
local function db_to_linear(db)
    if db == nil  then return 1   end
    if db <= -60  then return 0   end
    if db >=   0  then return 1   end
    return 10 ^ (db / 20)
end

-- dB-Wert auf [-60, 0] clampen. Stream-Audio kann von info-beamer
-- nicht verstaerkt werden, und unterhalb von -60 dB ist alles
-- praktisch stumm. Default 0 fuer nil (kein Pegelversatz).
local function clamp_db(db)
    if type(db) ~= "number" then return 0 end
    if db >   0  then return 0   end
    if db < -60  then return -60 end
    return db
end

-- URL-Sanitizer: percent-kodiert alle Bytes >= 0x80 (Non-ASCII).
-- Hintergrund: wenn die im Setup hinterlegte Stream-URL roh-UTF-8
-- enthaelt (z. B. "ß" als 0xC3 0x9F), liefert der HTTP-Server fuer
-- den so kodierten Pfad meist 404 — und ein bekannter SIGSEGV im
-- info-beamer-Audio-Worker beim Verarbeiten dieses 404 reisst den
-- gesamten Node samt Watchdog im Sekundentakt mit. Idempotent: bereits
-- prozentkodierte URLs (rein ASCII) bleiben unveraendert, doppelte
-- Kodierung kann also nicht auftreten.
local function sanitize_url(url)
    if type(url) ~= "string" or url == "" then return url end
    return (url:gsub("[\128-\255]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Englische Wochentag-/Monatsnamen durch deutsche ersetzen. Wird auf
-- die Ausgabe von os.date() angewendet, weil info-beamer-Lua mit
-- C-Locale läuft (=> englische %A/%B/%a/%b). Frontier-Patterns
-- (%f[%a]…%f[%A]) sorgen für Wortgrenzen — sonst würde "Mon" im
-- bereits ersetzten "Montag" wieder zu "Mo" werden.
--
-- Reihenfolge: vollständige Namen ZUERST, dann Abkürzungen. Sonst
-- könnte z. B. "Mar" das "Mar"-Präfix von "March" ersetzen, bevor
-- die volle Form drankommt.
local DE_REPLACEMENTS = {
    -- Vollständige Wochentage
    {"Wednesday", "Mittwoch"},
    {"Thursday",  "Donnerstag"},
    {"Saturday",  "Samstag"},
    {"Tuesday",   "Dienstag"},
    {"Monday",    "Montag"},
    {"Friday",    "Freitag"},
    {"Sunday",    "Sonntag"},
    -- Vollständige Monate
    {"September", "September"},
    {"February",  "Februar"},
    {"November",  "November"},
    {"December",  "Dezember"},
    {"October",   "Oktober"},
    {"January",   "Januar"},
    {"August",    "August"},
    {"March",     "März"},
    {"April",     "April"},
    {"June",      "Juni"},
    {"July",      "Juli"},
    -- Abgekürzte Wochentage
    {"Mon", "Mo"},
    {"Tue", "Di"},
    {"Wed", "Mi"},
    {"Thu", "Do"},
    {"Fri", "Fr"},
    {"Sat", "Sa"},
    {"Sun", "So"},
    -- Abgekürzte Monate (nur die, die sich vom Englischen unterscheiden)
    {"Mar", "Mär"},
    {"May", "Mai"},
    {"Oct", "Okt"},
    {"Dec", "Dez"},
}

local function localize_de(text)
    for _, pair in ipairs(DE_REPLACEMENTS) do
        text = text:gsub("%f[%a]" .. pair[1] .. "%f[%A]", pair[2])
    end
    return text
end

-- Zeit-Overlay-Schrift bei Asset-Wechsel neu laden.
local function update_time_font(name)
    if name == time_overlay.font_file then return end
    if time_overlay.font_res then
        pcall(function() time_overlay.font_res:dispose() end)
    end
    time_overlay.font_res  = nil
    time_overlay.font_file = name
    if not name then return end
    local ok, f = pcall(resource.load_font, name)
    if ok and f then
        time_overlay.font_res = f
    else
        print("Zeit-Schrift nicht ladbar: " .. name)
    end
end

-- Cornerlogo-Asset bei Wechsel neu laden.
local function update_corner_logo(name)
    if name == corner_logo.file then return end
    if corner_logo.res then
        pcall(function() corner_logo.res:dispose() end)
    end
    corner_logo.res  = nil
    corner_logo.file = name
    if not name then return end
    local ok, r = pcall(resource.load_image, {file = name})
    if ok and r then
        corner_logo.res = r
    else
        print("Cornerlogo nicht ladbar: " .. name)
    end
end

------------------------------------------------------------
-- Crossfade-Shader (prämultiplizierte-Alpha-Lerp)
------------------------------------------------------------
-- Standard-Alphablending mit zwei :draw-Aufrufen produziert keine
-- saubere Lerp zwischen zwei RGBA-Texturen — zweiter Draw = src*p +
-- (1-p) * (1-p)*A statt p*B + (1-p)*A. Die Folge: an Stellen, wo
-- Folie A opak und Folie B transparent ist (oder umgekehrt), gibt es
-- entweder einen abrupten Wechsel am Fade-Ende oder ein Helligkeits-
-- Loch in der Mitte des Fades.
--
-- Lösung: fragment-shader, der beide Texturen sampelt, in
-- prämultipliziertem Alpha-Raum lerpt (sodass transparente Pixel
-- wirklich keinen Color-Beitrag haben) und das Ergebnis als
-- straight-alpha herausgibt. Der nachgelagerte Standard-Composite
-- ueber den Hintergrund-Layer ist dann mathematisch korrekt fuer
-- alle Transparenz-Kombinationen.
--
-- WICHTIG: info-beamer liefert PNG-Texturen bereits prämultipliziert
-- (tex.rgb = color*A). Daher KEIN nochmaliges `a.rgb*a.a` — sonst
-- waere der Foreground-Beitrag im Shader-Pfad um Faktor A dunkler
-- als im :draw-Pfad (sichtbar als plötzlicher Helligkeitsabfall an
-- Fade-Beginn in halbtransparenten Folienbereichen).
local crossfade_shader
do
    local ok, sh = pcall(resource.create_shader, [[
        uniform sampler2D from_tex;
        uniform sampler2D to_tex;
        uniform float progress;
        varying vec2 TexCoord;
        void main() {
            vec4 a = texture2D(from_tex, TexCoord);
            vec4 b = texture2D(to_tex,   TexCoord);
            vec4 r_pre = mix(a, b, progress);
            if (r_pre.a > 0.0) {
                gl_FragColor = vec4(r_pre.rgb / r_pre.a, r_pre.a);
            } else {
                gl_FragColor = vec4(0.0);
            }
        }
    ]])
    if ok then
        crossfade_shader = sh
    else
        print("Crossfade-Shader konnte nicht kompiliert werden — fallback auf zwei-Draw-Compositing mit leichten Artefakten an Transparenz-Kanten.")
    end
end

-- Mathematisch sauberer Crossfade zwischen zwei Folien-Ressourcen.
-- Die Geometrie kommt vom :draw der ersten Textur, der Shader
-- ersetzt jedoch die Fragment-Farbe — beide Texturen werden über
-- die Uniforms gesampelt.
local function draw_crossfade(from_res, to_res, progress)
    if not from_res or not to_res then return end
    if crossfade_shader then
        crossfade_shader:use{
            from_tex = from_res,
            to_tex   = to_res,
            progress = progress,
        }
        from_res:draw(0, 0, WIDTH, HEIGHT)
        crossfade_shader:deactivate()
    else
        -- Fallback (Compositing-Artefakte an Transparenz-Kanten).
        from_res:draw(0, 0, WIDTH, HEIGHT, 1)
        to_res:draw(0, 0, WIDTH, HEIGHT, progress)
    end
end

------------------------------------------------------------
-- Audio-Routing
------------------------------------------------------------
-- info-beamer setzt audio=true beim Laden — runtime gibt's keinen
-- Mute-Toggle. pause/start eines Videos hält Decoder + Audio an.
-- Wir laden beide Videos initial paused, und genau eines wird per
-- :start() aktiv — entweder das Hintergrund- oder das Backup-Video.

local function video_pause(slot)
    if slot.kind == "video" and slot.res then
        pcall(function() slot.res:stop() end)
    end
end

local function video_play(slot)
    if slot.kind == "video" and slot.res then
        pcall(function() slot.res:start() end)
    end
end

-- (Re)load des Audio-Streams via resource.load_audio. paused=true,
-- damit update_audio_routing im nächsten Frame über :volume(0/1)
-- entscheidet. last_attempt setzt die Cooldown-Schranke für den
-- Watchdog, damit fehlerhafte Streams nicht in einer Reconnect-
-- Schleife landen. Vor dem Load wird die URL via sanitize_url percent-
-- kodiert (s. dort) — der Vergleich loaded_url ↔ audio_stream.url
-- bleibt absichtlich gegen die Roh-Form, damit Setup-Aenderungen
-- erkannt werden.
local function load_audio_stream()
    audio_stream.last_attempt = sys.now()

    local request_url = sanitize_url(audio_stream.url)
    local ok, r = pcall(resource.load_audio, {
        file   = request_url,
        buffer = audio_stream.buffer,
        paused = true,
    })
    if ok and r then
        audio_stream.res = r
        audio_stream.loaded_url = audio_stream.url
        pcall(function() r:volume(0) end)  -- gemutet starten
        pcall(function() r:start() end)     -- Decoder anwerfen
        audio_active = nil                  -- Routing-Neuevaluation
        if request_url ~= audio_stream.url then
            print("Audio-Stream geladen (URL prozentkodiert): " .. request_url)
        else
            print("Audio-Stream geladen: " .. request_url)
        end
    else
        audio_stream.res = nil
        audio_stream.loaded_url = nil
        print(string.format(
            "Audio-Stream nicht ladbar: %s (Fehler: %s)",
            request_url, tostring(r)
        ))
    end
end

-- Wird pro Frame aufgerufen. Disposed den Stream, wenn er deaktiviert,
-- die URL geändert oder der Decoder in "error"/"finished" gelandet ist;
-- lädt ihn neu, sobald die Cooldown-Periode (retry_after) abgelaufen ist.
local function check_audio_stream_health()
    -- Audio-Capability nicht verfügbar (z. B. Pi ohne Sound-Hardware
    -- oder info-beamer-Build ohne Audio-Support) → Feature stillgelegt.
    if not audio_stream.available then return end

    if not audio_stream.enabled or audio_stream.url == "" then
        if audio_stream.res then
            pcall(function() audio_stream.res:dispose() end)
            audio_stream.res = nil
            audio_stream.loaded_url = nil
        end
        return
    end

    -- URL hat sich seit dem Load geändert → bestehenden Stream killen.
    if audio_stream.res and audio_stream.loaded_url ~= audio_stream.url then
        pcall(function() audio_stream.res:dispose() end)
        audio_stream.res = nil
    end

    -- Health-Check via :state(). Werte: "loaded", "paused", "finished",
    -- "error". Bei den letzten beiden den Stream verwerfen und nach
    -- Cooldown neu aufbauen.
    if audio_stream.res then
        local ok, st = pcall(function() return audio_stream.res:state() end)
        if ok and (st == "error" or st == "finished") then
            print(string.format(
                "Audio-Stream state=%s — Reconnect in %d s",
                tostring(st), audio_stream.retry_after
            ))
            pcall(function() audio_stream.res:dispose() end)
            audio_stream.res = nil
        end
    end

    -- (Re)load nach Cooldown — nur wenn der Sidecar-Probe die URL
    -- gerade als erreichbar bestaetigt. Verhindert SIGSEGV im
    -- Audio-Worker bei kaputten URLs (Details s. audio_probe).
    -- Probe muss frisch sein (stale_after-Fenster) UND fuer die
    -- aktuell konfigurierte URL gelten — sonst koennte ein frisches
    -- "ok" der alten URL versehentlich den Load einer gerade
    -- geaenderten neuen URL freischalten.
    -- Bei fehlgeschlagener Probe wird kein last_attempt gesetzt —
    -- sobald die Probe wieder ok wird, soll im selben Frame
    -- geladen werden (kein zusaetzlicher retry_after-Cooldown).
    if not audio_stream.res
       and sys.now() - audio_stream.last_attempt >= audio_stream.retry_after then
        local probe_fresh = sys.now() - audio_probe.last_msg_at < audio_probe.stale_after
        local probe_matches = audio_probe.url == audio_stream.url
        if probe_fresh and probe_matches and audio_probe.ok == true then
            load_audio_stream()
        end
    end
end

-- Fisher-Yates-Shuffle in-place.
local function shuffle_array(arr)
    for i = #arr, 2, -1 do
        local j = math.random(i)
        arr[i], arr[j] = arr[j], arr[i]
    end
end

-- order neu aufbauen: Sequenz 1..N, optional gemischt. Der
-- Health-Check inkrementiert order_pos vor dem Load — Start mit 0
-- bedeutet: naechster Load liest order[1].
--
-- Wenn waehrend des Rebuilds gerade ein Track laeuft, richten wir
-- order_pos so aus, dass er auf seine neue Position in der Reihenfolge
-- zeigt. Dadurch laedt der naechste Wechsel den darauffolgenden Track
-- der neuen Reihenfolge, statt versehentlich wieder bei order[1]
-- anzufangen (was den gerade beendeten Track erneut spielen koennte).
-- Ist der laufende Track nicht (mehr) in der Liste, faellt order_pos
-- auf 0 zurueck — der naechste Load startet dann sauber von vorn.
local function rebuild_jukebox_order()
    audio_jukebox.order = {}
    for i = 1, #audio_jukebox.files do
        audio_jukebox.order[i] = i
    end
    if audio_jukebox.shuffle then
        shuffle_array(audio_jukebox.order)
    end

    audio_jukebox.order_pos = 0
    if audio_jukebox.loaded_file then
        for pos, idx in ipairs(audio_jukebox.order) do
            if audio_jukebox.files[idx] == audio_jukebox.loaded_file then
                audio_jukebox.order_pos = pos
                break
            end
        end
    end
end

local function dispose_jukebox_track()
    if audio_jukebox.res then
        pcall(function() audio_jukebox.res:dispose() end)
    end
    audio_jukebox.res         = nil
    audio_jukebox.loaded_file = nil
    audio_jukebox.last_state  = nil
end

-- Naechsten Filenamen aus der Reihenfolge holen. Am Listenende neu
-- mischen (falls shuffle aktiv) und wieder von vorn.
local function jukebox_next_file()
    if #audio_jukebox.order == 0 then return nil end
    audio_jukebox.order_pos = audio_jukebox.order_pos + 1
    if audio_jukebox.order_pos > #audio_jukebox.order then
        if audio_jukebox.shuffle then
            shuffle_array(audio_jukebox.order)
        end
        audio_jukebox.order_pos = 1
    end
    local idx = audio_jukebox.order[audio_jukebox.order_pos]
    return audio_jukebox.files[idx]
end

-- Naechsten Track laden, gemutet starten. update_audio_routing
-- entscheidet pro Frame, ob die Jukebox tatsaechlich hoerbar wird.
local function load_jukebox_track()
    audio_jukebox.last_attempt = sys.now()

    local file = jukebox_next_file()
    if not file then return end

    local ok, r = pcall(resource.load_audio, {
        file   = file,
        paused = true,
    })
    if ok and r then
        audio_jukebox.res         = r
        audio_jukebox.loaded_file = file
        audio_jukebox.last_state  = nil
        pcall(function() r:volume(0) end)   -- gemutet starten
        pcall(function() r:start() end)      -- Decoder anwerfen
        audio_active = nil                   -- Routing-Neuevaluation
        print("Jukebox-Track geladen: " .. file)
    else
        audio_jukebox.res         = nil
        audio_jukebox.loaded_file = nil
        print(string.format(
            "Jukebox-Track nicht ladbar: %s (Fehler: %s)",
            file, tostring(r)
        ))
    end
end

-- Wird pro Frame aufgerufen. Disposed den aktuellen Track, sobald
-- er fertig oder fehlerhaft ist; laedt den naechsten nach Cooldown.
-- Keine endlosen Retry-Schleifen auf demselben File: bei "error"
-- ruecken wir in der Reihenfolge weiter.
--
-- Bei aktivem Stream (Stream > Jukebox in der Routing-Prioritaet, kein
-- Fallback) wird die Jukebox nie hoerbar — wir disposen den Decoder
-- und laden nichts neu, statt unnoetig Resourcen zu verbrennen. Sobald
-- der Stream im Setup deaktiviert wird, springt der Watchdog wieder
-- an.
local function check_audio_jukebox_health()
    if not audio_jukebox.available then return end

    local stream_dominates = audio_stream.enabled

    if not audio_jukebox.enabled
       or #audio_jukebox.files == 0
       or stream_dominates then
        if audio_jukebox.res then
            dispose_jukebox_track()
        end
        return
    end

    if audio_jukebox.res then
        local ok, st = pcall(function() return audio_jukebox.res:state() end)
        if ok then
            audio_jukebox.last_state = st
            if st == "finished" or st == "error" then
                if st == "error" then
                    print(string.format(
                        "Jukebox-Track-Fehler: %s — naechster Track",
                        tostring(audio_jukebox.loaded_file)
                    ))
                end
                dispose_jukebox_track()
            end
        end
    end

    if not audio_jukebox.res
       and sys.now() - audio_jukebox.last_attempt >= audio_jukebox.retry_after then
        load_jukebox_track()
    end
end

local function update_audio_routing()
    -- Audio-Quellen mit Prioritaet:
    --   1. BACKUP-Video (in IDLE mit Backup als Video)
    --   2. Stream (wenn audio_stream.enabled + Resource ready)
    --   3. Jukebox (wenn audio_jukebox.enabled + Resource ready)
    --   4. BG-Video (nur wenn mit Audio geladen — d. h. weder Stream
    --      noch Jukebox aktiviert, sonst hat BG audio_loaded = false)
    -- Kein dynamisches Fallback zwischen Stream/Jukebox/BG bei Ausfall
    -- der hoeher priorisierten Quelle: ist Stream konfiguriert aber
    -- gerade nicht ladbar, bleibt's stumm — wir wechseln NICHT auf
    -- Jukebox/BG-Audio. Konsistent mit Setup-Erwartung "wenn Stream
    -- aktiv, dominiert er".
    local target
    if state == STATE_IDLE
       and backup_slot.kind == "video" and backup_slot.res then
        target = "backup"
    elseif audio_stream.enabled then
        if audio_stream.res then target = "stream" end
    elseif audio_jukebox.enabled then
        if audio_jukebox.res then target = "jukebox" end
    elseif background_slot.kind == "video"
       and background_slot.res
       and background_slot.audio_loaded then
        target = "background"
    end

    if target == audio_active then return end

    -- Mute alle Nicht-Ziel-Audio-Quellen. Bei Videos :stop() (pausiert
    -- auch den Frame-Strom — fuer Backup egal weil off-screen, fuer
    -- BG nur dann aufgerufen, wenn es ueberhaupt mit Audio geladen
    -- ist; sonst gibt's nichts zu muten und :stop() wuerde nur den
    -- Visual-Freeze ausloesen). Beim Stream/Jukebox :volume(0), damit
    -- der Decoder verbunden bleibt und ein Reaktivieren ohne Latenz
    -- hoerbar ist.
    if target ~= "backup"
       and backup_slot.kind == "video" and backup_slot.res then
        pcall(function() backup_slot.res:stop() end)
    end
    if target ~= "background"
       and background_slot.kind == "video"
       and background_slot.res
       and background_slot.audio_loaded then
        pcall(function() background_slot.res:stop() end)
    end
    if target ~= "stream" and audio_stream.res then
        pcall(function() audio_stream.res:volume(0) end)
    end
    if target ~= "jukebox" and audio_jukebox.res then
        pcall(function() audio_jukebox.res:volume(0) end)
    end

    -- Aktiviere Ziel. Stream/Jukebox-Volume wird NICHT hier gesetzt,
    -- sondern pro Frame in apply_audio_levels() — damit der Ducking-
    -- Ramp (waehrend FG-Video laeuft) nicht von einem Routing-Edge
    -- ueberschrieben wird und neu aktivierte Quellen ggf. bereits
    -- mit reduziertem Pegel einsetzen.
    if target == "backup" then
        video_play(backup_slot)
    elseif target == "background" then
        video_play(background_slot)
    end

    audio_active = target
end

-- Pegel-Anwendung pro Frame: rampt audio_ducking.factor linear in
-- der Zeit Richtung target_factor (1 = volles Ducking, 0 = kein
-- Ducking) und schreibt den amplituden-linear gemischten Pegel auf
-- die aktive Stream/Jukebox-Quelle.
--
-- Hoer-Begruendung fuer amplitude-linear statt dB-linear: dB-lineare
-- Rampen klingen besonders bei Fade-zu-Stumm (-60 dB) ungleichmaessig,
-- weil der lineare Amplituden-Verlauf exponentiell aussieht — die
-- ersten 30-40 % der Rampe machen subjektiv 90 % der Pegel-Aenderung,
-- der Rest trudelt unhoerbar aus. Linear in Amplitude verteilt die
-- wahrnehmbare Bewegung gleichmaessig ueber die Fade-Dauer.
--
-- Backup-/BG-Video-Audio nutzen :start()/:stop()-Mute (siehe
-- update_audio_routing) und sind hier nicht beteiligt — auf Pi 3B
-- ist BG-Video waehrend FG ohnehin via background_yield() disposed,
-- auf Pi 4+ wird genauso geyielded; ein FG-Video laeuft also nie
-- parallel zu einer BG-Video-Audioquelle.
local function apply_audio_levels()
    -- Ducking nur bei negativem Konfigurationswert wirksam — 0 (oder
    -- ungueltig) deaktiviert das Feature.
    local cfg_db = CONFIG.audio_ducking_db or 0
    local target_factor = (fg_video.res and cfg_db < 0) and 1 or 0

    local now_t = sys.now()
    local dt = (audio_ducking.last_t and (now_t - audio_ducking.last_t)) or 0
    if dt < 0 then dt = 0 end
    audio_ducking.last_t = now_t

    local fade = CONFIG.audio_ducking_fade or 0
    if fade <= 0 then
        audio_ducking.factor = target_factor
    elseif audio_ducking.factor ~= target_factor then
        local rate = 1 / fade   -- volle Strecke (0..1) in fade Sekunden
        local diff = target_factor - audio_ducking.factor
        local step = rate * dt
        if math.abs(diff) <= step then
            audio_ducking.factor = target_factor
        elseif diff > 0 then
            audio_ducking.factor = audio_ducking.factor + step
        else
            audio_ducking.factor = audio_ducking.factor - step
        end
    end

    -- Amplituden-Mix zwischen Basispegel und gedrueckter Endpegel.
    -- Beide Endpunkte werden pro Frame neu aus volume_db + cfg_db
    -- gerechnet, sodass Live-Aenderungen am Setup sofort greifen.
    local function leveled(volume_db)
        local base_lin   = db_to_linear(volume_db)
        local ducked_lin = db_to_linear(volume_db + cfg_db)
        return base_lin + (ducked_lin - base_lin) * audio_ducking.factor
    end

    if audio_active == "stream" and audio_stream.res then
        local lvl = leveled(audio_stream.volume_db)
        pcall(function() audio_stream.res:volume(lvl) end)
    elseif audio_active == "jukebox" and audio_jukebox.res then
        local lvl = leveled(audio_jukebox.volume_db)
        pcall(function() audio_jukebox.res:volume(lvl) end)
    end
end

------------------------------------------------------------
-- Zyklus-Crossfade-Primitive
------------------------------------------------------------

local function end_cycle_fade()
    if outgoing then
        if outgoing.dispose_after then
            pcall(function() outgoing.res:dispose() end)
        end
        outgoing = nil
    end
end

local function set_outgoing(slide)
    end_cycle_fade()
    if not slide or not slide.res then return end
    outgoing = {
        res           = slide.res,
        kind          = slide.kind,
        dispose_after = false,   -- ggf. von swap_slides auf true geflippt
    }
    cycle_fade_start = now()
end

-- Tauscht slides-Liste atomar aus und gibt die Ressourcen der alten
-- Liste frei — mit Ausnahme der ggf. von outgoing referenzierten, für
-- die wir die Disposal-Verantwortung übernehmen, damit der Zyklus-
-- Crossfade die Textur noch zu Ende rendern kann.
--
-- File-Keyed-Cache: vor der Disposal-Phase laufen wir ueber die neue
-- Liste und uebernehmen fuer Image-Slides bereits geladene Resourcen
-- aus der alten Liste, sofern (file, kind) uebereinstimmen. Vermeidet
-- erzwungenen Re-Decode bei Manifest-Updates mit grosser Schnittmenge
-- (haeufige Faelle: Sidecar-Restart liefert byte-identisches Manifest;
-- nur einzelne Folien werden hinzugefuegt/entfernt). Doppelvorkommen
-- desselben Filenames werden eintrags-basiert gematcht — ein einmal
-- uebernommener alter Slot ist fuer weitere Matches gesperrt
-- (consumed[i]); doppelte Resourcen entstehen so nicht.
--
-- Video-Slides haben slot.res == nil (FG-Video lebt eigenstaendig in
-- fg_video.res, der Slide-Wechsel-Hook entscheidet ueber Reload bzw.
-- Preserve). Hier werden sie deshalb uebersprungen.
local function swap_slides(new_list)
    local old = slides

    local consumed = {}
    for _, ns in ipairs(new_list) do
        if ns.kind == "image" and not ns.res and not ns.failed then
            for i, oldslide in ipairs(old) do
                if not consumed[i]
                   and oldslide.kind == "image"
                   and oldslide.file == ns.file
                   and (oldslide.res or oldslide.failed) then
                    ns.res    = oldslide.res
                    ns.failed = oldslide.failed
                    consumed[i] = true
                    break
                end
            end
        end
    end

    slides = new_list
    for i, s in ipairs(old) do
        if s.res and not consumed[i] then
            if outgoing and outgoing.res == s.res then
                outgoing.dispose_after = true
            elseif pending_image_hold and pending_image_hold.res == s.res then
                pending_image_hold.dispose_after = true
            else
                pcall(function() s.res:dispose() end)
            end
        end
    end
    -- slides-Identitaet hat sich geaendert: reconcile_window-Cache
    -- invalidieren, damit die naechste Unload-Phase wieder laeuft.
    reconcile_window_invalidate()
end

------------------------------------------------------------
-- Media-Slot-Verwaltung
------------------------------------------------------------

local function update_media_slot(slot, cfg_value, default_name)
    local name = resolve_resource(cfg_value) or default_name
    if name == "" then name = nil end

    -- Reload, wenn der Filename ODER der gewuenschte Audio-Modus
    -- sich gegenueber dem zuletzt geladenen Stand unterscheidet.
    -- Audio-Mode-Wechsel passiert beim BG-Video, sobald audio_stream
    -- ein-/ausgeschaltet wird.
    if name == slot.file and slot.audio == slot.audio_loaded then return end

    if slot.res then
        pcall(function() slot.res:dispose() end)
    end
    slot.res, slot.kind, slot.file = nil, nil, name
    slot.audio_loaded = nil

    if not name then return end

    local kind = media_type_for(cfg_value, name)
    local ok, r = load_media(name, kind, slot.audio)
    if ok and r then
        slot.res, slot.kind = r, kind
        slot.audio_loaded = slot.audio
        -- raw-Video hinter die GL-Surface legen, damit transparente
        -- Folien-Pixel das Video durchscheinen lassen können.
        if kind == "video" and slot.layer ~= nil then
            pcall(function() r:layer(slot.layer) end)
            -- Visual-Playback sofort starten. paused=true im Load
            -- haelt Video- UND Audio-Decoder an; ohne diesen :start()
            -- bleibt das Bild eingefroren, sobald das Audio-Routing
            -- direkt auf eine andere Quelle (z. B. den Stream) zielt
            -- und video_play(slot) nie aufruft. Das nachfolgende
            -- :stop() im Routing pausiert auf info-beamer empirisch
            -- nur den Audio-Track, nicht den Frame-Strom — daher
            -- bleibt das Video sichtbar.
            pcall(function() r:start() end)
        end
    else
        local hint = (kind == "video") and " (Codec/Container moeglicherweise nicht unterstuetzt)" or ""
        print(slot.label .. " nicht ladbar: " .. name .. hint)
    end
end

------------------------------------------------------------
-- Foreground-Video / BG-Yield (fuer Video-Folien)
------------------------------------------------------------

-- FG-Video aus dem Speicher loesen. Wird beim Verlassen einer Video-
-- Folie und vor jedem Reload aufgerufen. :place(0,0,0,0) verhindert,
-- dass info-beamer das letzte Frame auf seinem Layer eingefroren stehen
-- laesst — sonst bliebe es bis zum naechsten Slide-Wechsel sichtbar.
local function fg_video_unload()
    if fg_video.res then
        pcall(function() fg_video.res:place(0, 0, 0, 0) end)
        pcall(function() fg_video.res:dispose() end)
    end
    fg_video.res, fg_video.file = nil, nil
end

-- FG-Video laden und starten. looped=false → laeuft bis "finished",
-- dann triggert der Render-Loop das Advance. audio=true: der Audio-Track
-- mischt sich automatisch in den info-beamer-Output, parallel zu Stream/
-- Jukebox/BG (siehe Datei-Header). Auf Pi 3B muss vor dem Load das BG-
-- Video via background_yield() weichen — das macht der Caller.
--
-- Rueckgabe: true bei erfolgreichem Load, false sonst (Caller kann dann
-- z. B. background_resume() aufrufen, statt das BG dauerhaft yielded
-- zu lassen). Kein Same-File-Shortcut: wenn der Hook erneut feuert
-- (= Slide-Wechsel auf direkt aufeinanderfolgenden gleichen Video-
-- Dateinamen), wollen wir die Wiedergabe zurueckspulen, nicht beim
-- "finished"-State haengen bleiben.
--
-- looped: bei Single-Video-Playlists (#slides == 1, einziger Slot
-- ist Video) lassen wir den Decoder selbst loopen — frame-genau,
-- ohne :dispose()+Reload-Luecke. Mehr-Slide-Playlists muessen
-- dagegen mit looped=false laden, damit state=="finished" das
-- Advance auf die naechste Folie ausloesen kann.
local function fg_video_load(slide, looped)
    fg_video_unload()
    local ok, r = pcall(resource.load_video, {
        file   = slide.file,
        looped = looped and true or false,
        raw    = true,
        audio  = true,
        paused = true,
    })
    if ok and r then
        pcall(function() r:layer(fg_video.layer) end)
        pcall(function() r:start() end)
        fg_video.res, fg_video.file = r, slide.file
        return true
    end
    print("FG-Video nicht ladbar: " .. tostring(slide.file))
    return false
end

-- Pi-3B-Engpass: nur ein H.264-Hardware-Decoder. Wenn eine Video-Folie
-- spielen soll, muss das BG-Video vorher KOMPLETT freigegeben werden
-- (:dispose), nicht nur :stop()'t — sonst behaelt manche info-beamer-
-- Build den Decoder-Slot weiter belegt und der FG-Load schlaegt fehl.
-- bg_yielded_state merkt sich Filename + Audio-Modus, damit
-- background_resume() die Resource beim Verlassen der Video-Folie ueber
-- update_media_slot wiederherstellen kann. Der config.json-Watch muss
-- waehrend bg_yielded_state ~= nil das BG NICHT laden — sonst greift
-- der Yield ins Leere; das wird im Watch-Handler abgefangen.
local bg_yielded_state = nil  -- {file, audio}

-- Yield NUR bei Video-BG: Image-BG belegt keinen Hardware-Decoder, ein
-- Dispose+Reload waere reine Verschwendung. Stattdessen wird ein Image-
-- BG einfach waehrend der Video-Folie nicht gezeichnet (s. Render-Loop:
-- show_video-Gate) — sonst wuerde es auf Layer 0 das FG-Video auf
-- Layer -1 verdecken.
local function background_yield()
    if background_slot.kind ~= "video" or not background_slot.res then
        return
    end
    bg_yielded_state = {
        file  = background_slot.file,
        audio = background_slot.audio,
    }
    pcall(function() background_slot.res:dispose() end)
    background_slot.res, background_slot.kind = nil, nil
    background_slot.file, background_slot.audio_loaded = nil, nil
    audio_active = nil   -- Routing zwingen, neu zu evaluieren
end

local function background_resume()
    if not bg_yielded_state then return end
    local restore = bg_yielded_state
    bg_yielded_state = nil
    background_slot.audio = restore.audio
    update_media_slot(background_slot, restore.file, nil)
    audio_active = nil
end

-- Cleanup-Helper fuer alle Pfade, die eine evtl. laufende Video-Folie
-- verlassen (IDLE-Uebergang, leere Playlist, ungueltige cur). Geht
-- bewusst auf BEIDE Indikatoren (fg_video.res ODER bg_yielded_state) —
-- bei einem fehlgeschlagenen fg_video_load ist fg_video.res = nil, aber
-- bg_yielded_state noch gesetzt; ohne den expliziten Check bliebe das
-- BG dauerhaft yielded (config-Watch laedt es absichtlich nicht nach).
local function leave_video_slide_if_active()
    if not (fg_video.res or bg_yielded_state) then return end
    fg_video_unload()
    background_resume()
end

------------------------------------------------------------
-- Konfiguration / Watch (Lua-relevante Optionen)
------------------------------------------------------------

util.file_watch("config.json", function(raw)
    local cfg = json.decode(raw)

    -- fade_duration kommt als ms aus dem Setup (UI-Skala) und wird
    -- intern in Sekunden gehalten, damit Differenzen mit sys.now()
    -- direkt vergleichbar sind.
    CONFIG.fade_duration    = (tonumber(cfg.fade_duration) or 500) / 1000
    CONFIG.default_duration = tonumber(cfg.default_duration) or 10

    -- Audio-Stream- UND Jukebox-Zustand ZUERST lesen — beide bestimmen
    -- gemeinsam, ob das Hintergrund-Video mit oder ohne Audio-Track
    -- geladen wird (s. background_slot-Kommentar). Sobald eine der
    -- beiden Quellen aktiv ist, soll BG-Video stumm laufen (visuell
    -- durchgehend, Audio kommt von hoeher priorisierter Quelle).
    -- update_media_slot disposed+reloadet das BG-Video automatisch beim
    -- Toggle ueber den slot.audio_loaded-Vergleich.
    audio_stream.enabled = cfg.audio_stream_enabled and true or false
    -- Whitespace trimmen, damit die URL identisch zu der vom Sidecar
    -- gepruften ist (Sidecar strippt im service vor Probe + IPC).
    -- Sonst wuerde audio_probe.url ~= audio_stream.url und der
    -- Reload-Gate dauerhaft blocken bei fuehrenden/trailing Spaces
    -- im Setup-Eintrag. Type-Guard: bei manuell kaputter config.json
    -- (Wert kein String) zurueckfallen auf "" statt :match auf einem
    -- Nicht-String aufzurufen, was den file_watch-Callback abbrechen
    -- wuerde.
    local stream_url = cfg.audio_stream_url
    if type(stream_url) ~= "string" then stream_url = "" end
    audio_stream.url       = stream_url:match("^%s*(.-)%s*$") or ""
    audio_stream.volume_db = clamp_db(tonumber(cfg.audio_stream_volume_db))

    -- Jukebox-Playlist parsen. Reihenfolge im Setup ist Reihenfolge
    -- der sequenziellen Wiedergabe. Leere/ungueltige Eintraege werden
    -- uebersprungen (Setup-Liste kann in info-beamer leere Slots haben).
    local new_files = {}
    if type(cfg.audio_jukebox_playlist) == "table" then
        for _, item in ipairs(cfg.audio_jukebox_playlist) do
            local name = item and resolve_resource(item.file)
            if name then
                new_files[#new_files + 1] = name
            end
        end
    end

    local new_shuffle = cfg.audio_jukebox_shuffle and true or false

    -- Aenderungen im laufenden Betrieb so schonend wie moeglich
    -- behandeln: Track laeuft weiter, wenn er noch in der Liste ist.
    local files_changed = (#new_files ~= #audio_jukebox.files)
    if not files_changed then
        for i, f in ipairs(new_files) do
            if f ~= audio_jukebox.files[i] then
                files_changed = true
                break
            end
        end
    end
    local shuffle_changed = (new_shuffle ~= audio_jukebox.shuffle)

    audio_jukebox.enabled   = cfg.audio_jukebox_enabled and true or false
    audio_jukebox.shuffle   = new_shuffle
    audio_jukebox.volume_db = clamp_db(tonumber(cfg.audio_jukebox_volume_db))
    audio_jukebox.files     = new_files

    -- Audio-Ducking: Absenkung waehrend FG-Video-Wiedergabe. clamp_db
    -- begrenzt auf [-60, 0]; Werte > 0 werden auf 0 gesetzt (= Feature
    -- deaktiviert), darunter ist die Quelle praktisch stumm. Fade-Dauer
    -- darf nicht negativ werden — 0 bedeutet "harter Sprung".
    CONFIG.audio_ducking_db = clamp_db(tonumber(cfg.audio_ducking_db))
    -- audio_ducking_fade kommt als ms aus dem Setup, intern in Sekunden
    -- (gleiche Skala wie sys.now()-Differenzen in apply_audio_levels).
    local fade_ms = tonumber(cfg.audio_ducking_fade)
    if fade_ms == nil or fade_ms < 0 then fade_ms = 250 end
    CONFIG.audio_ducking_fade = fade_ms / 1000

    if files_changed or shuffle_changed then
        rebuild_jukebox_order()
        -- Wenn der gerade gespielte Track aus der Liste entfernt wurde,
        -- direkt disposen — der Health-Check laedt dann den naechsten.
        if audio_jukebox.loaded_file then
            local still_present = false
            for _, f in ipairs(new_files) do
                if f == audio_jukebox.loaded_file then
                    still_present = true
                    break
                end
            end
            if not still_present then
                dispose_jukebox_track()
            end
        end
    end

    update_media_slot(backup_slot, cfg.backup_media, "empty.png")

    -- BG-Slot: waehrend einer Video-Folie ist das BG-Video via
    -- background_yield() disposed (Pi 3B Decoder-Engpass). Wir fuettern
    -- die neuen Werte in bg_yielded_state, damit background_resume()
    -- spaeter die richtige Resource wiederherstellt — KEIN update_media_
    -- slot, sonst kollidiert der Reload mit dem laufenden FG-Video.
    local bg_audio_now = not (audio_stream.enabled or audio_jukebox.enabled)
    if bg_yielded_state then
        bg_yielded_state.audio = bg_audio_now
        bg_yielded_state.file  = cfg.background_media
        background_slot.audio  = bg_audio_now  -- bleibt fuer spaeter konsistent
    else
        background_slot.audio = bg_audio_now
        update_media_slot(background_slot, cfg.background_media, nil)
    end

    -- Zeit-Overlay (Format und Timezone liest der Python-Service;
    -- Lua-Seite verarbeitet nur den fertigen Text aus dem
    -- data_mapper-Handler).
    time_overlay.enabled = cfg.time_enabled and true or false
    time_overlay.size    = tonumber(cfg.time_size) or 80
    time_overlay.x       = tonumber(cfg.time_x)    or 1820
    time_overlay.y       = tonumber(cfg.time_y)    or 980
    time_overlay.align   = cfg.time_align or "right"
    time_overlay.locale  = cfg.time_locale or "de"
    if type(cfg.time_color) == "table" then
        time_overlay.color = {
            r = tonumber(cfg.time_color.r) or 1,
            g = tonumber(cfg.time_color.g) or 1,
            b = tonumber(cfg.time_color.b) or 1,
            a = tonumber(cfg.time_color.a) or 1,
        }
    end
    update_time_font(resolve_resource(cfg.time_font))

    -- Cornerlogo
    corner_logo.enabled = cfg.logo_enabled and true or false
    corner_logo.x       = tonumber(cfg.logo_x) or 0
    corner_logo.y       = tonumber(cfg.logo_y) or 0
    update_corner_logo(resolve_resource(cfg.logo_image))

    -- Pegel-Aenderungen werden pro Frame in apply_audio_levels()
    -- aus volume_db + Ducking-Offset frisch berechnet — ein
    -- separater Volume-Set hier ist nicht noetig.

    -- Slot-Wechsel können das Audio-Ziel verändern (Disposal des
    -- aktiven Videos). Routing-Stand zurücksetzen, damit der nächste
    -- Render-Frame frisch entscheidet.
    audio_active = nil
end)

------------------------------------------------------------
-- Manifest-Watch (vom Python-Service geschrieben)
------------------------------------------------------------

-- Zeit-Text vom service-Sidecar (mit korrekter Timezone-Behandlung
-- via Python pytz). Per UDP-IPC zugestellt — keine SD-Writes.
-- Path "time" matcht das vom Service gesendete "root/time:<text>".
util.data_mapper{
    time = function(msg)
        time_overlay.text = msg or ""
    end,
    -- Erreichbarkeits-Probe-Resultat vom Sidecar. Format: "ok:<url>"
    -- oder "fail:<url>". URL wird mitgesendet, damit der Reload-Gate
    -- ein "ok" nur fuer die aktuell aktive Konfig-URL akzeptiert
    -- (Race-Schutz, s. audio_probe-Tabelle). Defensiv gegen
    -- unerwartete Formate: bei Parser-Fehler bleibt der Probe-State
    -- unveraendert.
    audio_probe = function(msg)
        msg = msg or ""
        local result, url = msg:match("^([^:]+):(.*)$")
        if not result then return end
        audio_probe.last_msg_at = sys.now()
        audio_probe.ok = (result == "ok")
        audio_probe.url = url
    end,
}

util.json_watch("manifest.json", function(m)
    if not m then return end
    local entries = m.slides or {}

    -- Leere Playlist → IDLE (Backup wird angezeigt). Vorhandene slides
    -- bleiben erhalten, um beim nächsten Manifest-Update ggf. nahtlos
    -- weiterzumachen — gerendert werden sie in IDLE nicht.
    if #entries == 0 then
        -- Falls gerade eine Video-Folie laeuft: FG-Video wegraeumen und
        -- BG-Video reaktivieren, sonst bliebe die Decoder-Belegung
        -- bestehen und der Backup-Pfad waere visuell vom FG ueberdeckt.
        leave_video_slide_if_active()
        dispose_list(pending_slides)
        pending_slides = nil
        end_cycle_fade()
        state = STATE_IDLE
        return
    end

    -- Folien laden. Sowohl Image- als auch Video-Slides entstehen hier
    -- nur als Metadaten — Image-Texturen werden via reconcile_window /
    -- preload_slot bedarfsgerecht im Sliding-Window von SLIDE_WINDOW
    -- Folien gehalten, Video-Resources entstehen erst beim Eintritt in
    -- die Folie via fg_video_load (auf Pi 3B nur ein HW-Decoder).
    -- Lange Playlists wuerden sonst das CMA-Budget sprengen
    -- ("Cannot alloc texture: out of memory" -> Watchdog-Reboot).
    local loaded = {}
    for _, e in ipairs(entries) do
        if e.file then
            local kind = media_type_for(e, e.file)
            if kind == "video" then
                -- duration aus Manifest wird ignoriert: Video laeuft bis
                -- :state() == "finished".
                loaded[#loaded + 1] = {
                    file     = e.file,
                    kind     = "video",
                    duration = 0,
                    res      = nil,
                }
            else
                loaded[#loaded + 1] = {
                    file     = e.file,
                    kind     = "image",
                    duration = tonumber(e.duration) or CONFIG.default_duration,
                    res      = nil,
                    failed   = false,
                }
            end
        end
    end

    if #loaded == 0 then return end

    dispose_list(pending_slides)
    pending_slides = loaded

    -- Kein eager Preload und kein direkter IDLE->PLAYING-Wechsel mehr —
    -- reconcile_window triggert pending[1] in beiden States (IDLE und
    -- PLAYING) ueber den n==0-Pfad bzw. die Phase-2-Preload. Der IDLE-
    -- Render-Pfad faehrt erst dann auf PLAYING um, wenn pending[1]
    -- draw-ready ist (Image: image_drawable; Video: sofort, weil
    -- fg_video_load erst im Slide-Wechsel-Hook nach dem Uebergang
    -- triggert). Im PLAYING-State swappt der Renderer am Zyklus-Ende
    -- mit Crossfade.
end)

------------------------------------------------------------
-- Renderer
------------------------------------------------------------

-- Bild auf den vollen Bildschirm strecken (kein Letterbox). Bei
-- abweichendem Seitenverhältnis verzerrt es — Folien daher in nativer
-- Display-Auflösung anliefern.
local function draw_fit(res, alpha)
    if not res then return end
    res:draw(0, 0, WIDTH, HEIGHT, alpha)
end

-- Media-Slot auf den vollen Bildschirm zeichnen. Bilder per :draw mit
-- Zielrechteck, Videos per :place (raw-Videos haben kein :draw und
-- kein :size). Beide Pfade strecken ohne Aspect-Korrektur — Backup-
-- und Hintergrund-Assets daher in nativer Display-Auflösung
-- (z. B. 1920x1080) anliefern, sonst verzerrt es.
-- :place() wirkt nur in den States 'paused', 'loaded', 'playing',
-- 'finished'. Im 'loading'-State (Decoder waermt sich noch auf, Frame-
-- Groesse unbekannt) loggt info-beamer eine Warnung mit Stacktrace und
-- ignoriert den Aufruf. Im 'error'-State ist :place() ohnehin sinnlos.
-- Beide Faelle hier hart filtern, damit der Render-Pfad sauber bleibt.
local function video_placeable(res)
    if not res then return false end
    local ok, st = pcall(function() return res:state() end)
    return ok and st ~= "loading" and st ~= "error"
end

local function draw_slot(slot, alpha)
    if not slot.res then return end
    if slot.kind == "video" then
        if video_placeable(slot.res) then
            pcall(function() slot.res:place(0, 0, WIDTH, HEIGHT) end)
        end
    else
        slot.res:draw(0, 0, WIDTH, HEIGHT, alpha or 1)
    end
end

-- Verstecke ein Video durch :place auf ein 0×0-Rechteck — info-beamer
-- behält sonst die letzte Platzierung bei und das Video bliebe sichtbar.
-- Auch hier nur ausfuehren, wenn das Video place'bar ist; im 'loading'-
-- State gibt es ohnehin nichts Sichtbares zu verstecken.
local function hide_video(slot)
    if slot.kind == "video" and video_placeable(slot.res) then
        pcall(function() slot.res:place(0, 0, 0, 0) end)
    end
end

-- Zeit-Overlay zeichnen (wenn aktiviert und Schrift verfügbar). Nur
-- im PLAYING-Zustand aufgerufen; im IDLE-Zustand bleibt das Overlay
-- aus, damit der Backup-Inhalt klar dominiert.
--
-- Mehrzeilige Formate (\n im strftime-Format) werden auf einzelne
-- Zeilen aufgeteilt und untereinander mit Zeilenhöhe = Schriftgröße
-- gerendert. Die Ausrichtung gilt pro Zeile relativ zu time_x.
local function draw_time_overlay()
    if not time_overlay.enabled then return end
    local font = time_overlay.font_res
    if not font then return end

    local text = time_overlay.text
    if type(text) ~= "string" or text == "" then return end

    if time_overlay.locale == "de" then
        text = localize_de(text)
    end

    local lines = {}
    for line in text:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then return end

    local size       = time_overlay.size
    local line_height = size  -- 1.0 line-height; ggf. später konfigurierbar
    local c          = time_overlay.color

    for i, line in ipairs(lines) do
        local x = time_overlay.x
        if time_overlay.align == "right" or time_overlay.align == "center" then
            local ok_w, w = pcall(function() return font:width(line, size) end)
            if ok_w and type(w) == "number" then
                x = (time_overlay.align == "right") and (x - w) or (x - w / 2)
            end
        end
        local y = time_overlay.y + (i - 1) * line_height
        pcall(function()
            font:write(x, y, line, size, c.r, c.g, c.b, c.a)
        end)
    end
end

-- Cornerlogo zeichnen — wird IMMER zuletzt gezeichnet, also über
-- Folien, Backup-Bild UND Zeit-Overlay. Bei Backup-Video liegt das
-- Logo auf der GL-Surface oberhalb des raw-Videos.
--
-- Bild in Originalgröße bei (x, y) zeichnen. Vollformatige Logos
-- (Display-Auflösung, Position via Transparenz) füllen bei (0, 0)
-- automatisch den ganzen Bildschirm. image:size() liefert Pixelmaße;
-- Fallback auf Vollbild, falls die Abfrage scheitert (z. B. Resource
-- noch im "loading"-Zustand).
local function draw_corner_logo()
    if not corner_logo.enabled or not corner_logo.res then return end

    local ok, w, h = pcall(function() return corner_logo.res:size() end)
    if ok and type(w) == "number" and type(h) == "number" then
        local x, y = corner_logo.x, corner_logo.y
        corner_logo.res:draw(x, y, x + w, y + h, 1)
    else
        corner_logo.res:draw(0, 0, WIDTH, HEIGHT, 1)
    end
end

function node.render()
    check_audio_stream_health()
    check_audio_jukebox_health()
    update_audio_routing()

    local t = now()
    -- Transparent clearen, damit raw-Videos auf negativen Layers durch
    -- transparente Folien-Pixel hindurchscheinen können. Wo nichts auf
    -- der GL-Surface gezeichnet wird, ist sie durchsichtig — und gibt
    -- den Blick auf die Video-Ebenen darunter frei.
    gl.clear(0, 0, 0, 0)

    if state == STATE_IDLE then
        -- IDLE->PLAYING-Uebergang: schaltet auf PLAYING um, sobald
        -- pending_slides[1] draw-ready ist. Der Aufruf steht VOR der
        -- Backup-Zeichnung, damit im Wechsel-Frame bereits der PLAYING-
        -- Pfad rendert (kein zusaetzlicher Backup-Frame). Image-Slides
        -- gelten als ready, sobald image_drawable true liefert (oder
        -- der Slot ohnehin failed ist — der Watchdog faengt das spaeter
        -- wieder ab); Video-Slides sofort, weil fg_video_load erst im
        -- Slide-Wechsel-Hook nach dem Uebergang triggert.
        if pending_slides and pending_slides[1] then
            local first = pending_slides[1]
            local ready
            if first.kind == "video" then
                ready = true
            else
                -- Reihenfolge wichtig: image_drawable() ZUERST aufrufen,
                -- damit image_ready() einen evtl. neu erkannten Decode-
                -- Fehler in first.failed materialisieren kann (Seiten-
                -- effekt: setzt failed=true, disposed res). Erst danach
                -- first.failed lesen — sonst wuerde 'first.failed or
                -- image_drawable(first)' den Failed-State des aktuellen
                -- Frames verschlucken (or evaluiert links-zuerst, links
                -- ist im ersten Frame noch false), und der IDLE->
                -- PLAYING-Uebergang verzoegerte sich um einen Frame.
                ready = image_drawable(first) or first.failed
            end
            if ready then
                swap_slides(pending_slides)
                pending_slides            = nil
                current_idx               = 1
                -- Zeitbasis innerhalb des Render-Ticks konsistent
                -- halten: Frame-Zeitstempel t (aus dem Frame-Start)
                -- verwenden, nicht now() — sonst laege slide_started
                -- ein paar Mikrosekunden NACH t, und der erste
                -- elapsed=t-slide_started im PLAYING-Pfad waere
                -- minimal negativ (kann Fade-/Advance-Logik
                -- inkonsistent stossen).
                slide_started             = t
                slide_drew                = false
                consecutive_failed_slides = 0
                state                     = STATE_PLAYING
                -- KEIN early return: weiter mit dem PLAYING-Branch im
                -- selben Frame, damit der erste Render-Tick der neuen
                -- Playlist nicht erst auf den Folge-Frame wartet.
            end
        end
    end

    if state == STATE_IDLE then
        -- Defensiv: falls IDLE betreten wurde, ohne dass die ueblichen
        -- State-Transition-Pfade FG-Cleanup gelaufen sind. Greift auch
        -- bei haengendem bg_yielded_state (z. B. nach fehlgeschlagenem
        -- fg_video_load), wo fg_video.res selbst nil ist.
        leave_video_slide_if_active()
        clear_pending_image_hold()
        bg_resume_gate         = nil
        if backup_slot.kind == "video" and backup_slot.res then
            -- Backup-Video übernimmt voll: das Video liegt auf Layer -2
            -- hinter der (transparenten) GL-Surface und überdeckt das
            -- Hintergrund-Video auf Layer -3. Wir zeichnen weder
            -- Hintergrund-Bild noch sonst etwas auf GL, damit das
            -- Backup-Video sichtbar bleibt.
            if video_placeable(backup_slot.res) then
                pcall(function() backup_slot.res:place(0, 0, WIDTH, HEIGHT) end)
            end
        else
            -- Backup-Bild (oder leerer Slot): Hintergrund zuerst,
            -- danach Backup-Bild darüber. Bei transparenten Pixeln
            -- des Backup-Bildes scheint der Hintergrund durch.
            draw_slot(background_slot, 1)
            if backup_slot.kind == "image" and backup_slot.res then
                backup_slot.res:draw(0, 0, WIDTH, HEIGHT, 1)
            end
        end
        -- Cornerlogo IMMER ganz oben (auch im Backup-Zustand).
        draw_corner_logo()
        last_cur = nil
        -- pending_slides[1] direkt preloaden, damit der naechste
        -- IDLE->PLAYING-Uebergang ohne Decode-Wartezeit erfolgen kann.
        -- Bewusst NICHT reconcile_window: in IDLE wird slides nicht
        -- gerendert, ein Phase-1-Preload des alten Windows waere
        -- verschwendete Decode-Zeit und wuerde via In-Flight-Gate den
        -- pending[1]-Decode hinauszoegern (siehe preload_pending_first
        -- fuer Details).
        preload_pending_first()
        return
    end

    -- PLAYING
    if #slides == 0 then
        leave_video_slide_if_active()
        last_cur               = nil
        clear_pending_image_hold()
        bg_resume_gate         = nil
        state = STATE_IDLE
        return
    end

    local cur = slides[current_idx]
    -- Image-Slides muessen eine geladene Resource haben (sonst Loader-
    -- Fehler und sie waeren nicht in slides[] gelandet). Video-Slides
    -- haben legitimerweise res=nil — die Resource entsteht erst durch
    -- fg_video_load weiter unten.
    if not cur then
        leave_video_slide_if_active()
        last_cur               = nil
        clear_pending_image_hold()
        bg_resume_gate         = nil
        state = STATE_IDLE
        return
    end

    -- Backup-Video off-screen verstecken — sonst würde sein Standbild
    -- auf Layer -2 das Hintergrund-Video durch die transparenten
    -- Folien-Pixel hindurch überdecken.
    hide_video(backup_slot)

    -- Hintergrund-Draw wird unten gemeinsam mit der Slide-Wahl gemacht:
    -- bei aktiver Video-Folie zeichnen wir das BG NICHT auf die GL-
    -- Surface (Image-BG auf Layer 0 wuerde das FG-Video auf Layer -1
    -- ueberdecken), bei Image-Folien oder Video-Folien-Lade-Fehler aber
    -- schon. Bei Video-BG ist background_slot via background_yield()
    -- ohnehin disposed, dann ist der Aufruf eh ein No-op.

    -- Slide-Timing waehrend bg_resume_gate aktiv ist einfrieren:
    -- slide_started kontinuierlich nachschieben, sodass elapsed konstant
    -- bleibt. Ohne diese Pause wuerde die effektive Sichtbarkeitsdauer
    -- (und ggf. der Out-Fade) der wartenden Image-Folie um bis zu
    -- BG_RESUME_GATE_TIMEOUT verkuerzt — die Folie ist im Gate-Fenster
    -- nicht sichtbar, soll aber ihre volle Standzeit bekommen, sobald
    -- das BG-Video Frames liefert.
    if bg_resume_gate then
        if bg_resume_gate.last_tick then
            slide_started = slide_started + (t - bg_resume_gate.last_tick)
        end
        bg_resume_gate.last_tick = t
    end

    local fade_dur = math.max(0, CONFIG.fade_duration)
    local elapsed  = t - slide_started

    -- Advance-Entscheidung. Bei Image-Slides timer-basiert (mind.
    -- fade_dur lang sichtbar, sonst kein vollstaendiger Out-Fade), bei
    -- Video-Slides am Decoder-State festgemacht: das Video laeuft bis
    -- "finished", dann wechseln wir. Manifest-duration wird fuer Videos
    -- ignoriert. "error" behandeln wir wie "finished" — eine kaputte
    -- Folie soll nicht den Zyklus blockieren.
    local should_advance
    if cur.kind == "video" then
        if fg_video.res then
            local ok, st = pcall(function() return fg_video.res:state() end)
            should_advance = ok and (st == "finished" or st == "error")
            -- Bei looped=true (Single-Video-Playlist, #slides == 1)
            -- erreicht state() nie "finished" — der Cycle-Wrap waere
            -- damit blockiert und ein anliegendes pending_slides
            -- (Manifest-Update aus dem Sidecar) wuerde nie angewandt.
            -- In genau dem Moment erzwingen wir den Advance, damit der
            -- Wrap-Pfad swap_slides aufrufen und auf die neue Liste
            -- umsteigen kann. Auf Multi-Slide-Playlists darf das nicht
            -- greifen — dort laufen Videos bestimmungsgemaess bis
            -- "finished" und ein Manifest-Update wartet auf das
            -- regulaere Cycle-Ende.
            if not should_advance and pending_slides and #slides == 1 then
                should_advance = true
            end
        else
            -- Load fehlgeschlagen oder noch nicht erfolgt; ueberspringen,
            -- aber nur wenn der Slide-Wechsel-Hook bereits gelaufen ist
            -- (sonst skippen wir die Folie noch vor dem Lade-Versuch).
            should_advance = (cur == last_cur)
        end
    else
        local cur_dur = math.max(cur.duration, fade_dur)
        if elapsed >= cur_dur then
            -- Transition-Gate: die naechste Image-Folie muss
            -- draw-ready sein, sonst greift der nachfolgende
            -- Cycle-/Slide-Crossfade auf eine noch nicht dekodierte
            -- Textur. preload_slot/reconcile_window sollten den Slot
            -- laengst angetriggert haben — die folgenden Defensiv-
            -- Aufrufe sichern lediglich gegen pathologisch kurze
            -- Slide-Dauern (cur.duration < Decode-Zeit) am
            -- Window-Rand und beim Manifest-Wrap. Bei nicht-fertigem
            -- Slot bleibt cur stehen, bis ready — visuell sieht der
            -- Zuschauer nur eine minimal verlaengerte Standzeit der
            -- aktuellen Folie.
            local nxt_slot
            if current_idx >= #slides then
                nxt_slot = (pending_slides and pending_slides[1])
                           or slides[1]
            else
                nxt_slot = slides[current_idx + 1]
            end
            if nxt_slot and nxt_slot.kind == "image"
               and not image_ready(nxt_slot) then
                -- Preload-Trigger nur, wenn aktuell kein anderer
                -- Decode in Flight ist — sonst wuerde dieser Render-
                -- Loop-Pfad den globalen Sequentialisierungs-Gate
                -- aushebeln und einen zweiten parallelen Decode
                -- starten. Im Normalfall hat reconcile_window den
                -- Slot ohnehin laengst angetriggert; das hier ist
                -- nur Sicherung gegen pathologisch kurze Standzeiten,
                -- bei denen der Wechsel schneller kommt als der
                -- naechste reconcile-Tick. Bei laufendem Decode
                -- einfach defern — der naechste Frame prueft
                -- erneut.
                if not any_image_in_flight(current_idx) then
                    preload_slot(nxt_slot)
                end
                should_advance = false
                -- elapsed am Advance-Schwellwert klemmen, damit der
                -- naechste Frame sofort wieder prueft, ohne dass
                -- elapsed weit ueber cur_dur hinauslaeuft (sonst
                -- spaeter sichtbarer Sprung im Out-Fade).
                slide_started = t - cur_dur
            else
                should_advance = true
            end
        else
            should_advance = false
        end
    end

    -- Advance ZUERST. Beim Zyklus-Ende setzt das outgoing — der
    -- Cycle-Fade-Check muss DANACH laufen, damit die Crossfade direkt
    -- im selben Frame anlaeuft. Sonst entstuende ein Single-Frame-
    -- Flackern, in dem die naechste Folie kurz allein sichtbar ist,
    -- bevor das Cycle-Crossfade im Folgeframe startet.
    if should_advance then
        -- Watchdog Dauer-Fail: konnte die ablaufende Folie ueberhaupt
        -- gezeichnet werden? slide_drew wird im Render-Pfad bei
        -- erfolgreichem Image-/Video-Frame gesetzt. Ein kompletter
        -- Cycle (#slides Advances) ohne ein einziges sichtbares Frame
        -- → Backup-Modus (state=IDLE). Greift bei systematischen
        -- Lade-Fehlern, z. B. wenn der Sidecar Folien-Files schon
        -- geloescht hat, bevor sie gerendert werden konnten, oder
        -- alle Slots als slot.failed markiert sind.
        if slide_drew then
            consecutive_failed_slides = 0
        else
            consecutive_failed_slides = consecutive_failed_slides + 1
        end
        slide_drew = false

        if #slides > 0 and consecutive_failed_slides >= #slides then
            print(string.format(
                "Watchdog: %d Folien ohne sichtbaren Frame — Backup wird angezeigt.",
                consecutive_failed_slides
            ))
            leave_video_slide_if_active()
            end_cycle_fade()
            clear_pending_image_hold()
            last_cur                  = nil
            bg_resume_gate            = nil
            consecutive_failed_slides = 0
            state                     = STATE_IDLE
            return
        end

        if current_idx >= #slides then
            -- Zyklus-Ende: outgoing erfassen, ggf. pending einsetzen.
            set_outgoing(cur)
            if pending_slides then
                swap_slides(pending_slides)
                pending_slides            = nil
                consecutive_failed_slides = 0
            end
            current_idx = 1
            -- Single-Slot-Loops (#slides == 1): beim Wrap zeigt
            -- slides[1] auf denselben Lua-Pointer wie vor dem Wrap,
            -- sodass der Slide-Wechsel-Hook (cur ~= last_cur) ohne
            -- diesen Reset NICHT feuern wuerde — bei Video-Slides
            -- bliebe fg_video.res im "finished"-State haengen und das
            -- Video frieren auf dem letzten Frame ein, statt erneut
            -- zu laden. Fuer Image-Slides ist der Hook ein No-op,
            -- der Reset also unschaedlich.
            last_cur = nil
        else
            current_idx = current_idx + 1
        end
        cur           = slides[current_idx]
        -- Bei aktivem Cycle-Fade-In (image-Outgoing, sichtbarer
        -- Cross-Fade ueber fade_dur Sekunden) startet die Lifetime-
        -- Uhr der neuen Folie erst NACH dem Fade-In. Sonst wuerden
        -- bei Folien mit duration < 2*fade_dur (insbesondere
        -- duration=0) Cycle-Fade-In und Out-Fade vollstaendig
        -- ueberlappen — der Cycle-Fade setzt slide_drawn=true und
        -- blockiert den Out-Fade-Branch im selben Zeitfenster. Bei
        -- elapsed=fade_dur faellt dann sofort der Advance, und die
        -- Folie wuerde als Hard-Cut zur naechsten gewechselt, ohne
        -- jemals einen Out-Fade gerendert zu haben. Mit dem Shift
        -- ist der Out-Fade-Branch im Anschluss an den Cycle-Fade
        -- garantiert sichtbar — Invariante "jede Folie zeigt ihre
        -- eingehende UND ausgehende Transition" gilt damit auch
        -- ueber Wrap-Around-Grenzen hinweg, an jeder Position.
        --
        -- Zeitbasis fuer den Shift ist cycle_fade_start (gesetzt in
        -- set_outgoing, das Frames-genaue Ende des Cycle-Fades),
        -- nicht t — t wird am Frame-Start gemessen, cycle_fade_start
        -- per now() innerhalb set_outgoing (Mikrosekunden spaeter).
        -- Ohne diese Ausrichtung wuerde slide_started einige
        -- Mikrosekunden VOR dem Cycle-Fade-Ende liegen, bei
        -- duration=0 wuerde der Out-Fade dann nicht exakt bei
        -- progress=0 anlaufen.
        if outgoing and outgoing.kind == "image" and fade_dur > 0 then
            slide_started = cycle_fade_start + fade_dur
            elapsed       = t - slide_started
        else
            slide_started = t
            elapsed       = 0
        end
        -- Window-Reconcile passiert am Frame-Ende, NACH dem Render.
        -- Grund: der Slide-Wechsel-Hook (s. unten) kann last_cur.res
        -- in pending_image_hold einhaengen (Multi-Frame-Hold beim
        -- Image+BG-Video -> FG-Video-Wechsel), und der Hold wird ab
        -- dem aktuellen Frame gerendert. Wuerde reconcile hier laufen,
        -- koennte es last_cur disposen, bevor der erste Hold-Frame
        -- zeichnet. Das Hold-Konstrukt selbst schuetzt die Resource
        -- ueber dispose_after gegen spaetere Disposal-Aufrufe (s.
        -- dispose_slot_resource und swap_slides).
    end

    -- Slide-Wechsel-Hook: Video-Folien benoetigen explizite Decoder-
    -- Koordination (BG yield/resume) und Lazy-Load. Wird auch beim
    -- ersten Frame nach IDLE→PLAYING aktiv (last_cur ist dann nil bzw.
    -- zeigt auf eine alte Folie). Bei Video-Lade-Fehler sofort BG
    -- zurueckholen — sonst bliebe der Decoder unnoetig freigegeben und
    -- der Frame haette weder FG-Video noch Hintergrund.
    if cur ~= last_cur then
        if cur.kind == "video" then
            -- File-Keyed Video-Preserve: dasselbe File laeuft bereits
            -- als FG-Video und liefert noch Frames ("playing"). Tritt
            -- nach swap_slides bei identischer Single-Video-Playlist
            -- auf (haeufiger Fall: Sidecar-Restart liefert byte-
            -- identisches Manifest; #slides==1 mit looped=true). Ohne
            -- diese Pruefung wuerde der Decoder unnoetig disposed,
            -- BG-Video re-yielded und der Loop neu angeworfen — mit
            -- sichtbarem Reload-Glitch. State-Whitelist gegen "loaded"/
            -- "paused"/"finished"/"error" gewollt: nur waehrend echtem
            -- Frame-Strom darf der Decoder uebernommen werden (bei
            -- "finished" muesste reloaded werden, weil der Decoder
            -- sich bei looped=false nach Ende nicht wieder anstossen
            -- laesst).
            local can_preserve = false
            if fg_video.res and fg_video.file == cur.file then
                local ok, st = pcall(function() return fg_video.res:state() end)
                if ok and st == "playing" then
                    can_preserve = true
                end
            end

            if not can_preserve then
                -- Image->Video: alte Image-Folie als Hold halten, bis
                -- das neue FG-Video placeable ist (oder die Hold-
                -- Deadline erreicht). Hold wird unabhaengig vom BG-Typ
                -- gesetzt und markiert damit gleichzeitig, dass wir
                -- uns im Image->Video-Uebergang befinden:
                --
                -- * Bei Image-BG zeichnet der Render-Pfad waehrend
                --   des Loadings BG + Hold weiter (= vorheriges Frame).
                --   Sobald video_ready erreicht ist, wird der Hold
                --   geloescht UND der BG nicht mehr gezeichnet (FG
                --   deckt voll). FG und BG verschwinden damit synchron.
                -- * Bei Video-BG ist BG via background_yield disposed;
                --   draw_slot ist No-op. Der Hold liefert das alte
                --   Image als Brueckeninhalt.
                --
                -- Bei Video->Video (last_cur war Video, kein Hold) wird
                -- BG waehrend des Loadings NICHT gezeichnet — Schwarz
                -- ist im Video-zu-Video-Uebergang gewollt, damit FG
                -- und BG synchron weg/da sind.
                --
                -- Quelle: bevorzugt last_cur.res (Standard-Fall). Beim
                -- Cycle-Wrap setzt der Advance-Pfad last_cur=nil — dann
                -- liegt die letzte Image-Folie der alten Liste in
                -- outgoing.res. Disposal-Verantwortung wird vom
                -- outgoing zum Hold gehandoffed (outgoing.dispose_after
                -- wandert in den Hold; outgoing.dispose_after danach
                -- false, damit end_cycle_fade nichts disposed).
                --
                -- Pruefung muss VOR background_yield() laufen, weil
                -- yield() background_slot auf nil setzt — das beein-
                -- flusst zwar die Hold-Bedingung nicht mehr, aber wir
                -- behalten die Reihenfolge konsistent zur frueheren
                -- Variante.
                clear_pending_image_hold()
                local hold_res, hold_dispose_after = nil, false
                if last_cur and last_cur.kind == "image" and last_cur.res then
                    hold_res = last_cur.res
                elseif outgoing and outgoing.kind == "image" and outgoing.res then
                    -- Cycle-Wrap-Pfad: last_cur ist nil, outgoing
                    -- haelt die letzte Image-Folie der alten Liste.
                    -- Wir uebernehmen Disposal-Verantwortung —
                    -- outgoing wird im Render-Pfad direkt danach via
                    -- end_cycle_fade aufgeloest.
                    hold_res            = outgoing.res
                    hold_dispose_after  = outgoing.dispose_after or false
                    outgoing.dispose_after = false
                end
                if hold_res then
                    pending_image_hold = {
                        res           = hold_res,
                        deadline      = t + PENDING_IMAGE_HOLD_TIMEOUT,
                        dispose_after = hold_dispose_after,
                    }
                end
                background_yield()
                -- Single-Video-Playlist (#slides == 1, Slot ist Video):
                -- decoder-internes Looping aktivieren. fg_video.res bleibt
                -- damit dauerhaft auf der "playing"-Resource liegen,
                -- state() liefert nie "finished", und der Advance-Pfad
                -- darunter wird einmalig durch pending_slides gebrochen
                -- (s. should_advance fuer Video).
                local single_video_loop =
                    #slides == 1 and slides[1].kind == "video"
                if not fg_video_load(cur, single_video_loop) then
                    background_resume()
                end
            end
        elseif fg_video.res or bg_yielded_state or pending_image_hold then
            -- Cleanup auf den tatsaechlichen Decoder-/Hold-Zustand
            -- stuetzen, nicht auf last_cur: der Force-Advance fuer
            -- Single-Video-Loops (s. should_advance fuer Video) setzt
            -- last_cur=nil, damit der Hook nach dem Wrap auf demselben
            -- Lua-Pointer noch einmal feuert. Wenn die neue Playlist
            -- mit einem Image-Slide startet, wuerde 'last_cur and
            -- last_cur.kind == "video"' nicht mehr greifen — fg_video
            -- bliebe geladen (Decoder-Slot belegt, Frame-Strom auf
            -- Layer -1 sichtbar).
            --
            -- pending_image_hold im Guard, damit der Pfad auch dann
            -- feuert, wenn ein vorausgegangener fg_video_load
            -- fehlgeschlagen ist: in dem Fall ruft der Video-Branch
            -- direkt background_resume() auf (setzt bg_yielded_state=
            -- nil), fg_video.res ist ebenfalls nil — beide Hauptbe-
            -- dingungen waeren ohne pending_image_hold falsch, und der
            -- gesetzte Hold wuerde ueber den Slide-Wechsel hinweg
            -- haengen bleiben (Image-Resource wird festgehalten).
            fg_video_unload()
            background_resume()
            -- Etwaigen Hold aus einem vorherigen Image->Video-Wechsel
            -- jetzt aufloesen — er wird im Image-Render-Pfad nicht
            -- mehr gezeichnet, wuerde sonst aber bis zum naechsten
            -- Cleanup-Aufruf eingehaengt bleiben.
            clear_pending_image_hold()
            -- Video->Image+BG-Video: Gate setzen, damit die Image-Folie
            -- erst gezeichnet wird, wenn das BG-Video sein erstes Frame
            -- liefert. Bei Image-BG (kein Reload) ist nichts zu warten.
            if background_slot.kind == "video" and background_slot.res then
                bg_resume_gate = {
                    deadline  = t + BG_RESUME_GATE_TIMEOUT,
                    last_tick = t,
                }
            end
        end
        last_cur = cur
    end

    -- BG-Zeichnen-Logik:
    --   * Image-Folie (cur.kind ~= "video"): BG immer als Untergrund
    --     zeichnen (Standard-Pfad).
    --   * Video-Folie:
    --       - Image->Video-Uebergang (pending_image_hold gesetzt) und
    --         Video noch nicht placeable: BG zeichnen, damit der
    --         Uebergang nahtlos ist (Image-BG bleibt sichtbar bis
    --         FG-Video uebernimmt; Video-BG ist dort yielded → no-op).
    --       - sonst (video_ready=true ODER Video->Video-Uebergang):
    --         BG NICHT zeichnen. FG und BG verschwinden bzw. erscheinen
    --         damit synchron — zwischen zwei Videos bleibt der Schirm
    --         schwarz (gewollt: kein BG-Wechsel-Flackern, das nur
    --         waehrend Video-Loading sichtbar waere).
    --
    -- Damit gilt visuell: BG-Image ist sichtbar, solange eine Image-
    -- Folie laeuft, und unsichtbar, solange eine Video-Folie laeuft —
    -- der Hold ueberbrueckt nur den asymmetrischen Loading-Frame im
    -- Image->Video-Uebergang.
    local video_ready = (cur.kind == "video")
                        and video_placeable(fg_video.res)
    local draw_bg = (cur.kind ~= "video")
                    or (not video_ready and pending_image_hold ~= nil)
    if draw_bg then
        draw_slot(background_slot, 1)
    end

    if cur.kind == "video" then
        -- Hard-Cut zur Video-Folie: laufenden Cycle-Fade verwerfen,
        -- GL-Surface bleibt transparent (Folie wird NICHT gezeichnet),
        -- damit das FG-Video auf Layer -1 voll sichtbar ist.
        --
        -- pending_image_hold zeichnet die alte Image-Folie weiter,
        -- bis das neue FG-Video placeable ist (oder die Hold-Deadline
        -- erreicht — Sicherheits-Timeout fuer ein nie ladendes Video).
        -- Muss VOR end_cycle_fade() laufen, weil end_cycle_fade() die
        -- Resource am Cycle-Boundary disposen kann.
        if pending_image_hold then
            if video_ready or t >= pending_image_hold.deadline then
                clear_pending_image_hold()
            else
                pcall(function() draw_fit(pending_image_hold.res, 1) end)
            end
        end

        end_cycle_fade()
        if video_ready then
            pcall(function() fg_video.res:place(0, 0, WIDTH, HEIGHT) end)
            slide_drew = true
        end
    else
        -- Gate aufloesen, sobald BG-Video placeable ist (oder Timeout).
        -- Bewusst dieselbe Bedingung wie draw_slot()'s :place()-Aufruf
        -- (video_placeable, also state ~= "loading"/"error"), nicht
        -- state=="playing": draw_slot zieht das BG-Layer schon im
        -- "loaded"-State in den Compositor — wenn das Gate erst auf
        -- "playing" wartet, ist BG bereits 1+ Frames vor der Folie
        -- sichtbar. Mit derselben Bedingung sind :place() und das
        -- Zeichnen der Folie im gleichen Frame, der naechste vsync
        -- committet beide synchron. BG-Slot kann zwischenzeitlich auf
        -- Image gewechselt sein (Config-Update mid-Folie); dann ist
        -- nichts zu warten.
        if bg_resume_gate then
            local ready
            if background_slot.kind == "video" and background_slot.res then
                ready = video_placeable(background_slot.res)
            else
                ready = true
            end
            if ready or t >= bg_resume_gate.deadline then
                bg_resume_gate = nil
            end
        end

        -- Image-Pfad. Crossfade nur Image↔Image — Outgoing oder Nachfolger
        -- als Video → Hard-Cut (kein Shader-Sample auf raw-Videos
        -- moeglich). Bei aktivem bg_resume_gate wird die Folie nicht
        -- gezeichnet (Time-Overlay und Cornerlogo laufen weiter), sodass
        -- FG-Folie und BG-Video gemeinsam erscheinen statt das Image vor
        -- dem BG-Pop zu zeigen.
        if not bg_resume_gate then
            local slide_drawn = false
            if outgoing then
                local cycle_elapsed = t - cycle_fade_start
                -- Cycle-Fade nur, wenn BEIDE Resourcen konkret
                -- zeichenbar sind:
                --   outgoing.res via resource_drawable (kein Slot-
                --     Bezug mehr nach set_outgoing — bei sehr kurzen
                --     Slide-Dauern kann ein Slot mit res im
                --     "loading"-State outgoing geworden sein, weil
                --     should_advance den State von cur nicht prueft);
                --   slides[current_idx] via image_drawable (verlangt
                --     non-nil + not failed; image_ready allein wuerde
                --     failed-Slots als ready behandeln und
                --     draw_crossfade mit nil-cur.res aufrufen, was
                --     slide_drawn=true setzt und den Fallback-Draw
                --     blockiert).
                local can_fade = outgoing.kind == "image"
                                 and resource_drawable(outgoing.res)
                                 and image_drawable(slides[current_idx])
                if can_fade and fade_dur > 0 and cycle_elapsed < fade_dur then
                    local progress = cycle_elapsed / fade_dur
                    draw_crossfade(outgoing.res, cur.res, progress)
                    slide_drawn = true
                    slide_drew  = true
                else
                    end_cycle_fade()
                end
            end

            if not slide_drawn then
                local cur_dur = math.max(cur.duration, fade_dur)
                local fade_at = cur_dur - fade_dur
                local nxt     = slides[current_idx + 1]
                -- Out-Fade nur starten, wenn beide Folien konkret
                -- zeichenbar sind. image_drawable schlaegt failed-
                -- Slots aus (sonst draw_crossfade mit nil-Resource —
                -- waere effektiv ein verschluckter Fade ohne
                -- Fallback-Draw). Bei nicht-zeichenbarem nxt steht
                -- cur ueber das Advance-Gate ohnehin laenger; bei
                -- nicht-zeichenbarem cur (failed-Slide) zeigt
                -- draw_fit(cur.res=nil) reines BG fuer cur_dur.
                if image_drawable(cur) and image_drawable(nxt)
                   and fade_dur > 0 and elapsed >= fade_at
                   and current_idx < #slides then
                    local progress = math.min(1, (elapsed - fade_at) / fade_dur)
                    draw_crossfade(cur.res, nxt.res, progress)
                    slide_drew = true
                else
                    draw_fit(cur.res, 1)
                    if image_drawable(cur) then
                        slide_drew = true
                    end
                end
            end
        end
    end

    -- Zeit-Overlay über den Folien (in IDLE wird es ohnehin nicht
    -- aufgerufen, da das frühe return im IDLE-Branch bereits gezogen
    -- hat — somit bleibt die "hinter dem Backup-Layer"-Semantik
    -- erhalten). Liegt auf der GL-Surface (Layer 0) und ist somit auch
    -- ueber FG-Video-Folien (Layer -1) sichtbar.
    draw_time_overlay()

    -- Cornerlogo IMMER ganz oben.
    draw_corner_logo()

    -- Pegel-Anwendung am Frame-Ende: damit ein in dieser Render-Phase
    -- ausgeloester Slide-Wechsel (fg_video_load setzt fg_video.res)
    -- noch im SELBEN Frame den Ducking-Fade startet — sonst entstuende
    -- ein Frame Latenz zwischen visuellem Wechsel auf den FG-Layer und
    -- Beginn der Pegelabsenkung.
    apply_audio_levels()

    -- Sliding-Window am Frame-Ende abgleichen. Ab hier wird im Frame
    -- nichts mehr aus slides[i].res gelesen, also koennen Slots
    -- ausserhalb von [current_idx, current_idx + SLIDE_WINDOW - 1]
    -- gefahrlos disposed werden. preload_slot fuer die naechsten
    -- Folien laeuft async (Decode im Worker), bis zum naechsten
    -- Frame typisch fertig.
    if state == STATE_PLAYING then
        reconcile_window(current_idx)
    end
end
