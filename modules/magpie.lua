-- modules/magpie.lua - pure projections for magpie's local gateway.
--
-- Everything here is side-effect free and host-API free so that
-- `snowwidget test` can exercise it without a running SnowDesktop. The shapes
-- come from magpie 0.1.x; the board reads these two endpoints:
--
--   /v1/magpie/usage/requests  recent routed requests plus period totals
--   /v1/magpie/quotas          per-account remaining budget

local json = module.require("modules/json.lua")

local sub = string.sub
local find = string.find

local magpie = {}

-- The sandbox enforces a per-callback execution quota, and a very large usage
-- or request response can hit it mid-decode, which arrives as a Lua error.
-- Uncaught, that aborts the whole event handler and the board hangs on its
-- last frame; caught, it becomes an ordinary parse failure that the next poll
-- retries. Same guard as the TickTick widget.
local function decode(body, skip)
    local ok, payload, err = pcall(json.decode, body, skip and { skip = skip } or nil)
    if not ok then return nil, "quotaExceeded" end
    return payload, err
end

-- The usage endpoint repeats its totals as a per-bucket `by` breakdown, and
-- `series` carries one of those per hour. The board only needs the flat totals
-- and the per-bucket call counts, so `by` is dropped wherever it appears.
local USAGE_SKIP = {
    by = true,
    callerKeys = true,
    through = true,
    direct = true,
    reported = true,
    providers = true,
    purposes = true,
    speeds = true,
    agents = true,
    accounts = true,
    big_write = true,
    -- Aggregates the board never reads. On a 30d window `sessions` alone is
    -- ~60 KB and `models` ~24 KB; parsing them pushed the response past the
    -- VM's execution quota, so a period switch silently failed and retried.
    sessions = true,
    sessionCount = true,
    models = true,
    providerKeys = true,
    path = true,
    since = true,
    retried = true,
    canceled = true,
    cache_write = true,
    cache_unknown = true,
    cache_unknown_calls = true,
    reasoning = true,
    unpriced = true,
    credits = true,
    credited = true,
    timed = true,
    decode_ms = true,
    decode_out = true,
    decode_n = true,
    up_bytes = true,
    down_bytes = true,
    up_calls = true,
    up_measured = true,
    up_system = true,
    up_tools = true,
    up_images = true,
    bucket = true,
    floor_out = true,
    floor_ms = true,
    floor_n = true,
    speed_min = true,
}

-- /usage/requests repeats every aggregate and carries an hourly series the
-- board never draws (the sparkline comes from /usage). On 30d that series is
-- ~59 KB, so it is skipped as well.
local ROWS_SKIP = {}
for key in pairs(USAGE_SKIP) do ROWS_SKIP[key] = true end
ROWS_SKIP.series = true
for _, key in ipairs({
    "host", "req", "rid", "response_id", "ep", "stop", "session",
    "native_session", "up_parts", "priced", "icon", "providerName", "access",
    "first_reasoning_ms", "masking_ms", "flow_ms",
}) do
    ROWS_SKIP[key] = true
end

-- Howard Hinnant's civil-from-days, inverted: epoch day number for a date.
function magpie.daysFromCivil(year, month, day)
    local adjusted = month <= 2 and year - 1 or year
    local era = math.floor(adjusted / 400)
    local yearOfEra = adjusted - era * 400
    local monthPrime = (month + 9) % 12
    local dayOfYear = math.floor((153 * monthPrime + 2) / 5) + day - 1
    local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4)
        - math.floor(yearOfEra / 100) + dayOfYear
    return era * 146097 + dayOfEra - 719468
end

-- magpie timestamps look like 2026-11-14T16:22:48.9162143+08:00. Returns UTC
-- epoch milliseconds, or nil when the field is missing or malformed.
function magpie.parseIso(value)
    if type(value) ~= "string" then return nil end
    local year, month, day, hour, minute, second, rest = value:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
    if not year then return nil end

    local seconds = magpie.daysFromCivil(
        tonumber(year), tonumber(month), tonumber(day)) * 86400
        + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)

    local fraction = rest:match("^%.(%d+)")
    local milliseconds = fraction and math.floor(tonumber("0." .. fraction) * 1000) or 0

    local sign, offsetHour, offsetMinute = rest:match("([%+%-])(%d%d):(%d%d)")
    if sign then
        local offset = tonumber(offsetHour) * 3600 + tonumber(offsetMinute) * 60
        seconds = sign == "+" and seconds - offset or seconds + offset
    end
    return seconds * 1000 + milliseconds
end

-- "provider@account"; rows without a resolved account (a failed request, or a
-- provider that never assigned one) have no destination lane.
function magpie.splitAccount(id)
    local provider, user = tostring(id or ""):match("^([^@]+)@(.+)$")
    if provider then return provider, user end
    local bare = tostring(id or "")
    return bare, bare
end

function magpie.accountKey(provider, account)
    if type(account) ~= "string" or account == "" then return nil end
    return tostring(provider or "") .. "@" .. account
end

