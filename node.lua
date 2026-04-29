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
-- Bilder funktionieren auf jedem Pi; Video-Loops setzen Pi 4+ voraus
-- (raw=true GL-Pipeline).
--
-- Audio-Routing (Audio ist load-time-only in info-beamer; pause/start
-- schaltet zwischen Quellen):
--   * Normalbetrieb (PLAYING): Audio des Hintergrund-Videos.
--   * Backup-Zustand (IDLE) mit Backup-VIDEO: Audio des Backup-Videos.
--   * Backup-Zustand mit Backup-BILD: Audio des Hintergrund-Videos
--     läuft weiter, das Backup-Bild liegt nur visuell darüber.

gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

util.no_globals()

local json = require "json"

------------------------------------------------------------
-- Konfiguration
------------------------------------------------------------

local CONFIG = {
    fade_duration    = 0.5,
    default_duration = 10,
}

-- Raw-Videos rendern in info-beamer auf einer eigenen Ebene außerhalb
-- der GL-Pipeline. layer < 0 platziert das Video HINTER der GL-Surface,
-- sodass transparente Folien-Pixel via gl.clear(_, _, _, 0) und
-- transparenten Folien-PNG-Bereichen das Video durchscheinen lassen.
-- Backup auf höherer (= weniger negativer) Ebene als Background, damit
-- es im IDLE-Zustand das Hintergrund-Video überdeckt.
local backup_slot     = { res = nil, kind = nil, file = nil, label = "Backup-Inhalt",     layer = -1 }
local background_slot = { res = nil, kind = nil, file = nil, label = "Hintergrund-Inhalt", layer = -2 }

------------------------------------------------------------
-- Player-State
------------------------------------------------------------

local STATE_IDLE    = "idle"      -- keine Folien aktiv → backup_slot
local STATE_PLAYING = "playing"

local state          = STATE_IDLE
local slides         = {}     -- [{file, duration, res}, ...]
local current_idx    = 1
local slide_started  = 0
local pending_slides = nil    -- nächste Liste, swap am Zyklus-Ende

-- Zyklus-Crossfade (letzte Folie alt → erste Folie neu).
local outgoing         = nil   -- nil oder {res, dispose_after}
local cycle_fade_start = 0

-- Audio-Routing-Status: "background" | "backup" | nil
local audio_active = nil

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
local function media_type_for(value, name)
    if type(value) == "table" then
        if value.type == "video" then return "video" end
        if value.type == "image" then return "image" end
    end
    if name then
        local ext = name:lower():match("%.([%w]+)$") or ""
        if ext == "mp4" or ext == "webm" or ext == "mov"
           or ext == "mkv" or ext == "m4v" or ext == "avi" then
            return "video"
        end
    end
    return "image"
end

