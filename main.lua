-- main.lua - Magpie Routes, a SnowDesktop API v2 routing board for magpie.
--
-- magpie is a local routing gateway for AI agents. It serves read-only HTTP
-- endpoints; this widget reads two of them and draws which agent called, which
-- account answered, and what the traffic cost:
--
--   /v1/magpie/usage/requests  recent routed requests plus period totals
--   /v1/magpie/quotas          per-account remaining budget
--
-- The board is a composition (three lanes joined by curved routes), so it uses
-- immediate rendering with a proportional visual layout: every length derives
-- from the current content box and scales with it.

local magpie = module.require("modules/magpie.lua")
local bird = module.require("modules/bird.lua")

local DEFAULT_GATEWAY = "http://127.0.0.1:3425"
local MAX_LANES = 4                     -- agent and account rows per side
local ROW_LIMIT = 24                    -- recent requests requested from magpie
local CYCLE_MS = 2400                   -- one agent -> hub -> account pass
local ACTIVE_MS = 120 * 1000             -- replay only while traffic is recent
local QUOTA_WARN = 15                    -- remaining percent that turns amber

local glyph = {
    refresh = utf8.char(0xF13D),
    clear = utf8.char(0xF201),
    settings = utf8.char(0xF6A9),
    period = utf8.char(0xF23C),
}

-- Agent accents follow each tool's brand so a lane is recognizable without
-- reading the label. Unknown agents fall back to a stable hash color.
local brands = {
    zcode = 0x3D6DF6,
    dsh = 0x4D6BFE,
    deepseek = 0x4D6BFE,
    claude = 0xD97757,
    ["claude-code"] = 0xD97757,
    codex = 0x10A37F,
    openai = 0x10A37F,
    gemini = 0x4285F4,
    kimi = 0x7C3AED,
    qoder = 0x10B981,
    cursor = 0x0EA5E9,
    opencode = 0xF59E0B,
    pi = 0xEC4899,
    grok = 0x64748B,
    tunnel = 0x8B5CF6,
}
local brandFallback = { 0x38BDF8, 0xFB7185, 0xA78BFA, 0x34D399, 0xFBBF24, 0x60A5FA, 0x2DD4BF }

