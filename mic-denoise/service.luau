--!nonstrict
-- Mic Denoise - headless service (single owner of all logic).
--
-- Published state   noctalia.state["status"]  -> { enabled, available, default, raw }
-- Command channel   noctalia.state["command"] -> { action = "on" | "off" | "toggle" | "refresh" }
--
-- The tile and the bar widget are thin clients: they render "status" and write
-- "command". Switching off moves the default source (and every capture stream)
-- back to the physical microphone, which leaves the RNNoise filter-chain without
-- a consumer, so PipeWire suspends the whole graph and no DSP work happens.

local SOURCE = tostring(noctalia.getConfig("source") or "rnnoise_source")
local RAW_PREF = tostring(noctalia.getConfig("hardware_source") or "")
local INTERVAL = tonumber(noctalia.getConfig("poll_interval")) or 2000
if INTERVAL < 500 then
    INTERVAL = 500
end

-- A hung pactl must never wedge the service in a permanent "busy" state.
local CMD_TIMEOUT_MS = 8000

local PLUGIN_DIR = noctalia.pluginDir() or "."
local SCRIPT = PLUGIN_DIR .. "/assets/mic-denoise.sh"
local DATA_DIR = noctalia.pluginDataDir() or ""
local CONF_PATH = noctalia.expandPath("~/.config/pipewire/pipewire.conf.d/50-mic-denoise.conf")

local status = nil
local busy = false
local pending = nil -- latest queued work: { kind = "status" } or { kind = "action", action = ... }
local lastError = nil
local configState = "pending" -- pending | present | written | failed

local function log(msg)
    noctalia.log(`mic-denoise: {msg}`)
end

local function reportError(detail)
    if detail == nil or detail == "" then
        detail = noctalia.tr("notify.failed.body")
    end
    if detail == lastError then
        return
    end
    lastError = detail
    log(detail)
    noctalia.notifyError(noctalia.tr("notify.failed.title"), detail)
end

local function clearError()
    lastError = nil
end

local function parseStatus(out)
    local st = { enabled = false, available = false, default = "", raw = "" }
    for line in (out or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key == "enabled" then
            st.enabled = value == "1"
        elseif key == "available" then
            st.available = value == "1"
        elseif key == "default" then
            st.default = value
        elseif key == "raw" then
            st.raw = value
        end
    end
    return st
end

local function publish(st)
    local prev = status
    status = st
    if
        prev
        and prev.enabled == st.enabled
        and prev.available == st.available
        and prev.default == st.default
        and prev.raw == st.raw
    then
        return
    end
    noctalia.state.set("status", st)
end

-- The snippet is machine specific: the capture side is pinned to the physical
-- microphone so pointing the default source at the virtual one cannot loop.
-- Generated once from the bundled template, never overwritten afterwards.
local function ensurePipewireConfig(st)
    if configState == "present" or configState == "written" then
        return
    end
    if noctalia.fileExists(CONF_PATH) then
        configState = "present"
        return
    end
    if st.raw == "" then
        return -- no microphone known yet; retry on a later poll
    end

    local template, readErr = noctalia.readFile(PLUGIN_DIR .. "/assets/50-mic-denoise.conf.in")
    if not template then
        configState = "failed"
        log(`template unreadable: {tostring(readErr)}`)
        return
    end

    local content = template:gsub("@SOURCE@", function()
        return SOURCE
    end)
    content = content:gsub('node%.target%s*=%s*"@TARGET@"', function()
        return 'node.target  = "' .. st.raw .. '"'
    end)

    if content:find("@SOURCE@", 1, true) or content:find("@TARGET@", 1, true) then
        configState = "failed"
        log(`unresolved placeholder in template; refusing to write {CONF_PATH}`)
        return
    end

    noctalia.mkdirAll(CONF_PATH:match("^(.*)/[^/]+$") or ".")
    local ok, writeErr = noctalia.writeFile(CONF_PATH, content)
    if not ok then
        configState = "failed"
        log(`could not write {CONF_PATH}: {tostring(writeErr)}`)
        return
    end

    configState = "written"
    noctalia.notify(noctalia.tr("notify.config-installed.title"), noctalia.tr("notify.config-installed.body"))
end

function dispatch()
    if busy or pending == nil then
        return
    end
    local item = pending
    pending = nil

    local argv
    if item.kind == "action" then
        argv = { "sh", SCRIPT, item.action, SOURCE, RAW_PREF, DATA_DIR }
    else
        argv = { "sh", SCRIPT, "status", SOURCE, RAW_PREF, DATA_DIR }
    end

    busy = true
    local started = noctalia.runAsync(argv, function(res)
        busy = false
        if res.timedOut then
            reportError(noctalia.tr("notify.timeout.body"))
        elseif res.exitCode ~= 0 then
            reportError((res.stderr or ""):gsub("%s+$", ""))
        else
            clearError()
            if item.kind == "status" then
                local st = parseStatus(res.stdout)
                ensurePipewireConfig(st)
                publish(st)
            end
        end
        -- A switch always ends with a fresh status so the UI reflects reality.
        if item.kind == "action" and pending == nil then
            pending = { kind = "status" }
        end
        dispatch()
    end, CMD_TIMEOUT_MS)

    if not started then
        busy = false
        reportError(noctalia.tr("notify.spawn-failed.body"))
    end
end

local function request(item)
    pending = item -- latest request wins; never dropped while another command runs
    dispatch()
end

-- `on` and `off` are no-ops when the switch is already in that position, so they
-- are safe to expose as idempotent actions.
noctalia.state.watch("command", function(command)
    if type(command) ~= "table" then
        return
    end
    local action = command.action
    if action == "on" or action == "off" or action == "toggle" then
        request({ kind = "action", action = action })
    elseif action == "refresh" then
        request({ kind = "status" })
    end
end)

function update()
    request({ kind = "status" })
end

noctalia.setUpdateInterval(INTERVAL)
request({ kind = "status" })

-- Leave no dangling state behind: hand the microphone back when the plugin is
-- switched off. The command is detached so it survives this runtime.
function onExit(_signal, reason)
    if reason ~= "disable" and reason ~= "uninstall" then
        return
    end
    if status and status.enabled and status.raw ~= "" then
        noctalia.runAsync({ "pactl", "set-default-source", status.raw })
    end
end

-- Manual trigger, handy for keybinds and for testing the state channel:
--   noctalia msg plugin goldesquemoon/mic-denoise:state all toggle
function onIpc(event)
    if event == "on" or event == "off" or event == "toggle" then
        request({ kind = "action", action = event })
    elseif event == "refresh" then
        request({ kind = "status" })
    end
end