local function projectRow(raw, index)
    if type(raw) ~= "table" then return nil end
    local id = raw.route_id
    if id == nil or json.isNull(id) then return nil end

    local input = tonumber(raw["in"]) or 0
    local output = tonumber(raw.out) or 0
    local agent = type(raw.agent) == "string" and raw.agent:lower() or ""
    if agent == "" then agent = "unknown" end
    local label = type(raw.agentName) == "string" and raw.agentName ~= ""
        and raw.agentName or agent
    local provider = type(raw.provider) == "string" and raw.provider or ""

    return {
        id = tostring(id),
        order = index,
        at = magpie.parseIso(raw.t),
        agent = agent,
        label = label,
        provider = provider,
        account = magpie.accountKey(provider, raw.providerAccount),
        model = type(raw.served) == "string" and raw.served
            or (type(raw.model) == "string" and raw.model or ""),
        effort = type(raw.effort) == "string" and raw.effort or nil,
        status = tonumber(raw.status),
        input = input,
        output = output,
        tokens = input + output,
        cacheRead = tonumber(raw.cache_read) or 0,
        ms = tonumber(raw.ms),
        ttft = tonumber(raw.ttft_ms),
    }
end

-- parseUsage(body) -> { period, calls, errors, input, output, cost, series }, nil
-- Totals come from /v1/magpie/usage, the endpoint magpie's own Usage page
-- reads. /usage/requests returns the same fields but counts differently (it
-- keeps rows magpie's usage view folds away), so mixing the two made the
-- widget's figures drift from the app's.
function magpie.parseUsage(body)
    local payload, err = decode(body, USAGE_SKIP)
    if not payload then return nil, err end
    if type(payload) ~= "table" then return nil, "notAnObject" end

    local series = {}
    if type(payload.series) == "table" then
        for index = 1, #payload.series do
            local bucket = payload.series[index]
            if type(bucket) == "table" then
                series[#series + 1] = tonumber(bucket.calls) or 0
            end
        end
    end
    return {
        period = type(payload.period) == "string" and payload.period or "today",
        calls = tonumber(payload.calls) or 0,
        errors = tonumber(payload.errors) or 0,
        input = tonumber(payload.input) or 0,
        output = tonumber(payload.output) or 0,
        cacheRead = tonumber(payload.cache_read) or 0,
        cost = tonumber(payload.cost),
        series = series,
    }
end

-- parseRequests(body) -> { period, calls, cost, rows }, nil
function magpie.parseRequests(body)
    local payload, err = decode(body, ROWS_SKIP)
    if not payload then return nil, err end
    if type(payload) ~= "table" then return nil, "notAnObject" end

    local rows, count = {}, 0
    if type(payload.rows) == "table" then
        for index = 1, #payload.rows do
            local row = projectRow(payload.rows[index], index)
            if row then
                count = count + 1
                rows[count] = row
            end
        end
    end

    return {
        period = type(payload.period) == "string" and payload.period or "today",
        total = tonumber(payload.total) or count,
        calls = tonumber(payload.calls) or count,
        errors = tonumber(payload.errors) or 0,
        input = tonumber(payload.input) or 0,
        output = tonumber(payload.output) or 0,
        cacheRead = tonumber(payload.cache_read) or 0,
        cost = tonumber(payload.cost),
        rows = rows,
    }
end

local function bucket(map, keys, key)
    local group = map[key]
    if group then return group end
    group = {
        key = key,
        label = key,
        count = 0,
        tokens = 0,
        lastAt = 0,
        accounts = {},
        accountKeys = {},
        agents = {},
        agentKeys = {},
        models = {},
        modelKeys = {},
    }
    map[key] = group
    keys[#keys + 1] = group
    return group
end

local function noteMember(group, values, seen, value)
    if value == nil or value == "" or seen[value] then return end
    seen[value] = true
    values[#values + 1] = value
end

local function byActivity(left, right)
    if left.count ~= right.count then return left.count > right.count end
    return left.key < right.key
end

function magpie.summarize(rows)
    local groups, order = {}, {}
    for index = 1, #rows do
        local row = rows[index]
        local group = bucket(groups, order, row.agent)
        group.label = row.label
        group.count = group.count + 1
        group.tokens = group.tokens + row.tokens
        if (row.at or 0) > group.lastAt then group.lastAt = row.at or 0 end
        if row.account then
            noteMember(group, group.accounts, group.accountKeys, row.account)
        end
        noteMember(group, group.models, group.modelKeys, row.model)
    end
    table.sort(order, byActivity)
    return order
end

function magpie.summarizeAccounts(rows)
    local groups, order = {}, {}
    for index = 1, #rows do
        local row = rows[index]
        if row.account then
            local group = bucket(groups, order, row.account)
            local provider, user = magpie.splitAccount(row.account)
            group.label = user
            group.provider = provider
            group.count = group.count + 1
            group.tokens = group.tokens + row.tokens
            if (row.at or 0) > group.lastAt then group.lastAt = row.at or 0 end
            if group.count == 1 then
                -- Rows arrive newest first, so the first one seen for an
                -- account is its latest request: that is what the card shows.
                group.model = row.model
                group.effort = row.effort
                group.status = row.status
                group.lastTokens = row.tokens
                local decode = (row.ms or 0) - (row.ttft or 0)
                if decode > 0 and row.output > 0 then
                    group.speed = row.output / (decode / 1000)
                end
            end
            noteMember(group, group.agents, group.agentKeys, row.agent)
            noteMember(group, group.models, group.modelKeys, row.model)
        end
    end
    table.sort(order, byActivity)
    return order
end

function magpie.summarizePairs(rows)
    local groups, order = {}, {}
    for index = 1, #rows do
        local row = rows[index]
        if row.account then
            local key = row.agent .. "|" .. row.account
            local group = groups[key]
            if not group then
                group = { agent = row.agent, account = row.account, count = 0 }
                groups[key] = group
                order[#order + 1] = group
            end
            group.count = group.count + 1
        end
    end
    table.sort(order, function(left, right)
        if left.count ~= right.count then return left.count > right.count end
        return left.agent .. left.account < right.agent .. right.account
    end)
    return order
end

-- Newest first, which is the order the board replays.
function magpie.newestFirst(rows)
    local sorted = {}
    for index = 1, #rows do sorted[index] = rows[index] end
    table.sort(sorted, function(left, right)
        if (left.at or 0) ~= (right.at or 0) then
            return (left.at or 0) > (right.at or 0)
        end
        return left.id < right.id
    end)
    return sorted
end

-- parseQuotas(body) -> { ["provider@account"] = { remaining, limit, display, … } }
-- magpie reports one entry per account with several credit windows. The widget
-- shows the overall budget: the widest window that carries a unit, because
-- model token windows have no unit and are orders of magnitude larger.
function magpie.parseQuotas(body)
    local payload, err = decode(body)
    if not payload or type(payload) ~= "table" then return nil, err or "notAnObject" end
    if type(payload.data) ~= "table" then return nil, "notAnObject" end

    local quotas = {}
    for index = 1, #payload.data do
        local entry = payload.data[index]
        if type(entry) == "table" then
            local provider = type(entry.provider) == "string" and entry.provider or ""
            local user = type(entry.user) == "string" and entry.user or ""
            local chosen, fallback
            if type(entry.windows) == "table" then
                for windowIndex = 1, #entry.windows do
                    local window = entry.windows[windowIndex]
                    if type(window) == "table" then
                        local remaining = tonumber(window.remaining)
                        local limit = tonumber(window.limit)
                        if remaining and limit and limit > 0 then
                            local candidate = {
                                remaining = math.max(0, math.min(100, remaining)),
                                limit = limit,
                                unit = type(window.unit) == "string" and window.unit or nil,
                                display = type(window.display) == "string" and window.display or nil,
                                name = type(window.name) == "string" and window.name or nil,
                                resetAt = magpie.parseIso(window.resetsAt),
                            }
                            if candidate.unit then
                                if not chosen or candidate.limit > chosen.limit then
                                    chosen = candidate
                                end
                            elseif not fallback then
                                fallback = candidate
                            end
                        end
                    end
                end
            end
            chosen = chosen or fallback
            if chosen then
                chosen.plan = type(entry.plan) == "string" and entry.plan or nil
                quotas[provider .. "@" .. user] = chosen
            end
        end
    end
    return quotas
end

local units = {
    { size = 1e9, suffix = "B" },
    { size = 1e6, suffix = "M" },
    { size = 1e3, suffix = "k" },
}

function magpie.compact(value)
    local number = tonumber(value) or 0
    if number < 0 then number = 0 end
    if number < 1000 then return string.format("%.0f", number) end
    for index = 1, #units do
        local unit = units[index]
        if number >= unit.size then
            local scaled = number / unit.size
            local text
            if scaled >= 100 then
                text = string.format("%.0f", scaled)
            elseif scaled >= 10 then
                text = string.format("%.1f", scaled)
            else
                text = string.format("%.2f", scaled)
            end
            if find(text, ".", 1, true) then
                text = text:gsub("0+$", ""):gsub("%.$", "")
            end
            return text .. unit.suffix
        end
    end
    return string.format("%.0f", number)
end

-- A rounded-out account id such as "Acme-pu-0f0f0f0f-1111-…" is
-- is meaningless in a 110 px column. Keep the readable head and the last four
-- characters so two accounts of the same provider stay distinguishable; email
-- accounts keep just the local part.
function magpie.shortAccount(user)
    local text = tostring(user or "")
    if text == "" then return text end
    local at = find(text, "@", 1, true)
    if at and at > 1 then
        text = sub(text, 1, at - 1)
    end
    if #text > 14 and find(text, "-", 1, true) then
        local head = text:match("^([%w]+)%-") or sub(text, 1, 8)
        return head .. "\194\183" .. sub(text, -4)
    end
    return text
end

local function firstCharacters(text, count)
    local offset = utf8.offset(text, count + 1)
    if not offset then return text end
    return sub(text, 1, offset - 1)
end

function magpie.maskUser(user)
    local text = tostring(user or "")
    if text == "" then return text end
    if (utf8.len(text) or #text) <= 4 then return text end
    return firstCharacters(text, 2) .. "\226\128\166"
end

return magpie