local function brandColor(agent)
    local accent = brands[agent]
    if accent then return accent end
    local hash = 0
    for index = 1, #agent do
        hash = (hash * 31 + string.byte(agent, index)) % 100003
    end
    return brandFallback[hash % #brandFallback + 1]
end

local periods = { "today", "7d", "30d" }
local periodKeys = {
    today = "lua_widget.magpie_routes.period_today",
    ["7d"] = "lua_widget.magpie_routes.period_week",
    ["30d"] = "lua_widget.magpie_routes.period_month",
}

local settings = {
    presets = {
        {
            id = "frosted",
            label = l10n.tr("lua_widget.magpie_routes.preset_frosted"),
            default = true,
            values = {
                bg = 0x0B0B10,
                border = 0xFFFFFF,
                alpha = 0.16,
                borderAlpha = 0.10,
                gradientEndA = 0.16,
            },
        },
        {
            id = "solid",
            label = l10n.tr("lua_widget.magpie_routes.preset_solid"),
            values = {
                bg = 0x1A1A1E,
                border = 0xFFFFFF,
                alpha = 0.96,
                borderAlpha = 0.10,
                gradientEndA = 0.34,
            },
        },
        {
            id = "clear",
            label = l10n.tr("lua_widget.magpie_routes.preset_clear"),
            values = {
                bg = 0x000000,
                border = 0x000000,
                alpha = 0,
                borderAlpha = 0,
                gradientEndA = 0,
            },
        },
    },
    fields = {
        {
            key = "gateway",
            label = l10n.tr("lua_widget.magpie_routes.settings_gateway"),
            type = "text",
            default = DEFAULT_GATEWAY,
        },
        {
            key = "interval",
            label = l10n.tr("lua_widget.magpie_routes.settings_interval"),
            type = "duration",
            unit = "seconds",
            default = 3,
            min = 1,
            max = 60,
            step = 1,
        },
        {
            key = "period",
            label = l10n.tr("lua_widget.magpie_routes.settings_period"),
            type = "select",
            default = "today",
            options = periods,
            optionLabels = {
                l10n.tr("lua_widget.magpie_routes.period_today"),
                l10n.tr("lua_widget.magpie_routes.period_week"),
                l10n.tr("lua_widget.magpie_routes.period_month"),
            },
        },
        {
            key = "maskAccounts",
            label = l10n.tr("lua_widget.magpie_routes.settings_mask"),
            type = "bool",
            default = false,
        },
    },
}

local function config()
    local gateway = storage.get("gateway")
    if type(gateway) ~= "string" then gateway = "" end
    gateway = gateway:gsub("%s+", ""):gsub("/+$", "")
    if not gateway:match("^https?://[^/]+") then gateway = DEFAULT_GATEWAY end

    local interval = tonumber(storage.get("interval")) or 3
    interval = math.max(1, math.min(60, math.floor(interval)))

    local period = storage.get("period")
    if period ~= "7d" and period ~= "30d" then period = "today" end

    -- storage.get returns nil until the user touches a bool setting, so the
    -- manifest default is applied here instead of being implied by "~= 0".
    local mask = storage.get("maskAccounts")
    if mask == nil then mask = false else mask = mask ~= "0" end

    return {
        gateway = gateway,
        intervalMs = interval * 1000,
        period = period,
        maskAccounts = mask,
    }
end

local function palette(context)
    -- Text and accent follow magpie's own window (app.css); the surfaces are
    -- glass rather than the app's opaque cards, so the widget sits on the
    -- wallpaper as a pane instead of a dark panel.
    --
    -- The choice follows the host's resolved foreground, not the theme name: a
    -- glass material can be dark while the theme still reads "light".
    local snapshot = widget.theme()
    local darkInk = snapshot ~= nil and snapshot.contentTheme == 1
    if darkInk then
        return {
            glass = 0xFFFFFF, glassAlpha = 0.64,
            line = 0x000000, lineAlpha = 0.10,
            onInk = 0xFFFFFF,
            track = 0x000000, trackAlpha = 0.10,
            ink = 0x1C1C21, ink2 = 0x4B4B53, muted = 0x6F6F78, faint = 0x9A9AA3,
            accent = 0x4F46E5, accentSoft = 0xEEEDFD,
            good = 0x189A58, bad = 0xD64545, warn = 0xB45309,
            hair = 1,
        }
    end
    return {
        glass = 0xFFFFFF, glassAlpha = 0.07,
        line = 0xFFFFFF, lineAlpha = 0.15,
        onInk = 0x14141A,
        track = 0xFFFFFF, trackAlpha = 0.18,
        ink = 0xEDEDF1, ink2 = 0xC3C3CB, muted = 0x9C9CA6, faint = 0x74747E,
        accent = 0xA5B4FC, accentSoft = 0x2B2C47,
        good = 0x6FD99B, bad = 0xF28B82, warn = 0xF2B544,
        hair = 1,
    }
end

-- ---------------------------------------------------------------------------
-- Request pipeline
--
-- network.request allows two concurrent calls per instance. The usage poll is
-- the one that matters; quotas refresh on a slower cadence and a failure there
-- only degrades the per-account percentages.
-- ---------------------------------------------------------------------------

local function enqueue(model, kind, url)
    for index = 1, #model.pending do
        if model.pending[index].kind == kind then
            model.pending[index].url = url
            return
        end
    end
    model.pending[#model.pending + 1] = { kind = kind, url = url }
end

local function pump(model)
    while model.inFlight < 2 and #model.pending > 0 do
        local job = table.remove(model.pending, 1)
        local arguments = {
            url = job.url,
            timeoutMs = 8000,
            cacheSeconds = 0,
            maxBytes = model.maxBytes,
        }
        if widget.hasFeature("task.network.headers") then
            arguments.headers = { Accept = "application/json" }
        end
        local taskId, taskError = task.start("network.request", arguments)
        if not taskId then
            model.error = taskError or "requestRejected"
            return
        end
        model.tasks[taskId] = job.kind
        model.inFlight = model.inFlight + 1
    end
end

local function poll(model, force)
    if model.preview then return end
    local cfg = config()
    local now = time.monotonic()

    -- Two reads on purpose: totals from the endpoint the app's Usage page
    -- shows, rows from the list endpoint. Their counters do not agree, and the
    -- widget must match the app.
    enqueue(model, "hits", cfg.gateway .. "/v1/magpie/usage?period=" .. cfg.period)
    enqueue(model, "rows", cfg.gateway .. "/v1/magpie/usage/requests?period=" ..
        cfg.period .. "&limit=" .. tostring(ROW_LIMIT))
    if force or now - model.quotaAt >= 60000 then
        enqueue(model, "quotas", cfg.gateway .. "/v1/magpie/quotas")
    end
    pump(model)
end

-- Frames are requested from event callbacks only, and the loop stops as soon as
-- the newest route is older than ACTIVE_MS, so an idle board costs nothing.
local function ensureFrames(model)
    if model.preview or model.framePending or model.reducedMotion then return end
    if not model.animating then return end
    if animation.requestFrame("live") then
        model.framePending = true
    else
        model.reducedMotion = true
    end
end

local function nowIsActive(model)
    return model.newestAt ~= nil and (time.now() - model.newestAt) <= ACTIVE_MS
end

-- Which agent an account mostly serves: the right-hand route takes that
-- agent's colour, so one glance answers "whose traffic is this".
-- Which agent an account mostly serves: the right-hand wire takes that
-- agent's colour, so one glance answers "whose traffic is this".
local function indexPairs(model)
    local links = magpie.summarizePairs(model.rows)
    model.dominant = {}
    for index = 1, #links do
        local link = links[index]
        if model.dominant[link.account] == nil then
            model.dominant[link.account] = link.agent
        end
    end
end

-- The model the board is mostly routing to, for the hub's subtitle: the app's
-- hub names the route it is serving, not the gateway (that sits in the bar).
local function computeTopModel(model)
    local tally, topCount = {}, 0
    local providers, providerCount = {}, 0
    model.topModel, model.topProvider = nil, nil
    for index = 1, #model.rows do
        local row = model.rows[index]
        if type(row.model) == "string" and row.model ~= "" then
            local count = (tally[row.model] or 0) + 1
            tally[row.model] = count
            if count > topCount then
                topCount, model.topModel = count, row.model
            end
        end
        if type(row.provider) == "string" and row.provider ~= "" then
            local count = (providers[row.provider] or 0) + 1
            providers[row.provider] = count
            if count > providerCount then
                providerCount, model.topProvider = count, row.provider
            end
        end
    end
end

local function refresh(model, nowMs)
    model.agents = magpie.summarize(model.rows)
    model.accounts = magpie.summarizeAccounts(model.rows)
    indexPairs(model)
    computeTopModel(model)
    model.animating = model.newestAt ~= nil and (nowMs - model.newestAt) <= ACTIVE_MS
    if not model.animating then
        model.framePending = false
        model.anim = 0
    end
end

local function applyTotals(model, body)
    local payload, err = magpie.parseUsage(body)
    if not payload then
        model.error = err or "parseFailed"
        return false
    end
    model.usage = payload
    model.usagePeriod = payload.period
    model.usageAt = time.monotonic()
    model.loaded = true
    model.error = nil
    return true
end

local function applyRows(model, body)
    local payload, err = magpie.parseRequests(body)
    if not payload then
        model.error = err or "parseFailed"
        return false
    end
    model.rows = magpie.newestFirst(payload.rows)
    model.newestAt = model.rows[1] and model.rows[1].at or nil
    model.loaded = true
    model.error = nil
    refresh(model, time.now())
    return true
end

-- ---------------------------------------------------------------------------
-- Preview fixture
--
-- The preview host answers network.request with a fixed mock, so preview builds
-- its board from previewData.storage instead, like the bundled widgets do.
-- ---------------------------------------------------------------------------

local previewSeries = {
    0, 0, 1, 4, 9, 14, 11, 7, 5, 8, 12, 16, 9, 6, 3, 4, 8, 13, 10, 6, 2, 1, 0, 0,
}

local function loadPreview(model)
    model.preview = true

    local agents = {}
    for name, label, count in tostring(storage.get("previewAgents") or "")
        :gmatch("([^|;]+)|([^|;]+)|(%d+)") do
        agents[#agents + 1] = {
            key = name,
            label = label,
            count = tonumber(count),
            tokens = (tonumber(count) or 0) * 1460,
            accounts = {},
            models = {},
        }
    end
    table.sort(agents, function(left, right) return left.count > right.count end)
    model.agents = agents

    local accounts = {}
    for name, percent, count, display in tostring(storage.get("previewAccounts") or "")
        :gmatch("([^|;]+)|(%d+)|(%d+)|([^;]*)") do
        local key = name
        accounts[#accounts + 1] = {
            key = key,
            label = select(2, magpie.splitAccount(name)),
            speed = 34 + (#accounts + 1) * 6,
            model = storage.get("previewModel") or "",
            status = 200,
            count = tonumber(count) or 1,
            tokens = 0,
            agents = {},
            models = {},
        }
        model.quotas[key] = {
            remaining = tonumber(percent) or 0,
            display = display ~= "" and display or nil,
            resetAt = time.now() + (2 + #accounts) * 86400000,
        }
    end
    table.sort(accounts, function(left, right) return left.count > right.count end)
    model.accounts = accounts

    local usage = {
        period = config().period,
        calls = 0,
        input = 0,
        output = 0,
        cacheRead = 0,
        cost = 0,
        series = previewSeries,
    }
    local fields = {}
    for field in tostring(storage.get("previewUsage") or ""):gmatch("[^|]+") do
        fields[#fields + 1] = field
    end
    usage.input = tonumber(fields[1]) or 0
    usage.output = tonumber(fields[2]) or 0
    usage.calls = tonumber(fields[3]) or 0
    usage.cost = tonumber(fields[4]) or 0
    usage.cacheRead = tonumber(fields[5]) or 0
    model.usage = usage
    model.usagePeriod = usage.period

    model.rows = {}
    for agentIndex = 1, #agents do
        local agent = agents[agentIndex]
        -- Each preview agent keeps to one account, the common shape on a real
        -- board and the clearest way to show a route.
        local account = accounts[((agentIndex - 1) % math.max(1, #accounts)) + 1]
        for step = 1, math.min(agent.count, 3) do
            model.rows[#model.rows + 1] = {
                id = agent.key .. "#" .. tostring(step),
                agent = agent.key,
                label = agent.label,
                model = storage.get("previewModel") or "",
                effort = step == 1 and "max" or nil,
                account = account and account.key or nil,
            }
        end
    end
    model.animating = true
    model.loaded = true
    indexPairs(model)
    computeTopModel(model)
end

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------

local function textAt(text, x, y, size, color, maxWidth, bold, alpha)
    draw.text(x, y, text, size, color, maxWidth, bold or false, true, 0, alpha or 1)
end

-- measureText() with a maxWidth reports the wrapped block's height while
-- draw.text(..., singleLine=true) paints one line, so every single-line label
-- is centred on a plain line box.
local function textMid(text, x, centerY, size, color, maxWidth, bold, alpha)
    local metrics = draw.measureText("Ag", size, 0, bold or false)
    textAt(text, x, centerY - metrics.height / 2, size, color, maxWidth, bold, alpha)
end

local function textRight(text, right, centerY, size, color, bold, alpha)
    local metrics = draw.measureText(text, size, 0, bold or false)
    textAt(text, right - metrics.width, centerY - metrics.height / 2,
        size, color, 0, bold, alpha)
end

-- draw.measureText is a host call and a frame measures many strings twice
-- (once to centre or fit them, once to draw). Memoise by text, size and weight;
-- the table resets if a widget ever produces a lot of distinct strings.
local measureCache, measureEntries = {}, 0

local function measure(text, size, bold)
    local key = text .. "|" .. string.format("%.1f", size) .. (bold and "|b" or "")
    local cached = measureCache[key]
    if cached then return cached end
    if measureEntries >= 512 then
        measureCache, measureEntries = {}, 0
    end
    local metrics = draw.measureText(text, size, 0, bold or false)
    measureCache[key] = metrics
    measureEntries = measureEntries + 1
    return metrics
end

local function textWidth(text, size, bold)
    return measure(text, size, bold).width
end

local function lineHeight(size, bold)
    return measure("Ag", size, bold).height
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

-- A card on the widget's own surface: the app's own .rt-node recipe, a fill
-- one step lighter than the page plus a hairline.
local function cardSurface(x, y, w, h, radius, c, strength, borderColor)
    strength = strength or 1
    draw.rect(x, y, w, h, c.glass, radius, c.glassAlpha * strength)
    draw.strokeRect(x, y, w, h, borderColor or c.line, radius, c.hair,
        c.lineAlpha * strength)
end

-- A quota meter: the app's .quota-track, a solid accent fill that turns amber
-- when the balance runs out.
local function meter(x, y, w, h, percent, c, low)
    if w < 3 or h < 1 then return end
    local radius = math.min(h / 2, w / 2)
    draw.rect(x, y, w, h, c.track, radius, c.trackAlpha)
    local filled = math.floor(w * clamp(percent, 0, 100) / 100)
    if filled >= 2 then
        draw.rect(x, y, filled, h, low and c.warn or c.accent, radius, 0.95)
    end
end

-- The app's live wire: a solid hairline at rest, and dashes in the agent's
-- colour running along it while a request is on the way.
local function wireRail(x1, y1, x2, y2, color, alpha, thickness)
    local middle = (x1 + x2) / 2
    draw.path({
        { op = "move", x = x1, y = y1 },
        { op = "cubic", x1 = middle, y1 = y1, x2 = middle, y2 = y2, x = x2, y = y2 },
    }, { strokeColor = color, thickness = thickness, alpha = alpha })
end

local function curvePoint(x1, y1, x2, y2, t)
    local middle = (x1 + x2) / 2
    local inverse = 1 - t
    local a = inverse * inverse * inverse
    local b = 3 * inverse * inverse * t
    local c = 3 * inverse * t * t
    local d = t * t * t
    return a * x1 + b * middle + c * middle + d * x2,
        a * y1 + b * y1 + c * y2 + d * y2
end

-- Dashes as short straight segments along the curve: no per-frame table
-- allocation, and at these lengths the chord is indistinguishable.
local function wireDashes(x1, y1, x2, y2, color, phase, dashCount, span,
    thickness, alpha)
    for index = 1, dashCount do
        local from = ((index - 1) / dashCount + phase) % 1
        local into = from + span
        if into <= 1 then
            local ax, ay = curvePoint(x1, y1, x2, y2, from)
            local mx, my = curvePoint(x1, y1, x2, y2, (from + into) / 2)
            local bx, by = curvePoint(x1, y1, x2, y2, into)
            draw.line(ax, ay, mx, my, thickness, color, alpha)
            draw.line(mx, my, bx, by, thickness, color, alpha)
        end
    end
end

local function laneRows(list, limit)
    if #list <= limit then return list, nil end
    local shown = {}
    local extra = { count = 0, tokens = 0, more = 0 }
    for index = 1, limit - 1 do
        shown[index] = list[index]
    end
    for index = limit, #list do
        extra.count = extra.count + (list[index].count or 0)
        extra.tokens = extra.tokens + (list[index].tokens or 0)
        extra.more = extra.more + 1
    end
    return shown, extra
end

local function isDimmed(model, kind, value)
    local filter = model.filter
    if not filter then return false end
    return filter.kind ~= kind or filter.value ~= value
end

local function regionSpec(spec, tooltip)
    if tooltip and tooltipSupported then
        spec.tooltip = tooltip
    end
    interaction.region(spec)
end



-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

-- Surface proportions in one table: the stage is the app's three columns
-- (agents | wire | hub | wire | accounts), scaled down for a desktop card.
local STAGE = {
    header = 0.16,
    footer = 0.155,
    wire = 0.085,
    hub = 0.24,
    hubCapByNode = 1.75,
    laneSplit = 0.42,
    nodeFill = 0.90,
    nodeContent = 4.0,
}

local function statusOf(model, c)
    if model.error then
        return c.bad, l10n.tr("lua_widget.magpie_routes.status_offline")
    end
    if not model.preview and not model.loaded then
        return c.faint, l10n.tr("lua_widget.magpie_routes.status_connecting")
    end
    return c.good, l10n.tr("lua_widget.magpie_routes.status_live")
end

-- One table per frame: geometry, fonts, colours and the pre-formatted labels
-- every surface needs. Built once, then passed to the drawing functions.
local function buildFrame(context, model)
    local width = layout.contentWidth()
    local height = layout.contentHeight()
    if width < 40 or height < 26 then return nil end

    local c = palette(context)
    local cfg = config()
    local short = math.min(width, height)
    local hair = math.max(1, short * 0.0022)
    c.hair = hair

    local inset = short * 0.045
    local left = inset
    local right = width - inset
    local top = inset
    local bottom = height - inset
    local usableWidth = math.max(1, right - left)
    local usableHeight = math.max(1, bottom - top)

    local headerHeight = usableHeight * STAGE.header
    local footerHeight = usableHeight * STAGE.footer
    local bodyTop = top + headerHeight
    local bodyBottom = bottom - footerHeight
    local bodyHeight = math.max(1, bodyBottom - bodyTop)

    local agentRows, agentExtra = laneRows(model.agents, MAX_LANES)
    local accountRows, accountExtra = laneRows(model.accounts, MAX_LANES)

    -- Text rides the host row unit: a taller span should show more rows, not
    -- bigger labels.
    local rowUnit = ui.metrics().layoutRowHeight
    local baseFont = math.min(rowUnit * 0.42, bodyHeight * 0.20)
    local smallFont = math.min(baseFont * 0.80, rowUnit * 0.34)
    local tinyFont = math.min(baseFont * 0.72, rowUnit * 0.30)

    local agentLines = #agentRows + (agentExtra and 1 or 0)
    local accountLines = #accountRows + (accountExtra and 1 or 0)
    local rowHeight = bodyHeight / clamp(math.max(agentLines, accountLines), 1, MAX_LANES)
    -- Cards size to their content and are centred in the lane: one agent should
    -- not become a tall empty panel.
    local nodeHeight = math.min(rowHeight * STAGE.nodeFill,
        baseFont * STAGE.nodeContent, bodyHeight)

    local wireSpan = usableWidth * STAGE.wire
    local hubWidth = math.min(bodyHeight * 0.86, usableWidth * STAGE.hub,
        nodeHeight * STAGE.hubCapByNode)
    local laneTotal = usableWidth - hubWidth - wireSpan * 2
    local agentWidth = laneTotal * STAGE.laneSplit
    local accountWidth = laneTotal - agentWidth
    local agentLeft = left
    local hubX = left + agentWidth + wireSpan
    local accountLeft = hubX + hubWidth + wireSpan

    local usage = model.usage
    local statusColor, statusText = statusOf(model, c)

    local f = {
        context = context, model = model, c = c, cfg = cfg,
        width = width, height = height, short = short, hair = hair,
        left = left, right = right, top = top, bottom = bottom,
        usableWidth = usableWidth, usableHeight = usableHeight,
        headerHeight = headerHeight, footerHeight = footerHeight,
        bodyTop = bodyTop, bodyBottom = bodyBottom, bodyHeight = bodyHeight,
        rowUnit = rowUnit,
        baseFont = baseFont, smallFont = smallFont, tinyFont = tinyFont,
        headerFont = math.min(rowUnit * 0.42, headerHeight * 0.46),
        agentRows = agentRows, agentExtra = agentExtra,
        accountRows = accountRows, accountExtra = accountExtra,
        agentLines = agentLines, accountLines = accountLines,
        rowHeight = rowHeight, nodeHeight = nodeHeight,
        agentLeft = agentLeft, agentWidth = agentWidth,
        agentRight = left + agentWidth,
        accountLeft = accountLeft, accountWidth = accountWidth,
        hubWidth = hubWidth, hubX = hubX,
        hubCenterX = hubX + hubWidth / 2,
        hubCenterY = bodyTop + bodyHeight / 2,
        usage = usage, recentCount = #model.rows,
        statusColor = statusColor, statusText = statusText,
        gateway = cfg.gateway:gsub("^https?://", ""),
        tokensText = usage and magpie.compact(usage.input + usage.output) or "--",
        periodLabel = l10n.tr(periodKeys[cfg.period]),
        compact = layout.rows() <= 1,
    }
    f.laneCenter = function(index, lines)
        local block = lines * rowHeight
        return bodyTop + (bodyHeight - block) / 2 + rowHeight * (index - 0.5)
    end
    return f
end

-- Centre a single-line label inside a box and report the width it may use.
-- Clamping first matters: centring on a label wider than the box pushes its
-- start left of the box, and the host clips from there instead of centring.
local function centeredBox(text, boxLeft, boxWidth, size, bold, room)
    local maxWidth = math.max(1, math.min(boxWidth, room or boxWidth))
    local width = math.min(textWidth(text, size, bold), maxWidth)
    return boxLeft + (boxWidth - width) / 2, width
end

-- A clickable card region: every lane and the counter share this shape.
local function nodeRegion(key, shape, actionId, value, label, tooltip)
    regionSpec({
        key = key, shape = shape, cursor = "hand",
        events = {
            click = { id = actionId, value = value },
            contextMenu = { id = "route.menu", scope = "component", value = value },
        },
        accessibility = { role = "button", label = label },
    }, tooltip)
end

local function drawPeriodPill(f, x, y, w, h, radius, label, tooltip)
    local c = f.c
    local hovered = interaction.isHovered("pill")
    draw.rect(x, y, w, h, c.glass, radius,
        hovered and c.glassAlpha * 2.2 or c.glassAlpha * 1.5)
    draw.strokeRect(x, y, w, h, c.line, radius, f.hair,
        hovered and 0.9 or 0.55)
    regionSpec({
        key = "pill",
        shape = { type = "roundedRect", x = x, y = y, width = w, height = h, radius = radius },
        cursor = "hand",
        events = {
            click = { id = "period.next" },
            contextMenu = { id = "route.menu", scope = "component" },
        },
        accessibility = { role = "button", label = label },
    }, tooltip)
end

-- Header switch: three segments (today / week / 30 days), the same control the
-- TickTick board uses. Geometry is computed once so the top bar can centre it
-- before drawing; the tokens that used to sit in this pill already live in the
-- footer, so the switch carries no duplicated figure.
local function periodSegments(f, height)
    local font = math.max(7, math.min(f.rowUnit * 0.30, height * 0.47))
    local labels, widths, total = {}, {}, 0
    for index = 1, #periods do
        local label = l10n.tr(periodKeys[periods[index]])
        local width = textWidth(label, font, false) + height * 0.58
        labels[index], widths[index] = label, width
        total = total + width
    end
    return labels, widths, total + height * 0.10, font
end

local function drawPeriodSwitch(f, x, y, height)
    local c = f.c
    local labels, widths, total, font = periodSegments(f, height)
    local radius = height / 2
    draw.rect(x, y, total, height, c.glass, radius, c.glassAlpha * 2.2)
    draw.strokeRect(x, y, total, height, c.line, radius, f.hair,
        c.lineAlpha * 0.9)

    local cursor = x + height * 0.05
    for index = 1, #periods do
        local id = periods[index]
        local active = f.cfg.period == id
        if active then
            draw.rect(cursor, y, widths[index], height, c.glass, radius,
                c.glassAlpha * 3.6)
            draw.strokeRect(cursor, y, widths[index], height, c.line, radius,
                f.hair, c.lineAlpha * 1.2)
        end
        local boxX, boxWidth = centeredBox(labels[index], cursor, widths[index],
            font, false, widths[index] - 4)
        textMid(labels[index], boxX, y + height / 2, font,
            active and c.ink or c.muted, boxWidth, false)
        regionSpec({
            key = "period:" .. id,
            shape = { type = "roundedRect", x = cursor, y = y,
                width = widths[index], height = height, radius = radius },
            cursor = "hand",
            events = {
                click = { id = "period.set", value = id },
                contextMenu = { id = "route.menu", scope = "component" },
            },
            accessibility = { role = "button", label = labels[index] },
        })
        cursor = cursor + widths[index]
    end
    return total
end

-- Compact bar: one row of height shows connection, recent count and usage.
local function drawCompactBar(f)
    local c, model = f.c, f.model
    local labelFont = math.min(f.usableHeight * 0.30, f.rowUnit * 0.54)
    local metaFont = math.max(labelFont * 0.60,
        math.min(f.usableHeight * 0.17, f.rowUnit * 0.30))
    local midY = f.top + f.usableHeight / 2

    local dotR = math.max(2, labelFont * 0.28)
    draw.circle(f.left + dotR, midY - labelFont * 0.62, dotR, f.statusColor, 0.95)
    if model.animating then
        draw.circle(f.left + dotR, midY - labelFont * 0.62, dotR * 2.2,
            f.statusColor, 0.12)
    end
    local statusX = f.left + dotR * 2.4
    textMid(f.statusText, statusX, midY - labelFont * 0.62, labelFont, c.ink,
        f.usableWidth * 0.30, true)
    textMid(f.gateway, statusX, midY + labelFont * 0.92, metaFont, c.faint,
        f.usableWidth * 0.34, false)

    local countText = f.recentCount > 0 and tostring(f.recentCount) or "--"
    local pillW = math.min(f.usableWidth * 0.26, labelFont * 6.2)
    local pillH = math.min(f.usableHeight * 0.88, labelFont * 4.2)
    local pillXC = f.left + f.usableWidth / 2 - pillW / 2
    local pillYC = midY - pillH / 2
    cardSurface(pillXC, pillYC, pillW, pillH, pillH * 0.30, c, 1)
    local countFont = pillH * 0.50
    local caption = l10n.tr("lua_widget.magpie_routes.hub_caption")
    local countLine = lineHeight(countFont, true)
    local stackHeight = countLine + lineHeight(metaFont, false) * 0.55
    local stackTop = midY - stackHeight / 2
    textAt(countText, pillXC + pillW / 2 - textWidth(countText, countFont, true) / 2,
        stackTop, countFont, f.recentCount > 0 and c.ink or c.faint, 0, true)
    if stackHeight < pillH * 0.80 then
        textAt(caption, pillXC + pillW / 2 - textWidth(caption, metaFont, false) / 2,
            stackTop + countLine * 0.94, metaFont, c.muted, 0, false)
    end
    drawPeriodPill(f, pillXC, pillYC, pillW, pillH, pillH * 0.30, countText)

    local tokensFont = math.min(labelFont * 1.45, f.usableHeight * 0.28)
    local rightRoom = math.max(1, f.right - (pillXC + pillW) - f.short * 0.02)
    local natural = textWidth(f.tokensText, tokensFont, true)
    if natural > rightRoom then
        tokensFont = tokensFont * math.max(0.55, rightRoom / math.max(1, natural))
    end
    textRight(f.tokensText, f.right, midY - labelFont * 0.62, tokensFont, c.ink, true)
    local callText = f.usage
        and l10n.tr("lua_widget.magpie_routes.compact_calls",
            f.periodLabel, magpie.compact(f.usage.calls))
        or l10n.tr("lua_widget.magpie_routes.footer_waiting")
    if textWidth(callText, metaFont, false) <= rightRoom then
        textRight(callText, f.right, midY + labelFont * 0.92, metaFont, c.muted, false)
    end
end

local function drawTopBar(f)
    local c = f.c
    local centerY = f.top + f.headerHeight / 2
    local dotRadius = math.max(1.5, f.headerHeight * 0.075)
    local dotX = f.left + dotRadius
    draw.circle(dotX, centerY, dotRadius, f.statusColor, 1)
    if f.model.animating then
        draw.circle(dotX, centerY, dotRadius * 2.6, f.statusColor, 0.14)
    end

    local windowFont = math.min(f.rowUnit * 0.32, f.headerHeight * 0.34)
    local switchHeight = math.min(f.headerHeight * 0.62, f.rowUnit * 0.78)
    local _, _, switchWidth = periodSegments(f, switchHeight)
    local switchX = f.left + (f.usableWidth - switchWidth) / 2
    drawPeriodSwitch(f, switchX, centerY - switchHeight / 2, switchHeight)

    local statusX = dotX + dotRadius * 2.6
    textMid(f.statusText, statusX, centerY, f.headerFont, c.ink2,
        math.max(1, switchX - statusX - f.short * 0.02), false)

    local gatewayWidth = textWidth(f.gateway, windowFont, false)
    if f.right - (switchX + switchWidth) > gatewayWidth + f.short * 0.03 then
        textRight(f.gateway, f.right, centerY, windowFont, c.faint, false)
    end
end

local function drawFooter(f)
    local c = f.c
    local centerY = f.bodyBottom + f.footerHeight / 2
    draw.line(f.left, f.bodyBottom + f.footerHeight * 0.04, f.right,
        f.bodyBottom + f.footerHeight * 0.04, f.hair, c.line, 0.55)

    local usage = f.usage
    local stats = {
        { value = usage and magpie.compact(usage.calls) or "--",
          label = l10n.tr("lua_widget.magpie_routes.stat_calls") },
        { value = f.tokensText,
          label = l10n.tr("lua_widget.magpie_routes.stat_tokens") },
        { value = usage and string.format("%.2f", usage.cost or 0) or "--",
          label = l10n.tr("lua_widget.magpie_routes.stat_spend") },
    }
    local valueFont = math.min(f.rowUnit * 0.60, f.footerHeight * 0.44)
    local labelFont = math.min(f.rowUnit * 0.34, f.footerHeight * 0.26)
    local sparkWidth = usage and #usage.series > 1 and f.usableWidth * 0.26 or 0
    local valueLine = lineHeight(valueFont, true)
    local statTop = centerY - (valueLine + lineHeight(labelFont, false) * 0.9) / 2
    local statX = f.left
    for index = 1, #stats do
        local stat = stats[index]
        textAt(stat.value, statX, statTop, valueFont, c.ink, 0, true)
        textAt(stat.label, statX, statTop + valueLine * 0.94, labelFont, c.muted, 0, false)
        statX = statX + math.max(textWidth(stat.value, valueFont, true),
            textWidth(stat.label, labelFont, false)) + f.short * 0.06
        if statX > f.right - sparkWidth - valueFont then break end
    end
    if sparkWidth > 0 then
        local sparkHeight = f.footerHeight * 0.36
        draw.sparkline(usage.series, f.right - sparkWidth,
            centerY - sparkHeight / 2, sparkWidth, sparkHeight,
            c.accent, math.max(1, f.hair * 1.2), nil, nil, 0.85)
    end
end

local function drawEmpty(f)
    local c, model, cfg = f.c, f.model, f.cfg
    local message, hint
    if model.error == "permissionDenied" or model.error == "permissionRevoked" then
        message = l10n.tr("lua_widget.magpie_routes.error_permission")
        hint = cfg.gateway
    elseif model.error then
        message = l10n.tr("lua_widget.magpie_routes.error_offline")
        hint = l10n.tr("lua_widget.magpie_routes.hint_gateway", cfg.gateway)
    elseif model.loaded or model.preview then
        message = l10n.tr("lua_widget.magpie_routes.empty_no_routes")
        hint = l10n.tr("lua_widget.magpie_routes.hint_no_routes")
    else
        message = l10n.tr("lua_widget.magpie_routes.empty_connecting")
        hint = cfg.gateway
    end
    local titleFont = math.min(f.rowUnit * 0.52, f.bodyHeight * 0.16)
    textMid(message, f.left, f.bodyTop + f.bodyHeight * 0.44, titleFont,
        model.error and c.bad or c.ink2, f.usableWidth, true)
    textMid(hint, f.left, f.bodyTop + f.bodyHeight * 0.62, titleFont * 0.72,
        c.muted, f.usableWidth, false)
end

-- Wires: a hairline at rest, dashes in the agent's colour while live.
local function drawWires(f)
    local c, model = f.c, f.model
    local thickness = math.max(1, f.short * 0.0024)
    local sourceX = f.agentRight + f.hair
    local sinkX = f.accountLeft - f.hair
    local phase = model.animating and ((model.anim / CYCLE_MS) % 1) or 0

    for index = 1, #f.agentRows do
        local agent = f.agentRows[index]
        local y = f.laneCenter(index, f.agentLines)
        local dimmed = isDimmed(model, "agent", agent.key)
        wireRail(sourceX, y, f.hubX, f.hubCenterY, c.ink, dimmed and 0.06 or 0.16,
            thickness)
        if model.animating and not dimmed then
            wireDashes(sourceX, y, f.hubX, f.hubCenterY, brandColor(agent.key),
                phase, 4, 0.09, thickness, 0.9)
        end
    end
    for index = 1, #f.accountRows do
        local account = f.accountRows[index]
        local y = f.laneCenter(index, f.accountLines)
        local dimmed = isDimmed(model, "account", account.key)
        local owner = model.dominant and model.dominant[account.key]
        wireRail(f.hubX + f.hubWidth, f.hubCenterY, sinkX, y, c.ink,
            dimmed and 0.06 or 0.16, thickness)
        if model.animating and not dimmed then
            wireDashes(f.hubX + f.hubWidth, f.hubCenterY, sinkX, y,
                owner and brandColor(owner) or c.muted, phase, 4, 0.09,
                thickness, 0.9)
        end
    end
end

-- Hub: the bird, the name, one routing label and the count. The card takes its
-- width from the column but its height from its content, so a tall widget keeps
-- the label instead of dropping it.
local function drawHub(f)
    local c, model = f.c, f.model
    local width = f.hubWidth
    local chipText = f.recentCount > 0 and tostring(f.recentCount) or "--"
    local chipFont = math.min(f.rowUnit * 0.34, width * 0.15)
    local chipHeight = chipFont * 1.5
    local chipWidth = textWidth(chipText, chipFont, true) + chipHeight * 0.82
    local nameFont = math.min(f.rowUnit * 0.42, width * 0.19)
    local smallFont = math.min(f.rowUnit * 0.30, width * 0.13)
    local birdSide = math.min(width * 0.40, f.rowUnit * 0.95)

    local nameLine = lineHeight(nameFont, true)
    local birdGap = width * 0.03
    local badgeGap = width * 0.06
    local smallGap = width * 0.02
    local padY = math.max(width * 0.08, f.hair * 3)

    -- The app's hub names the gateway under the bird; the routed model is more
    -- useful where it fits. Either way the label is drawn only when it fits
    -- whole (one small step down allowed) — a clipped "deepseek-v4.1…" reads
    -- as broken text.
    local subtitle, subtitleFont = nil, smallFont
    local subtitleRoom = width - f.hair * 5
    local candidates = { model.topModel, model.topProvider, f.gateway }
    for index = 1, #candidates do
        local candidate = candidates[index]
        if type(candidate) == "string" and candidate ~= "" then
            local natural = textWidth(candidate, smallFont, false)
            if natural <= subtitleRoom then
                subtitle = candidate
                break
            elseif natural <= subtitleRoom / 0.82 then
                subtitle = candidate
                subtitleFont = smallFont * subtitleRoom / natural
                break
            end
        end
    end
    local smallLine = lineHeight(subtitleFont, false)

    local function stackHeightFor(bird, withSub, gap)
        local stack = bird + gap + nameLine + badgeGap + chipHeight
        if withSub then stack = stack + smallGap + smallLine end
        return stack
    end

    local hasSub = subtitle ~= nil and subtitle ~= ""
    local withSub = stackHeightFor(birdSide, hasSub, birdGap) + padY * 2
    local hubHeight = math.min(f.bodyHeight * 0.96, math.max(width, withSub))
    if hasSub and hubHeight < withSub - 0.5 then
        -- a smaller bird buys the label its line before it is dropped
        local shrunkGap = birdGap * 0.75
        if stackHeightFor(birdSide * 0.82, true, shrunkGap) + padY * 2 <= hubHeight then
            birdSide, birdGap = birdSide * 0.82, shrunkGap
        else
            hasSub = false
            hubHeight = math.min(f.bodyHeight * 0.96,
                math.max(width, stackHeightFor(birdSide, false, birdGap) + padY * 2))
        end
    end

    local hubTop = f.hubCenterY - hubHeight / 2
    local radius = math.min(width, hubHeight) * 0.24
    local centerX = f.hubCenterX

    draw.strokeRect(f.hubX - f.hair * 3.5, hubTop - f.hair * 3.5,
        width + f.hair * 7, hubHeight + f.hair * 7, c.line, radius + f.hair * 3.5,
        f.hair * 2, 0.10)
    cardSurface(f.hubX, hubTop, width, hubHeight, radius, c, 1, c.ink)

    local cursor = f.hubCenterY - stackHeightFor(birdSide, hasSub, birdGap) / 2
    bird.draw(centerX - birdSide / 2, cursor, birdSide, c.ink, 0.95)
    cursor = cursor + birdSide + birdGap
    local nameX, nameWidth = centeredBox("magpie", f.hubX, width, nameFont, true,
        width - f.hair * 2)
    textAt("magpie", nameX, cursor, nameFont, c.ink, nameWidth, true)
    cursor = cursor + nameLine
    if hasSub then
        textAt(subtitle, centerX - textWidth(subtitle, subtitleFont, false) / 2,
            cursor + smallGap * 0.5, subtitleFont, c.muted, width - f.hair * 2, false)
        cursor = cursor + smallGap + smallLine
    end
    cursor = cursor + badgeGap
    draw.rect(centerX - chipWidth / 2, cursor, chipWidth, chipHeight,
        c.ink, chipHeight / 2, 0.92)
    -- centre the label in the pill: textMid() draws from x, not from a centre
    textMid(chipText, centerX - textWidth(chipText, chipFont, true) / 2,
        cursor + chipHeight / 2, chipFont, c.onInk, 0, true)

    regionSpec({
        key = "hub",
        shape = { type = "roundedRect", x = f.hubX, y = hubTop,
            width = width, height = hubHeight, radius = radius },
        cursor = model.filter and "hand" or "default",
        events = { click = { id = "filter.clear" } },
        accessibility = { role = "button", label = "magpie" },
    })
end

local function drawAgentCards(f)
    local c, model = f.c, f.model
    local nameLine = lineHeight(f.baseFont, true)
    local metaFont = f.smallFont
    local metaLine = lineHeight(metaFont, false)
    local dotR = math.max(1.5, f.baseFont * 0.21)
    local dotGap = f.baseFont * 0.42
    local radius = math.min(f.nodeHeight * 0.28, 12 * (f.baseFont / 13))

    for index = 1, #f.agentRows do
        local agent = f.agentRows[index]
        local centerY = f.laneCenter(index, f.agentLines)
        local nodeY = centerY - f.nodeHeight / 2
        local dimmed = isDimmed(model, "agent", agent.key)
        local alpha = dimmed and 0.45 or 1
        local accent = brandColor(agent.key)
        local key = "agent." .. tostring(index)
        local label = agent.label or agent.key

        cardSurface(f.agentLeft, nodeY, f.agentWidth, f.nodeHeight, radius, c,
            dimmed and 0.5 or 1)
        if interaction.isHovered(key) then
            draw.strokeRect(f.agentLeft, nodeY, f.agentWidth, f.nodeHeight, c.ink,
                radius, f.hair, 0.55)
        end

        local metaText = l10n.tr("lua_widget.magpie_routes.agent_meta",
            tostring(agent.count), magpie.compact(agent.tokens))
        if textWidth(metaText, metaFont, false) > f.agentWidth - f.hair * 4 then
            -- the count survives, the token figure goes rather than being cut
            -- to "17.…"
            metaText = l10n.tr("lua_widget.magpie_routes.agent_count",
                tostring(agent.count))
        end
        local showMeta = nameLine * 0.95 + metaLine * 0.78 <= f.nodeHeight * 0.92
        local stackHeight = nameLine * 0.95
        if showMeta then stackHeight = stackHeight + metaLine * 0.78 end
        local stackTop = centerY - stackHeight / 2

        -- The name carries the row; a dot in the agent's colour keeps the tie
        -- to its wire without an icon the widget has no artwork for. Centre on
        -- the *clamped* width: centring on a label wider than the card pushed
        -- its start past the card's left edge and out of the widget.
        local nameX, nameWidth = centeredBox(label, f.agentLeft, f.agentWidth,
            f.baseFont, true, f.agentWidth - dotGap * 3)
        if nameWidth >= textWidth(label, f.baseFont, true) then
            draw.circle(nameX - dotGap - dotR, stackTop + nameLine / 2, dotR, accent, alpha)
        end
        textAt(label, nameX, stackTop, f.baseFont, c.ink, nameWidth, true, alpha)
        if showMeta then
            local metaX, metaWidth = centeredBox(metaText, f.agentLeft, f.agentWidth,
                metaFont, false, f.agentWidth - f.hair * 2)
            textAt(metaText, metaX, stackTop + nameLine * 0.86, metaFont, c.muted,
                metaWidth, false, alpha)
        end

        local tooltip
        if #agent.models > 0 then
            tooltip = l10n.tr("lua_widget.magpie_routes.tooltip_agent", label,
                tostring(agent.count), magpie.compact(agent.tokens))
        end
        nodeRegion(key, { type = "roundedRect", x = f.agentLeft, y = nodeY,
            width = f.agentWidth, height = f.nodeHeight, radius = radius },
            "agent.select", agent.key, label, tooltip)
    end

    if f.agentExtra then
        textMid(l10n.tr("lua_widget.magpie_routes.more_agents",
            tostring(f.agentExtra.more)), f.agentLeft + f.agentWidth * 0.05,
            f.laneCenter(#f.agentRows + 1, f.agentLines), f.tinyFont, c.muted,
            f.agentWidth, false)
    end
end

local function drawAccountCards(f)
    local c, model, cfg = f.c, f.model, f.cfg
    local nameLine = lineHeight(f.baseFont, true)
    local metaLine = lineHeight(f.tinyFont, false)
    local radius = math.min(f.nodeHeight * 0.26, 10 * (f.baseFont / 13))
    local padX = math.max(f.hair * 2,
        math.min(f.nodeHeight * 0.16, f.accountWidth * 0.06))
    local innerLeft = f.accountLeft + padX
    local innerRight = f.accountLeft + f.accountWidth - padX
    local innerWidth = math.max(1, innerRight - innerLeft)
    local dotR = math.max(1.5, f.nodeHeight * 0.035)
    local quotaHeight = math.max(2, f.nodeHeight * 0.055)
    local gap = f.nodeHeight * 0.07

    for index = 1, #f.accountRows do
        local account = f.accountRows[index]
        local centerY = f.laneCenter(index, f.accountLines)
        local nodeY = centerY - f.nodeHeight / 2
        local dimmed = isDimmed(model, "account", account.key)
        local alpha = dimmed and 0.45 or 1
        local quota = model.quotas[account.key]
        local low = quota ~= nil and quota.remaining < QUOTA_WARN
        local failed = account.status ~= nil and account.status >= 400
        local owner = model.dominant and model.dominant[account.key]
        local accent = owner and brandColor(owner) or c.muted
        local key = "account." .. tostring(index)

        local _, user = magpie.splitAccount(account.key)
        local name = user ~= "" and magpie.shortAccount(user) or account.key
        if cfg.maskAccounts then name = magpie.maskUser(name) end

        cardSurface(f.accountLeft, nodeY, f.accountWidth, f.nodeHeight, radius, c,
            dimmed and 0.5 or 1, failed and c.bad or nil)
        if not failed and interaction.isHovered(key) then
            draw.strokeRect(f.accountLeft, nodeY, f.accountWidth, f.nodeHeight, c.ink,
                radius, f.hair, 0.55)
        end

        local percentText = quota and string.format("%.0f%%", quota.remaining) or ""
        local percentW = percentText ~= "" and
            textWidth(percentText, f.smallFont, true) or 0

        -- The meta line: model on the left, speed pinned right. The model gives
        -- way before the live figure does, and drops out entirely when it would
        -- be cut to a stub.
        local modelText = account.model or ""
        if account.effort and account.effort ~= "" and modelText ~= "" then
            modelText = account.effort .. " · " .. modelText
        end
        local speedText = ""
        if account.speed and account.speed > 0 then
            speedText = l10n.tr("lua_widget.magpie_routes.account_speed",
                string.format("%.0f", account.speed))
        end
        local speedWidth = speedText ~= "" and
            (textWidth(speedText, f.tinyFont, false) + padX * 0.4) or 0
        local modelRoom = innerWidth - speedWidth
        local showModel = modelText ~= "" and
            textWidth(modelText, f.tinyFont, false) <= modelRoom / 0.7

        local usedHeight = nameLine + gap + quotaHeight
        local showMeta = (showModel or speedText ~= "") and
            f.nodeHeight >= usedHeight + gap + metaLine * 1.1
        if showMeta then usedHeight = usedHeight + gap + metaLine end
        local cursorY = centerY - usedHeight / 2

        -- the dot keeps the route's colour, and turns red when the account's
        -- latest request came back a failure
        draw.circle(innerLeft + dotR, cursorY + nameLine / 2, dotR,
            failed and c.bad or accent, alpha)
        local nameX = innerLeft + dotR * 2.4
        textMid(name, nameX, cursorY + nameLine / 2, f.baseFont, c.ink,
            math.max(1, innerRight - nameX - percentW - padX * 0.4), true, alpha)
        if percentText ~= "" then
            textRight(percentText, innerRight, cursorY + nameLine / 2, f.smallFont,
                low and c.warn or c.muted, true, alpha)
        end
        cursorY = cursorY + nameLine + gap

        if quota then
            meter(innerLeft, cursorY, innerWidth, quotaHeight, quota.remaining, c, low)
            cursorY = cursorY + quotaHeight
        end
        if showMeta then
            local metaY = cursorY + gap + metaLine / 2
            if showModel then
                textMid(modelText, innerLeft, metaY, f.tinyFont, c.muted,
                    modelRoom, false, alpha)
            end
            if speedText ~= "" then
                textRight(speedText, innerRight, metaY, f.tinyFont, c.muted,
                    false, alpha)
            end
        end

        local tooltip
        if quota then
            -- the row keeps the figure; the renewal and the raw amount live in
            -- the tooltip, as they do one page away in the app
            local detail = quota.display or "--"
            if quota.resetAt then
                local days = math.floor((quota.resetAt - time.now()) / 86400000)
                if days >= 0 then
                    detail = detail .. " · " .. l10n.tr(
                        "lua_widget.magpie_routes.quota_reset", tostring(days))
                end
            end
            tooltip = l10n.tr("lua_widget.magpie_routes.tooltip_quota", name,
                percentText, detail)
        end
        nodeRegion(key, { type = "roundedRect", x = f.accountLeft, y = nodeY,
            width = f.accountWidth, height = f.nodeHeight, radius = radius },
            "account.select", account.key, name, tooltip)
    end

    if f.accountExtra then
        textMid(l10n.tr("lua_widget.magpie_routes.more_accounts",
            tostring(f.accountExtra.more)), f.accountLeft + f.accountWidth * 0.04,
            f.laneCenter(#f.accountRows + 1, f.accountLines), f.tinyFont, c.muted,
            f.accountWidth, false)
    end
end

local function render(context, model)
    local f = buildFrame(context, model)
    if not f then return end

    -- Whole-surface context menu; registered first so nodes sit above it.
    regionSpec({
        key = "board",
        shape = { type = "rect", x = 0, y = 0, width = f.width, height = f.height },
        events = { contextMenu = { id = "route.menu", scope = "component" } },
        accessibility = { role = "group", label = l10n.tr("lua_widget.magpie_routes.name") },
    })

    if f.compact then
        drawCompactBar(f)
        return
    end

    drawTopBar(f)
    drawFooter(f)

    if #f.agentRows == 0 and #f.accountRows == 0 then
        drawEmpty(f)
        return
    end

    drawWires(f)
    drawHub(f)
    drawAgentCards(f)
    drawAccountCards(f)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function setup(context)
    local model = {
        rows = {},
        agents = {},
        accounts = {},
        pairs = {},
        dominant = {},
        quotas = {},
        usage = nil,
        usagePeriod = nil,
        newestAt = nil,
        loaded = false,
        animating = false,
        anim = 0,
        framePending = false,
        reducedMotion = false,
        filter = nil,
        error = nil,
        preview = false,
        pending = {},
        tasks = {},
        inFlight = 0,
        usageAt = -1e9,
        quotaAt = -1e9,
        maxBytes = widget.hasFeature("task.network.largeResponse")
            and 4 * 1024 * 1024 or 1024 * 1024,
    }
    widget.setTitle(l10n.tr("lua_widget.magpie_routes.name"))
    tooltipSupported = widget.hasFeature("interaction.tooltip")
    schedule.every("poll", config().intervalMs, { whenHidden = "pause" })
    if context.preview then
        loadPreview(model)
    else
        poll(model, true)
    end
    return model
end

local function setPeriod(model, period)
    storage.set("period", period)
    model.usagePeriod = nil
    -- Only the period-scoped endpoints changed; quotas are period-independent
    -- and already refreshed on their own minute timer.
    if not model.preview then poll(model, false) end
end

local function cyclePeriod(model)
    local cfg = config()
    local index = 1
    for position = 1, #periods do
        if periods[position] == cfg.period then index = position end
    end
    setPeriod(model, periods[(index % #periods) + 1])
end

local function resetData(model)
    model.rows = {}
    model.agents, model.accounts = {}, {}
    model.dominant = {}
    model.quotas = {}
    model.usage = nil
    model.usagePeriod = nil
    model.newestAt = nil
    model.loaded = false
    model.animating = false
    model.usageAt, model.quotaAt = -1e9, -1e9
    model.error = nil
end

local function event(_context, model, value)
    if value.kind == "schedule" and value.id == "poll" then
        poll(model, false)
        return
    elseif value.kind == "task.complete" then
        local kind = model.tasks[value.taskId]
        if not kind then return end
        model.tasks[value.taskId] = nil
        model.inFlight = math.max(0, model.inFlight - 1)

        local body = value.ok and value.value and value.value.body or nil
        if body and body ~= "" then
            if kind == "hits" then
                applyTotals(model, body)
            elseif kind == "rows" then
                applyRows(model, body)
            else
                local quotas = magpie.parseQuotas(body)
                if quotas then
                    model.quotas = quotas
                    model.quotaAt = time.monotonic()
                end
            end
        elseif kind == "rows" or kind == "hits" then
            model.error = value.error or "emptyResponse"
        end

        pump(model)
        ensureFrames(model)
        widget.invalidate()
        return
    elseif value.kind == "frame" and value.id == "live" then
        model.framePending = false
        if model.animating and nowIsActive(model) then
            model.anim = (model.anim + (value.deltaMs or 0)) % (CYCLE_MS * 1000)
            widget.invalidate()
        else
            model.animating = false
            model.anim = 0
            widget.invalidate()
        end
        ensureFrames(model)
        return
    elseif value.kind == "visibility" then
        if value.visible then ensureFrames(model) end
        return
    elseif value.kind == "settings.changed" then
        local keys = value.keys or {}
        for index = 1, #keys do
            if keys[index] == "gateway" then
                resetData(model)
            elseif keys[index] == "interval" then
                schedule.every("poll", config().intervalMs, { whenHidden = "pause" })
            elseif keys[index] == "period" then
                model.usagePeriod = nil
                poll(model, false)
                widget.invalidate()
            end
        end
        return
    elseif value.kind ~= "action" then
        return
    end

    if value.id == "refresh" then
        resetData(model)
        poll(model, true)
    elseif value.id == "period.next" then
        cyclePeriod(model)
    elseif value.id == "period.set" then
        local target = tostring(value.value or "today")
        local valid = false
        for index = 1, #periods do
            if periods[index] == target then valid = true end
        end
        setPeriod(model, valid and target or "today")
    elseif value.id == "filter.clear" then
        model.filter = nil
    elseif value.id == "agent.select" or value.id == "account.select" then
        local kind = value.id == "agent.select" and "agent" or "account"
        local target = tostring(value.value or "")
        if model.filter and model.filter.kind == kind and model.filter.value == target then
            model.filter = nil
        else
            model.filter = { kind = kind, value = target }
        end
    elseif value.id == "settings.open" then
        widget.openSettings()
    end
    -- Every action above changed something visible (period, filter, refresh).
    -- Without this the new segment only lit up when the next frame or network
    -- reply happened to repaint, which read as a laggy switch.
    widget.invalidate()
    ensureFrames(model)
end

local function menu(_context, model, request)
    if request.id ~= "route.menu" then return nil end

    local items = {
        {
            id = "refresh",
            label = l10n.tr("lua_widget.magpie_routes.menu_refresh"),
            icon = glyph.refresh,
            iconFont = "fluent",
        },
    }
    if model.filter then
        items[#items + 1] = {
            id = "filter.clear",
            label = l10n.tr("lua_widget.magpie_routes.menu_clear_filter"),
            icon = glyph.clear,
            iconFont = "fluent",
        }
    end
    items[#items + 1] = { type = "separator" }

    local cfg = config()
    for index = 1, #periods do
        items[#items + 1] = {
            id = "period.set",
            value = periods[index],
            label = l10n.tr(periodKeys[periods[index]]),
            icon = glyph.period,
            iconFont = "fluent",
            checked = cfg.period == periods[index],
        }
    end

    items[#items + 1] = { type = "separator" }
    items[#items + 1] = {
        id = "settings.open",
        label = l10n.tr("lua_widget.magpie_routes.menu_settings"),
        icon = glyph.settings,
        iconFont = "fluent",
    }
    return ui.menu(items)
end

local function dispose(_context, model)
    schedule.cancel("poll")
    if model.framePending then animation.cancelFrame("live") end
    for taskId in pairs(model.tasks) do
        task.cancel(taskId)
    end
end

return widget.define({
    name = l10n.tr("lua_widget.magpie_routes.name"),
    useCustomStyle = true,
    followPersonalizationDefault = true,
    bottomBarHover = false,
    bg = 0x0B0B10,
    border = 0xFFFFFF,
    alpha = 0.16,
    borderAlpha = 0.10,
    gradientEndA = 0.16,
    settings = settings,
    setup = setup,
    render = render,
    event = event,
    menu = menu,
    dispose = dispose,
})
