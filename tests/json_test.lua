local json = module.require("modules/json.lua")

local function same(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label,
            tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(value, label)
    if not value then error(label, 2) end
end

return {
    ["decodes objects, arrays and scalars"] = function()
        local value = json.decode('{"a":1,"b":[true,false,null],"c":"x","d":{}}')
        same(value.a, 1, "a")
        same(value.b[1], true, "b1")
        same(value.b[2], false, "b2")
        truthy(json.isNull(value.b[3]), "null sentinel")
        same(value.c, "x", "c")
        same(#value.d, 0, "empty object")
    end,

    ["decodes numbers in every JSON shape"] = function()
        local value = json.decode("[-1, 2.5, 1e3, -2.5E-2, 0, 1024]")
        same(value[1], -1, "negative")
        same(value[2], 2.5, "decimal")
        same(value[3], 1000, "exponent")
        same(value[4], -0.025, "signed exponent")
        same(value[5], 0, "zero")
        same(value[6], 1024, "integer")
    end,

    ["decodes escapes, unicode and surrogate pairs"] = function()
        local value = json.decode('"line\\nbreak \\"quoted\\" tab\\t \\u4e2d\\u6587 \\ud83d\\ude00 end"')
        same(value, 'line\nbreak "quoted" tab\t 中文 😀 end', "escaped text")
    end,

    ["keeps raw UTF-8 bytes untouched"] = function()
        local value = json.decode('{"name":"alice"}')
        same(value.name, "alice", "utf8")
    end,

    ["tolerates whitespace and an empty array"] = function()
        local value = json.decode(' \n\t{ "a" : [ ] , "b" : 1 } \n ')
        same(#value.a, 0, "empty array")
        same(value.b, 1, "b")
    end,

    ["skip drops named subtrees at every depth"] = function()
        local payload = '{"keep":1,"order":[{"id":"a"},{"id":"b"}],' ..
            '"nested":{"order":[1,2],"ok":true},"prompt":{"parts":[{"x":1}]}}'
        local value = json.decode(payload, { skip = { order = true, prompt = true } })
        same(value.keep, 1, "keep")
        same(value.order, nil, "top level skip")
        same(value.prompt, nil, "top level prompt skip")
        same(value.nested.ok, true, "nested survivor")
        same(value.nested.order, nil, "nested skip")
    end,

    ["skip handles strings containing braces and quotes"] = function()
        local payload = '{"skipMe":{"text":"a\\"}]}b","list":[[1],[2]]},"keep":7}'
        local value = json.decode(payload, { skip = { skipMe = true } })
        same(value.keep, 7, "kept after tricky skip")
    end,

    ["rejects malformed documents"] = function()
        local value = json.decode('{"a":}')
        same(value, nil, "missing value")
        value = json.decode('{"a":1')
        same(value, nil, "unterminated object")
        value = json.decode('[1,2,]')
        same(value, nil, "trailing comma")
        value = json.decode("")
        same(value, nil, "empty input")
    end,

    ["projects a large skipped payload quickly"] = function()
        -- The shape and size of a real trace snapshot: magpie caps the
        -- response at 60 routes of roughly 8 KB. `order` is 57% of that and
        -- `prompt` another 22%, and the board reads neither.
        local candidate = '{"id":"workbuddy@some-account","provider":"workbuddy",' ..
            '"name":"WorkBuddy","icon":"workbuddy-color","who":"some-account",' ..
            '"kind":"account","agent":"workbuddy","plan":"Free plan",' ..
            '"model":"deepseek-v4.1-flash","routing":"order","shared":true,' ..
            '"known":true,"used":1.5927615550486616,"amount":104.73999986,' ..
            '"limit":6576,"unit":"credits","renews":["2026-11-30T15:59:59Z"],' ..
            '"soon":["2026-11-14T13:00:06Z"],"lapse":"2026-11-14T13:00:06Z",' ..
            '"pace":0.2554222118009678,"due":"2026-11-14T13:00:06Z",' ..
            '"dueBy":"expiry","held":true,"heldBy":"DeepSeek V4.1 Flash","rank":2}'
        local candidates = {}
        for index = 1, 15 do candidates[index] = candidate end
        local order = "[" .. table.concat(candidates, ",") .. "]"
        local parts = {}
        for index = 1, 6 do
            parts[index] = '{"kind":"system","tokens":21016,"items":[{"name":"prompt",' ..
                '"tokens":21016}]}'
        end
        local prompt = '{"window":1000000,"tokens":30729,"counted":true,"turns":1,' ..
            '"parts":[' .. table.concat(parts, ",") .. ']}'
        local routes = {}
        for index = 1, 60 do
            routes[index] = '{"seq":' .. index .. ',"id":' .. (1000 + index) ..
                ',"time":"2026-11-14T15:19:46.9550545+08:00","agent":"zcode",' ..
                '"provider":"workbuddy","done":true,"tokens":31088,"out":359,' ..
                '"order":' .. order .. ',"prompt":' .. prompt .. '}'
        end
        local payload = '{"seq":999,"routes":[' .. table.concat(routes, ",") .. ']}'
        truthy(#payload > 400 * 1024, "fixture is snapshot sized")

        local value = json.decode(payload, { skip = { order = true, prompt = true } })
        same(#value.routes, 60, "route count")
        same(value.routes[1].agent, "zcode", "agent survives")
        same(value.routes[60].order, nil, "orders dropped")
        same(value.routes[60].prompt, nil, "prompts dropped")
    end,
}
