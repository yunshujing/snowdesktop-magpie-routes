local magpie = module.require("modules/magpie.lua")

local function same(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label,
            tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(value, label)
    if not value then error(label, 2) end
end

local function near(actual, expected, tolerance, label)
    if math.abs((actual or 0) - expected) > tolerance then
        error(string.format("%s: expected ~%s, got %s", label,
            tostring(expected), tostring(actual)), 2)
    end
end

-- Trimmed from magpie 0.1.x /v1/magpie/usage/requests: recent rows, period
-- totals, a per-bucket series that repeats the totals as `by`, and account
-- rows that failed before an account was assigned.
local REQUESTS = [[
{"period":"today","limit":3,"offset":0,"total":1298,
 "rows":[
  {"route_id":1794636618856,"t":"2026-11-14T16:22:48.9162143+08:00","agent":"zcode",
   "provider":"workbuddy","providerAccount":"alice","model":"deepseek-v4.1-flash",
   "served":"deepseek-v4.1-flash","req":"workbuddy/deepseek-v4.1-flash",
   "effort":"max","in":382,"out":1571,"cache_read":268288,"reasoning":1270,
   "ms":11972,"ttft_ms":4025,"status":200,"agentName":"ZCode",
   "providerName":"WorkBuddy","up_parts":{"system":30575,"tools":22931}},
  {"route_id":1794636618855,"t":"2026-11-14T16:22:20.0000000+08:00","agent":"codebuddy",
   "provider":"session-unknown","model":"deepseek-v4.1-flash","in":10,"out":0,
   "cache_read":0,"ms":40,"status":0,"agentName":"CodeBuddy"},
  {"route_id":1794636618854,"t":"2026-11-14T16:21:02.0000000+08:00","agent":"zcode",
   "provider":"workbuddy","providerAccount":"alice","served":"deepseek-v4.1-flash-sg",
   "in":100,"out":50,"cache_read":1000,"ms":900,"status":200,"agentName":"ZCode"}
 ],
 "calls":1298,"errors":3,"retried":1,"canceled":2,"input":7139706,"output":640132,
 "cache_read":88757376,"cost":1.82788415,"series":[
   {"label":"00","calls":307,"by":{"agent":{"zcode":{"calls":10,"tokens":9}}}},
   {"label":"01","calls":5,"by":{"agent":{"zcode":{"calls":1}}}}],
 "by":{"agent":{"zcode":{"calls":95,"tokens":123}}},
 "agents":[{"id":"zcode","name":"ZCode","icon":"generic"}],
 "providers":[{"id":"workbuddy"}],"purposes":[{"id":"chat"}],"accounts":[],
 "speeds":[],"callerKeys":[],"through":{},"direct":{},"reported":{},"big_write":{}}
]]

local QUOTAS = [[
{"object":"quotas","data":[
 {"provider":"workbuddy","name":"WorkBuddy","kind":"subscription","plan":"Free plan",
  "user":"alice","windows":[
   {"name":"Credits","used":0,"remaining":100,"limit":500,"unit":"credits","display":"0 / 500"},
   {"name":"Extra credits","used":0,"remaining":9.5,"limit":5028,"unit":"credits"},
   {"name":"Total credits","used":7,"remaining":8.7,"limit":5528,"unit":"credits",
    "display":"5046 / 5528","resetsAt":"2026-11-30T15:59:59Z"},
   {"name":"deepseek tokens","used":1,"remaining":27.1,"limit":200000000,
    "display":"145.7M / 200M"}]}]}
]]

return {
    ["parseIso converts magpie timestamps to UTC epoch ms"] = function()
        same(magpie.parseIso("1970-01-01T00:00:00Z"), 0, "epoch")
        same(magpie.parseIso("2026-11-14T15:19:46.955+08:00"), 1794640786955, "offset")
        same(magpie.parseIso("2026-11-30T15:59:59Z"), 1796054399000, "zulu")
        same(magpie.parseIso("not a time"), nil, "rejects garbage")
        same(magpie.parseIso(nil), nil, "rejects nil")
    end,

    ["splitAccount and accountKey name the destination lane"] = function()
        local provider, user = magpie.splitAccount("workbuddy@alice")
        same(provider, "workbuddy", "provider")
        same(user, "alice", "user")
        provider, user = magpie.splitAccount("workbuddy")
        same(provider, "workbuddy", "bare provider")
        same(user, "workbuddy", "bare user")
        same(magpie.accountKey("workbuddy", "alice"), "workbuddy@alice", "key")
        same(magpie.accountKey("workbuddy", nil), nil, "unassigned account")
        same(magpie.accountKey("workbuddy", ""), nil, "empty account")
    end,

    ["parseRequests projects rows and period totals"] = function()
        local payload, err = magpie.parseRequests(REQUESTS)
        truthy(payload, err)
        same(payload.period, "today", "period")
        same(payload.calls, 1298, "calls")
        same(#payload.rows, 3, "row count")
        same(payload.total, 1298, "reported total")

        local first = payload.rows[1]
        same(first.agent, "zcode", "agent id")
        same(first.label, "ZCode", "agent display name")
        same(first.account, "workbuddy@alice", "account key")
        same(first.model, "deepseek-v4.1-flash", "served model")
        same(first.input, 382, "input tokens")
        same(first.output, 1571, "output tokens")
        same(first.tokens, 1953, "combined tokens")
        same(first.at, 1794644568916, "timestamp")
        same(first.status, 200, "status")
    end,

    ["parseRequests tolerates a row without an account"] = function()
        local payload = magpie.parseRequests(REQUESTS)
        local failed = payload.rows[2]
        same(failed.agent, "codebuddy", "still an agent")
        same(failed.account, nil, "no destination lane")
        same(failed.status, 0, "status")
    end,

    ["parseRequests drops the hourly series and the by breakdown"] = function()
        -- The rows endpoint repeats a large hourly series the board never
        -- draws; on a 30d window that alone pushes the parse past the VM quota.
        local payload = magpie.parseRequests(REQUESTS)
        same(payload.series, nil, "series dropped")
        same(#payload.rows, 3, "rows kept")
        near(payload.cost, 1.82788415, 1e-9, "cost")
        same(payload.cacheRead, 88757376, "cache reads")
    end,

    ["parseRequests reports malformed bodies"] = function()
        local payload = magpie.parseRequests("<html>nope</html>")
        same(payload, nil, "rejects non JSON")
    end,

    ["summarize ranks busiest agents and keeps display labels"] = function()
        local payload = magpie.parseRequests(REQUESTS)
        local agents = magpie.summarize(payload.rows)
        same(#agents, 2, "two agents")
        same(agents[1].key, "zcode", "busiest first")
        same(agents[1].label, "ZCode", "label")
        same(agents[1].count, 2, "request count")
        same(agents[1].tokens, 1953 + 150, "token sum")
        same(agents[2].key, "codebuddy", "second agent")
    end,

    ["summarizeAccounts groups by provider account"] = function()
        local payload = magpie.parseRequests(REQUESTS)
        local accounts = magpie.summarizeAccounts(payload.rows)
        same(#accounts, 1, "one account")
        same(accounts[1].key, "workbuddy@alice", "account key")
        same(accounts[1].label, "alice", "user label")
        same(accounts[1].provider, "workbuddy", "provider")
        same(accounts[1].count, 2, "request count")
    end,

    ["summarizePairs links agent and account"] = function()
        local payload = magpie.parseRequests(REQUESTS)
        local pairs = magpie.summarizePairs(payload.rows)
        same(#pairs, 1, "one link")
        same(pairs[1].agent, "zcode", "source")
        same(pairs[1].account, "workbuddy@alice", "destination")
        same(pairs[1].count, 2, "weight")
    end,

    ["newestFirst orders rows by timestamp"] = function()
        local payload = magpie.parseRequests(REQUESTS)
        local reordered = { payload.rows[3], payload.rows[1], payload.rows[2] }
        local sorted = magpie.newestFirst(reordered)
        same(sorted[1].id, "1794636618856", "newest first")
        same(sorted[3].id, "1794636618854", "oldest last")
    end,

    ["parseQuotas picks the widest budget window with a unit"] = function()
        local quotas, err = magpie.parseQuotas(QUOTAS)
        truthy(quotas, err)
        local quota = quotas["workbuddy@alice"]
        truthy(quota, "account keyed by provider@user")
        near(quota.remaining, 8.7, 0.001, "overall budget, not the model token window")
        same(quota.limit, 5528, "limit")
        same(quota.unit, "credits", "unit")
        same(quota.display, "5046 / 5528", "display text")
        same(quota.plan, "Free plan", "plan")
        same(quota.resetAt, 1796054399000, "renewal time")
    end,

    ["compact shortens large counters"] = function()
        same(magpie.compact(0), "0", "zero")
        same(magpie.compact(999), "999", "below one thousand")
        same(magpie.compact(1000), "1k", "one thousand")
        same(magpie.compact(1500), "1.5k", "one and a half thousand")
        same(magpie.compact(15000), "15k", "fifteen thousand")
        same(magpie.compact(8800000), "8.8M", "millions")
        same(magpie.compact(1234567), "1.23M", "two decimals")
        same(magpie.compact(nil), "0", "nil is zero")
    end,

    ["maskUser hides long names only"] = function()
        same(magpie.maskUser("amy"), "amy", "short names stay")
        same(magpie.maskUser("小明"), "小明", "short CJK name stays")
        same(magpie.maskUser("someone@example.com"), "so…", "long names are cut")
        same(magpie.maskUser(""), "", "empty name")
    end,

    ["shortAccount keeps real names and compacts machine ids"] = function()
        same(magpie.shortAccount("Acme-pu-0f0f0f0f-1111-2222-3333-444455556666"),
            "Acme·6666", "machine id keeps head and tail")
        same(magpie.shortAccount("Acme-pu-0f0f0f0f-9999"), "Acme·9999",
            "sibling account stays distinguishable")
        same(magpie.shortAccount(""), "", "empty name")
    end,
}