-- Lädt ein Media-Asset entsprechend seines Typs. Videos werden mit
-- raw=true (GL-Pipeline) und audio=true geladen; paused=true, weil
-- update_audio_routing entscheidet, wer aktiv abspielt — nur eine
-- Audio-Quelle gleichzeitig. Auf Pi 3 schlägt raw-Video fehl, der
-- pcall-Aufruf liefert ok=false.
local function load_media(name, kind)
    if kind == "video" then
        return pcall(resource.load_video, {
            file   = name,
            looped = true,
            raw    = true,
            audio  = true,
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
-- über den Hintergrund-Layer ist dann mathematisch korrekt für
-- alle Transparenz-Kombinationen.

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
            vec4 a_pre = vec4(a.rgb * a.a, a.a);
            vec4 b_pre = vec4(b.rgb * b.a, b.a);
            vec4 r_pre = mix(a_pre, b_pre, progress);
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

local function update_audio_routing()
    local target
    if state == STATE_IDLE
       and backup_slot.kind == "video" and backup_slot.res then
        target = "backup"
    elseif background_slot.kind == "video" and background_slot.res then
        target = "background"
    else
        target = nil
    end

    if target == audio_active then return end

    if audio_active == "background" then
        video_pause(background_slot)
    elseif audio_active == "backup" then
        video_pause(backup_slot)
    end

    if target == "background" then
        video_play(background_slot)
    elseif target == "backup" then
        video_play(backup_slot)
    end

    audio_active = target
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
        dispose_after = false,   -- ggf. von swap_slides auf true geflippt
    }
    cycle_fade_start = now()
end

-- Tauscht slides-Liste atomar aus und gibt die Ressourcen der alten
-- Liste frei — mit Ausnahme der ggf. von outgoing referenzierten, für
-- die wir die Disposal-Verantwortung übernehmen, damit der Zyklus-
-- Crossfade die Textur noch zu Ende rendern kann.
local function swap_slides(new_list)
    local old = slides
    slides = new_list
    for _, s in ipairs(old) do
        if s.res then
            if outgoing and outgoing.res == s.res then
                outgoing.dispose_after = true
            else
                pcall(function() s.res:dispose() end)
            end
        end
    end
end

------------------------------------------------------------
-- Media-Slot-Verwaltung
------------------------------------------------------------

local function update_media_slot(slot, cfg_value, default_name)
    local name = resolve_resource(cfg_value) or default_name
    if name == "" then name = nil end

    if name == slot.file then return end

    if slot.res then
        pcall(function() slot.res:dispose() end)
    end
    slot.res, slot.kind, slot.file = nil, nil, name

    if not name then return end

    local kind = media_type_for(cfg_value, name)
    local ok, r = load_media(name, kind)
    if ok and r then
        slot.res, slot.kind = r, kind
        -- raw-Video hinter die GL-Surface legen, damit transparente
        -- Folien-Pixel das Video durchscheinen lassen können.
        if kind == "video" and slot.layer ~= nil then
            pcall(function() r:layer(slot.layer) end)
        end
    else
        local hint = (kind == "video") and " (Video-Loop benötigt Pi 4+)" or ""
        print(slot.label .. " nicht ladbar: " .. name .. hint)
    end
end

------------------------------------------------------------
-- Konfiguration / Watch (Lua-relevante Optionen)
------------------------------------------------------------

util.file_watch("config.json", function(raw)
    local cfg = json.decode(raw)

    CONFIG.fade_duration    = tonumber(cfg.fade_duration)    or 0.5
    CONFIG.default_duration = tonumber(cfg.default_duration) or 10

    update_media_slot(backup_slot,     cfg.backup_media,     "empty.png")
    update_media_slot(background_slot, cfg.background_media, nil)

    -- Slot-Wechsel können das Audio-Ziel verändern (Disposal des
    -- aktiven Videos). Routing-Stand zurücksetzen, damit der nächste
    -- Render-Frame frisch entscheidet.
    audio_active = nil
end)

------------------------------------------------------------
-- Manifest-Watch (vom Python-Service geschrieben)
------------------------------------------------------------

util.json_watch("manifest.json", function(m)
    if not m then return end
    local entries = m.slides or {}

    -- Leere Playlist → IDLE (Backup wird angezeigt). Vorhandene slides
    -- bleiben erhalten, um beim nächsten Manifest-Update ggf. nahtlos
    -- weiterzumachen — gerendert werden sie in IDLE nicht.
    if #entries == 0 then
        dispose_list(pending_slides)
        pending_slides = nil
        end_cycle_fade()
        state = STATE_IDLE
        return
    end

    -- Folien laden.
    local loaded = {}
    for _, e in ipairs(entries) do
        if e.file then
            local ok, res = pcall(resource.load_image, {file = e.file})
            if ok and res then
                loaded[#loaded + 1] = {
                    file     = e.file,
                    duration = tonumber(e.duration) or CONFIG.default_duration,
                    res      = res,
                }
            else
                print("Folie nicht ladbar: " .. tostring(e.file))
            end
        end
    end

    if #loaded == 0 then return end

    dispose_list(pending_slides)
    pending_slides = loaded

    if state == STATE_IDLE then
        -- Sofort einsetzen — kein laufender Zyklus, von dem wir
        -- ausfaden müssten.
        local old = slides
        slides = pending_slides
        pending_slides = nil
        dispose_list(old)
        current_idx   = 1
        slide_started = now()
        state = STATE_PLAYING
    end
    -- Sonst: bleibt als pending; Renderer swappt am Zyklus-Ende mit
    -- Crossfade.
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
local function draw_slot(slot, alpha)
    if not slot.res then return end
    if slot.kind == "video" then
        pcall(function() slot.res:place(0, 0, WIDTH, HEIGHT) end)
    else
        slot.res:draw(0, 0, WIDTH, HEIGHT, alpha or 1)
    end
end

-- Verstecke ein Video durch :place auf ein 0×0-Rechteck — info-beamer
-- behält sonst die letzte Platzierung bei und das Video bliebe sichtbar.
local function hide_video(slot)
    if slot.kind == "video" and slot.res then
        pcall(function() slot.res:place(0, 0, 0, 0) end)
    end
end

function node.render()
    update_audio_routing()

    local t = now()
    -- Transparent clearen, damit raw-Videos auf negativen Layers durch
    -- transparente Folien-Pixel hindurchscheinen können. Wo nichts auf
    -- der GL-Surface gezeichnet wird, ist sie durchsichtig — und gibt
    -- den Blick auf die Video-Ebenen darunter frei.
    gl.clear(0, 0, 0, 0)

    if state == STATE_IDLE then
        if backup_slot.kind == "video" and backup_slot.res then
            -- Backup-Video übernimmt voll: das Video liegt auf Layer -1
            -- hinter der (transparenten) GL-Surface und überdeckt das
            -- Hintergrund-Video auf Layer -2. Wir zeichnen weder
            -- Hintergrund-Bild noch sonst etwas auf GL, damit das
            -- Backup-Video sichtbar bleibt.
            pcall(function() backup_slot.res:place(0, 0, WIDTH, HEIGHT) end)
        else
            -- Backup-Bild (oder leerer Slot): Hintergrund zuerst,
            -- danach Backup-Bild darüber. Bei transparenten Pixeln
            -- des Backup-Bildes scheint der Hintergrund durch.
            draw_slot(background_slot, 1)
            if backup_slot.kind == "image" and backup_slot.res then
                backup_slot.res:draw(0, 0, WIDTH, HEIGHT, 1)
            end
        end
        return
    end

    -- PLAYING
    if #slides == 0 then
        state = STATE_IDLE
        return
    end

    local cur = slides[current_idx]
    if not cur or not cur.res then
        state = STATE_IDLE
        return
    end

    -- Hintergrund: Video :place auf Layer -2 (durchscheinend hinter
    -- transparenten Folien-Pixeln), Bild direkt auf GL (von Folien
    -- überdeckt, scheint durch transparente Folien-Pixel hindurch).
    draw_slot(background_slot, 1)

    -- Backup-Video off-screen verstecken — sonst würde sein Standbild
    -- auf Layer -1 das Hintergrund-Video durch die transparenten
    -- Folien-Pixel hindurch überdecken.
    hide_video(backup_slot)

    local fade_dur = math.max(0, CONFIG.fade_duration)

    -- Eine Folie muss mindestens fade_dur lang "current" sein, sonst
    -- bleibt fuer den Crossfade auf die naechste Folie keine Zeit. Bei
    -- duration=0 (oder duration < fade_dur) wuerde der Advance sofort
    -- nach dem Eintritt ausloesen und den Out-Fade ueberspringen — die
    -- naechste Folie poppt dann hart rein. Mit max(duration, fade_dur)
    -- spielt der Crossfade immer komplett.
    local cur_dur = math.max(cur.duration, fade_dur)
    local elapsed = t - slide_started

    -- Advance ZUERST. Beim Zyklus-Ende setzt das outgoing — der
    -- Cycle-Fade-Check muss DANACH laufen, damit die Crossfade direkt
    -- im selben Frame anlaeuft. Sonst entstuende ein Single-Frame-
    -- Flackern, in dem die naechste Folie kurz allein sichtbar ist,
    -- bevor das Cycle-Crossfade im Folgeframe startet.
    if elapsed >= cur_dur then
        if current_idx >= #slides then
            -- Zyklus-Ende: outgoing erfassen, ggf. pending einsetzen.
            set_outgoing(cur)
            if pending_slides then
                swap_slides(pending_slides)
                pending_slides = nil
            end
            current_idx = 1
        else
            current_idx = current_idx + 1
        end
        slide_started = t
        cur           = slides[current_idx]
        cur_dur       = math.max(cur.duration, fade_dur)
        elapsed       = 0
    end

    -- Zyklus-Crossfade: outgoing (letzte Folie alt) ausblenden, cur
    -- (erste Folie neu) einblenden. Greift sowohl bei laufendem Fade
    -- aus vorigen Frames als auch im Frame, in dem advance gerade
    -- outgoing gesetzt hat (cycle_elapsed = 0 → progress = 0 →
    -- outgoing voll sichtbar, cur unsichtbar — keine harte Folge).
    if outgoing then
        local cycle_elapsed = t - cycle_fade_start
        if fade_dur > 0 and cycle_elapsed < fade_dur then
            local progress = cycle_elapsed / fade_dur
            draw_crossfade(outgoing.res, cur.res, progress)
            return
        end
        end_cycle_fade()
    end

    -- Intra-Zyklus-Crossfade.
    local fade_at = cur_dur - fade_dur
    if fade_dur > 0 and elapsed >= fade_at and current_idx < #slides then
        local nxt      = slides[current_idx + 1]
        local progress = math.min(1, (elapsed - fade_at) / fade_dur)
        draw_crossfade(cur.res, nxt.res, progress)
    else
        draw_fit(cur.res, 1)
    end
end
