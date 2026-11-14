-- modules/bird.lua - the magpie bird mark.
--
-- Source: the inline SVG inside magpie's own window
-- (https://github.com/yetone/magpie, <symbol id="bird">, 44 x 44, even-odd,
-- 176 cubics), MIT License, Copyright (c) 2026 yetone. This widget is an
-- unofficial companion and is not affiliated with that project.
--
-- The path is flattened and simplified to 91 points: plenty at the 24-42 px
-- this widget paints, and inside draw.path's budget of 256 commands.

local bird = {}

local SUBPATHS = {
    {1.50,5.50,1.17,7.25,1.54,8.85,3.03,11.11,8.20,17.30,2.80,11.40,0.70,9.60,0.56,11.21,1.12,13.08,2.22,14.44,8.30,19.70,4.99,17.01,0.66,14.13,0.90,16.30,2.81,18.41,6.14,20.46,8.02,22.07,10.50,25.80,13.07,23.76,10.20,26.90,7.73,30.96,11.91,29.71,9.70,30.73,8.92,31.66,12.55,32.64,18.65,37.03,23.54,38.54,26.49,38.50,31.45,36.68,33.40,35.20,35.61,32.83,37.99,28.55,39.00,24.17,38.90,21.40,36.90,16.11,37.02,14.08,37.70,13.15,38.85,12.45,43.37,11.48,43.10,11.03,40.69,10.00,38.18,9.50,36.39,8.09,34.40,7.13,32.25,6.82,29.83,7.36,28.23,8.29,27.05,9.48,24.38,14.27,22.94,16.06,17.00,20.50,16.00,20.90,14.20,20.20,12.23,18.41,10.70,16.30,8.12,10.89,6.33,8.53,3.38,6.13,1.50,5.50,},
    {28.40,16.70,29.66,17.32,29.99,18.42,29.60,19.40,27.88,21.03,23.83,22.82,14.90,25.11,16.58,22.60,20.92,18.78,25.34,16.92,28.40,16.70,},
    {30.40,20.20,31.69,22.54,33.05,23.95,34.69,24.95,37.79,26.02,36.92,29.44,34.70,33.30,32.72,35.11,30.43,36.54,26.25,37.89,22.13,37.68,18.59,36.15,16.45,33.88,16.22,32.99,16.51,32.00,24.50,27.60,26.00,26.40,28.47,23.63,29.48,22.02,30.12,20.11,30.40,20.20,},
}

local cache = { key = nil, commands = nil }

-- Commands are cached per size and position: the layout only changes when the
-- widget is resized, so a per-frame rebuild would be pure waste.
function bird.commands(size, x, y)
    local scale = size / 44
    local key = string.format("%.1f:%.1f:%.1f", size, x, y)
    if cache.key == key then return cache.commands end

    local commands, count = {}, 0
    for index = 1, #SUBPATHS do
        local flat = SUBPATHS[index]
        count = count + 1
        commands[count] = { op = "move", x = x + flat[1] * scale, y = y + flat[2] * scale }
        for point = 3, #flat, 2 do
            count = count + 1
            commands[count] = { op = "line",
                x = x + flat[point] * scale, y = y + flat[point + 1] * scale }
        end
        count = count + 1
        commands[count] = { op = "close" }
    end
    cache.key, cache.commands = key, commands
    return commands
end

function bird.draw(x, y, size, color, alpha)
    draw.path(bird.commands(size, x, y),
        { fillColor = color, fillRule = "alternate", alpha = alpha or 1 })
end

return bird
