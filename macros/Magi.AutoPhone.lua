script_name = "AutoPhone"
script_description = "Automates positioned phone chat signs with perspective-matched bubbles, customizable seamless balloon tails, usernames, read indicators, multi-line avatars, and optional auto-wrapping."
script_author = "Magi"
script_version = "0.5.0"
script_namespace = "Magi.AutoPhone"

local haveDepCtrl, DependencyControl, depRec = pcall(require, "l0.DependencyControl")
if haveDepCtrl then
    depRec = DependencyControl {
        feed = "https://raw.githubusercontent.com/Tenebris-Magi/Aegisub-Scripts/main/DependencyControl.json"
    }
end

include("karaskel.lua")

-- ============================================================================
-- Configuration Persistence (?user/phone_sign_automator.conf)
-- ============================================================================

local CONFIG_FILE = aegisub.decode_path("?user") .. "/phone_sign_automator.conf"

local DEFAULT_CONFIG = {
    left_text_color    = "#000000",
    left_box_color     = "#E5E5EA",
    right_text_color   = "#FFFFFF",
    right_box_color    = "#007AFF",
    padding            = 12,
    padding_y          = 12,
    spacing            = 14,
    clip_margin        = 10,
    corner_radius      = 0,

    -- Line breaks & Auto-wrap
    ignore_line_breaks = false,
    auto_wrap_enable   = false,
    max_width_pct      = 75,

    -- Username (Actor field)
    username_mode      = "Above",
    username_color     = "#555555",
    username_size_pct  = 75,

    -- Read indicator
    read_color         = "#888888",
    read_size_pct      = 65,

    -- Avatar
    avatar_size        = 48,
    avatar_gap         = 10,
    avatar_align       = "Top",

    -- Left balloon tail
    left_arrow_enable  = false,
    left_arrow_size    = 12,
    left_arrow_height  = 14,
    left_arrow_pos     = "Near Top",
    left_arrow_curve   = 50,
    left_arrow_dir     = "Bottom to Top",

    -- Right balloon tail
    right_arrow_enable = false,
    right_arrow_size   = 12,
    right_arrow_height = 14,
    right_arrow_pos    = "Near Top",
    right_arrow_curve  = 50,
    right_arrow_dir    = "Bottom to Top"
}

local function load_config()
    local cfg = {}
    for k, v in pairs(DEFAULT_CONFIG) do
        cfg[k] = v
    end

    local f = io.open(CONFIG_FILE, "r")
    if not f then
        return cfg
    end

    for line in f:lines() do
        local key, val = line:match("^([^=]+)=(.*)$")
        if key and val and DEFAULT_CONFIG[key] ~= nil then
            local def_type = type(DEFAULT_CONFIG[key])
            if def_type == "number" then
                cfg[key] = tonumber(val) or DEFAULT_CONFIG[key]
            elseif def_type == "boolean" then
                cfg[key] = (val == "true")
            else
                cfg[key] = val
            end
        end
    end
    f:close()
    return cfg
end

local function save_config(cfg)
    local f = io.open(CONFIG_FILE, "w")
    if not f then
        return
    end
    local nl = string.char(10)
    for k, _ in pairs(DEFAULT_CONFIG) do
        f:write(k .. "=" .. tostring(cfg[k]) .. nl)
    end
    f:close()
end

-- ============================================================================
-- Utility Helpers
-- ============================================================================

local function copy_table(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

local function fmt(n)
    if math.abs(n) < 0.005 then
        return "0"
    end
    local s = string.format("%.2f", n)
    s = s:gsub("(%..-)0+$", "%1"):gsub("%.$", "")
    if s == "-0" then s = "0" end
    return s
end

-- Convert Aegisub dialog HTML color (#RRGGBB) to ASS color (&HBBGGRR&)
local function html_to_ass_color(hex)
    local r, g, b = tostring(hex):match("#?(%x%x)(%x%x)(%x%x)")
    if not r then
        return "&HFFFFFF&"
    end
    return string.format("&H%s%s%s&", b:upper(), g:upper(), r:upper())
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_layout_res_y(sub, fallback_res_y)
    for i = 1, #sub do
        local l = sub[i]
        if l.class == "info" and l.key == "LayoutResY" then
            local v = tonumber(l.value)
            if v and v > 0 then
                return v
            end
        elseif l.class == "dialogue" then
            break
        end
    end
    return fallback_res_y
end

-- ============================================================================
-- ASS Tag, Effect, Read & Multi-Line Avatar Parsing
-- ============================================================================

local function extract_clip_points(text)
    local clip_content = text:match([=[\i?clip%(([^%)]+)%)]=])
    if not clip_content then
        return nil
    end

    local scale = 1
    local scale_str, rest = clip_content:match("^%s*(%d+)%s*,%s*(.+)$")
    if scale_str and rest then
        local s = tonumber(scale_str)
        if s and s > 1 then
            scale = 2 ^ (s - 1)
        end
        clip_content = rest
    end

    local draw_part = clip_content:match("[mM].*")
    if not draw_part then
        return nil
    end

    local nums = {}
    for num in draw_part:gmatch("[%-]?%d+%.?%d*") do
        table.insert(nums, tonumber(num) / scale)
    end

    local pts = {}
    for i = 1, #nums - 1, 2 do
        table.insert(pts, { x = nums[i], y = nums[i + 1] })
    end

    if #pts < 4 then
        return nil
    end
    return { pts[1], pts[2], pts[3], pts[4] }
end

local function extract_base_tags(text, style)
    local tags = ""
    for block in text:gmatch("{([^}]*)}") do
        tags = tags .. block
    end

    local function get_num(pattern, default_val)
        local m = tags:match(pattern)
        return m and tonumber(m) or default_val
    end

    local fscx = get_num([=[\fscx([%-]?%d+%.?%d*)]=], style.scale_x or 100)
    local fscy = get_num([=[\fscy([%-]?%d+%.?%d*)]=], style.scale_y or 100)
    local frx  = get_num([=[\frx([%-]?%d+%.?%d*)]=], 0)
    local fry  = get_num([=[\fry([%-]?%d+%.?%d*)]=], 0)
    local frz  = get_num([=[\frz([%-]?%d+%.?%d*)]=], nil)
    if frz == nil then
        frz = get_num([=[\fr([%-]?%d+%.?%d*)]=], style.angle or 0)
    end
    local fax  = get_num([=[\fax([%-]?%d+%.?%d*)]=], 0)

    local px, py = tags:match([=[\pos%(([%-%d%.]+)%s*,%s*([%-%d%.]+)%)]=])
    px = px and tonumber(px) or nil
    py = py and tonumber(py) or nil

    local ox, oy = tags:match([=[\org%(([%-%d%.]+)%s*,%s*([%-%d%.]+)%)]=])
    ox = ox and tonumber(ox) or nil
    oy = oy and tonumber(oy) or nil

    local an  = get_num([=[\an(%d)]=], style.align or 2)
    local fs  = get_num([=[\fs(%d+%.?%d*)]=], nil)
    local fsp = get_num([=[\fsp([%-]?%d+%.?%d*)]=], nil)
    local fn  = tags:match([=[\fn([^\}]+)]=])
    local b   = tags:match([=[\b(%d+)]=])
    local i   = tags:match([=[\i(%d+)]=])

    return {
        fscx = fscx,
        fscy = fscy,
        frx  = frx,
        fry  = fry,
        frz  = frz,
        fax  = fax,
        px   = px,
        py   = py,
        ox   = ox,
        oy   = oy,
        an   = an,
        fs   = fs,
        fsp  = fsp,
        fn   = fn,
        b    = b,
        i    = i
    }
end

local function anchor_y_to_top(py, an, block_h)
    local v_align = math.floor((an - 1) / 3)
    if v_align == 1 then
        return py - (block_h / 2)
    elseif v_align == 0 then
        return py - block_h
    end
    return py
end

local function parse_effect(eff_raw)
    local eff = trim(eff_raw):lower()
    local has_left, has_right, has_read, has_avatar = false, false, false, false

    for tok in eff:gmatch("[^%s,]+") do
        if tok == "left" or tok == "l" then
            has_left = true
        elseif tok == "right" or tok == "r" then
            has_right = true
        elseif tok == "read" then
            has_read = true
        elseif tok == "avatar" then
            has_avatar = true
        end
    end

    if has_read and (not has_left) and (not has_right) and (not has_avatar) then
        return { is_read_template = true }
    end

    if has_avatar and (not has_left) and (not has_right) and (not has_read) then
        return { is_avatar_template = true }
    end

    return {
        is_read_template   = false,
        is_avatar_template = false,
        is_right           = has_right,
        has_read           = has_read,
        has_avatar         = has_avatar
    }
end

local function parse_read_template(raw_text)
    local tags = ""
    for block in raw_text:gmatch("{([^}]*)}") do
        tags = tags .. block
    end

    local p_level = tonumber(tags:match([=[\p([1-9]%d*)]=]))
    local clean = trim(raw_text:gsub("{[^}]*}", ""))

    if p_level and clean ~= "" then
        local scale = 2 ^ (p_level - 1)
        local min_x, min_y = math.huge, math.huge
        local max_x, max_y = -math.huge, -math.huge

        local tokens = {}
        for tok in clean:gmatch("%S+") do
            table.insert(tokens, tok)
        end

        local is_x = true
        for _, tok in ipairs(tokens) do
            local num = tonumber(tok)
            if num then
                local v = num / scale
                if is_x then
                    if v < min_x then min_x = v end
                    if v > max_x then max_x = v end
                else
                    if v < min_y then min_y = v end
                    if v > max_y then max_y = v end
                end
                is_x = not is_x
            else
                is_x = true
            end
        end

        if min_x < math.huge and min_y < math.huge then
            local norm_tokens = {}
            is_x = true
            for _, tok in ipairs(tokens) do
                local num = tonumber(tok)
                if num then
                    local v = num / scale
                    if is_x then
                        table.insert(norm_tokens, fmt(v - min_x))
                    else
                        table.insert(norm_tokens, fmt(v - min_y))
                    end
                    is_x = not is_x
                else
                    table.insert(norm_tokens, tok)
                    is_x = true
                end
            end

            return {
                is_shape = true,
                drawing  = table.concat(norm_tokens, " "),
                width    = math.max(1, max_x - min_x),
                height   = math.max(1, max_y - min_y)
            }
        end
    end

    if clean == "" then
        return nil
    end

    return {
        is_shape = false,
        text     = clean
    }
end

local function extract_visual_tags(raw_text)
    local all_tags = ""
    for block in raw_text:gmatch("{([^}]*)}") do
        all_tags = all_tags .. block
    end

    local kept = {}
    local has_bord = false
    local has_shad = false

    for tag in all_tags:gmatch([=[\[^\]+]=]) do
        local is_layout =
            tag:match([=[^\an%d]=]) or
            tag:match([=[^\a%d]=]) or
            tag:match([=[^\pos%(]=]) or
            tag:match([=[^\move%(]=]) or
            tag:match([=[^\org%(]=]) or
            tag:match([=[^\fr[xyz]?[%-%d%.]]=]) or
            tag:match([=[^\fa[xy][%-%d%.]]=]) or
            tag:match([=[^\fsc[xy][%-%d%.]]=]) or
            tag:match([=[^\p%d]=]) or
            tag:match([=[^\i?clip%(]=])

        if not is_layout then
            table.insert(kept, tag)
            if tag:match([=[^\x?y?bord]=]) then has_bord = true end
            if tag:match([=[^\x?y?shad]=]) then has_shad = true end
        end
    end

    if not has_bord then table.insert(kept, [=[\bord0]=]) end
    if not has_shad then table.insert(kept, [=[\shad0]=]) end

    return table.concat(kept, "")
end

local function compile_avatar_group(raw_lines)
    if not raw_lines or #raw_lines == 0 then
        return nil
    end

    local parsed_parts = {}
    local ref_px, ref_py = nil, nil
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    local min_layer = math.huge

    for _, line in ipairs(raw_lines) do
        local tags = ""
        for block in line.text:gmatch("{([^}]*)}") do
            tags = tags .. block
        end

        local p_level = tonumber(tags:match([=[\p([1-9]%d*)]=]))
        local clean = trim(line.text:gsub("{[^}]*}", ""))

        if p_level and clean ~= "" then
            local scale_p = 2 ^ (p_level - 1)
            local fscx = tonumber(tags:match([=[\fscx([%-]?%d+%.?%d*)]=])) or 100
            local fscy = tonumber(tags:match([=[\fscy([%-]?%d+%.?%d*)]=])) or 100

            local px, py = tags:match([=[\pos%(([%-%d%.]+)%s*,%s*([%-%d%.]+)%)]=])
            px = px and tonumber(px) or nil
            py = py and tonumber(py) or nil

            if px and py and not ref_px then
                ref_px, ref_py = px, py
            end
            local off_x = (px and ref_px) and (px - ref_px) or 0
            local off_y = (py and ref_py) and (py - ref_py) or 0

            local tokens = {}
            local is_x = true
            for tok in clean:gmatch("%S+") do
                local num = tonumber(tok)
                if num then
                    if is_x then
                        local ux = (num / scale_p) * (fscx / 100.0) + off_x
                        if ux < min_x then min_x = ux end
                        if ux > max_x then max_x = ux end
                        table.insert(tokens, { is_num = true, is_x = true, val = ux })
                    else
                        local uy = (num / scale_p) * (fscy / 100.0) + off_y
                        if uy < min_y then min_y = uy end
                        if uy > max_y then max_y = uy end
                        table.insert(tokens, { is_num = true, is_x = false, val = uy })
                    end
                    is_x = not is_x
                else
                    table.insert(tokens, { is_num = false, text = tok })
                    is_x = true
                end
            end

            if line.layer < min_layer then
                min_layer = line.layer
            end

            table.insert(parsed_parts, {
                tokens      = tokens,
                layer       = line.layer,
                style       = line.style,
                visual_tags = extract_visual_tags(line.text)
            })
        end
    end

    if #parsed_parts == 0 or min_x == math.huge then
        return nil
    end

    local final_parts = {}
    for _, part in ipairs(parsed_parts) do
        local str_tokens = {}
        for _, t in ipairs(part.tokens) do
            if t.is_num then
                local shifted = t.is_x and (t.val - min_x) or (t.val - min_y)
                table.insert(str_tokens, fmt(shifted))
            else
                table.insert(str_tokens, t.text)
            end
        end

        table.insert(final_parts, {
            drawing      = table.concat(str_tokens, " "),
            layer_offset = part.layer - min_layer,
            style        = part.style,
            visual_tags  = part.visual_tags
        })
    end

    return {
        parts  = final_parts,
        width  = math.max(1, max_x - min_x),
        height = math.max(1, max_y - min_y)
    }
end

-- ============================================================================
-- Exact ASS / libass 3D Inverse Perspective Projection
-- ============================================================================

local function screen_to_local(xs, ys, ox, oy, frx, fry, frz, focal_d)
    local rx = math.rad(frx)
    local ry = math.rad(fry)
    local rz = math.rad(frz)

    local cx, sx = math.cos(rx), math.sin(rx)
    local cy, sy = math.cos(ry), math.sin(ry)
    local cz, sz = math.cos(rz), math.sin(rz)

    local u = xs - ox
    local v = ys - oy

    local nx = -sy
    local ny =  cy * sx
    local nz =  cy * cx

    local denom = nx * u + ny * v + nz * focal_d
    if math.abs(denom) < 1e-6 then
        return xs, ys
    end
    local t = (nz * focal_d) / denom

    local x3 = t * u
    local y3 = t * v
    local z3 = (t - 1) * focal_d

    local x2 = x3
    local y2 = y3 * cx - z3 * sx
    local z2 = y3 * sx + z3 * cx

    local x1 = x2 * cy + z2 * sy
    local y1 = y2

    local dx = x1 * cz - y1 * sz
    local dy = x1 * sz + y1 * cz

    return ox + dx, oy + dy
end

local function order_quad_corners(pts)
    local sorted = { pts[1], pts[2], pts[3], pts[4] }
    table.sort(sorted, function(a, b) return a.y < b.y end)

    local tl, tr = sorted[1], sorted[2]
    if tl.x > tr.x then tl, tr = tr, tl end

    local bl, br = sorted[3], sorted[4]
    if bl.x > br.x then bl, br = br, bl end

    return tl, tr, bl, br
end

local function edge_x_at_y(p1, p2, y)
    local dy = p2.y - p1.y
    if math.abs(dy) < 1e-4 then
        return (p1.x + p2.x) / 2
    end
    local t = (y - p1.y) / dy
    return p1.x + t * (p2.x - p1.x)
end

-- ============================================================================
-- Text Formatting & Measurement (Ignore Breaks + Optional Auto-Wrap)
-- ============================================================================

local function format_and_measure_text(clean_text, measure_style, ignore_breaks, max_text_w)
    local working = clean_text:gsub([=[\n]=], [=[\N]=])

    if ignore_breaks then
        working = trim(working:gsub([=[\N]=], " "):gsub("%s+", " "))
    end

    local paragraphs = {}
    local start_idx = 1
    while true do
        local s, e = working:find([=[\N]=], start_idx, true)
        if not s then
            table.insert(paragraphs, working:sub(start_idx))
            break
        end
        table.insert(paragraphs, working:sub(start_idx, s - 1))
        start_idx = e + 1
    end

    local final_lines = {}
    if max_text_w and max_text_w > 0 then
        for _, para in ipairs(paragraphs) do
            local pw = aegisub.text_extents(measure_style, para)
            if pw <= max_text_w or para == "" then
                table.insert(final_lines, para)
            else
                local current = ""
                for word in para:gmatch("%S+") do
                    local candidate = (current == "") and word or (current .. " " .. word)
                    local cw = aegisub.text_extents(measure_style, candidate)
                    if cw <= max_text_w or current == "" then
                        current = candidate
                    else
                        table.insert(final_lines, current)
                        current = word
                    end
                end
                if current ~= "" then
                    table.insert(final_lines, current)
                end
            end
        end
    else
        final_lines = paragraphs
    end

    local _, base_line_h = aegisub.text_extents(measure_style, "Ay")
    local max_w = 0
    for _, l in ipairs(final_lines) do
        local lw = aegisub.text_extents(measure_style, l)
        if lw > max_w then
            max_w = lw
        end
    end

    local total_h = #final_lines * base_line_h
    return table.concat(final_lines, [=[\N]=]), max_w, total_h, base_line_h
end

-- ============================================================================
-- Single-Contour Seamless Bubble + Customizable Balloon Tail Drawing (\p1)
-- ============================================================================

local function build_box_drawing(w, h, radius, is_right, tail_enable, tail_w, tail_h, tail_pos, tail_curve_pct, tail_dir)
    local has_tail = tail_enable and (tail_w or 0) > 0 and (tail_h or 0) > 0
    local s  = has_tail and tail_w or 0
    local th = has_tail and tail_h or 0
    local c  = math.max(0, math.min(100, tail_curve_pct or 0)) / 100.0
    local sweep_up = (tail_dir ~= "Top to Bottom")
    local r = math.max(0, math.min(radius or 0, w / 2, h / 2))

    local is_side_pos = (tail_pos == "Near Top" or tail_pos == "Middle" or tail_pos == "Near Bottom")
    local is_tl = has_tail and (not is_right) and (tail_pos == "Top")
    local is_bl = has_tail and (not is_right) and (tail_pos == "Bottom")
    local is_sl = has_tail and (not is_right) and is_side_pos
    local is_tr = has_tail and is_right and (tail_pos == "Top")
    local is_br = has_tail and is_right and (tail_pos == "Bottom")
    local is_sr = has_tail and is_right and is_side_pos

    local cmds = {}
    local function add(str) table.insert(cmds, str) end

    local function add_arc(cx, cy, rad, a1, a2)
        if rad < 0.5 or math.abs(a2 - a1) < 1e-4 then
            return
        end
        local d  = rad * (4.0 / 3.0) * math.tan((a2 - a1) / 4.0)
        local x1 = cx + rad * math.cos(a1)
        local y1 = cy + rad * math.sin(a1)
        local x2 = cx + rad * math.cos(a2)
        local y2 = cy + rad * math.sin(a2)
        local c1x = x1 - d * math.sin(a1)
        local c1y = y1 + d * math.cos(a1)
        local c2x = x2 + d * math.sin(a2)
        local c2y = y2 - d * math.cos(a2)
        add(string.format("b %s %s %s %s %s %s", fmt(c1x), fmt(c1y), fmt(c2x), fmt(c2y), fmt(x2), fmt(y2)))
    end

    local function clamp_unit(v)
        return math.max(-1, math.min(1, v))
    end

    local function right_boundary_at(y)
        if r >= 0.5 and y < r then
            local a = math.asin(clamp_unit((y - r) / r))
            return (w - r) + r * math.cos(a), a
        elseif r >= 0.5 and y > h - r then
            local a = math.asin(clamp_unit((y - (h - r)) / r))
            return (w - r) + r * math.cos(a), a
        end
        return w, nil
    end

    local function left_boundary_at(y)
        if r >= 0.5 and y > h - r then
            local a = math.pi - math.asin(clamp_unit((y - (h - r)) / r))
            return r + r * math.cos(a), a
        elseif r >= 0.5 and y < r then
            local a = math.pi - math.asin(clamp_unit((y - r) / r))
            return r + r * math.cos(a), a
        end
        return 0, nil
    end

    local function side_tail_span()
        local max_h     = math.max(1, h - 1)
        local base_h    = math.min(max_h, math.max(1, th))
        local max_inset = math.max(0, (h - base_h) / 2 - 0.5)
        local inset     = math.min(max_inset, math.max(3, math.min(10, h * 0.12)))

        local top_y
        if tail_pos == "Near Top" then
            top_y = inset
        elseif tail_pos == "Near Bottom" then
            top_y = h - inset - base_h
        else
            top_y = (h - base_h) / 2
        end
        top_y = math.max(0.5, math.min(top_y, h - base_h - 0.5))
        return top_y, top_y + base_h, base_h
    end

    local HALF_PI = math.pi / 2
    local ax = math.min(w * 0.5, math.max(r, s * 0.9))
    local ay = math.min(math.max(1, h - r), math.max(1, th))

    local top_start_x = is_tl and ax or r
    add(string.format("m %s 0", fmt(top_start_x)))

    -- ========================================================================
    -- RIGHT HALF
    -- ========================================================================
    if is_sr then
        local top_y, bot_y, base_h = side_tail_span()
        local mid_y = (top_y + bot_y) / 2
        local x_top, a_top = right_boundary_at(top_y)
        local x_bot, a_bot = right_boundary_at(bot_y)

        add(string.format("l %s 0", fmt(w - r)))

        if r >= 0.5 and top_y < r then
            add_arc(w - r, r, r, -HALF_PI, a_top)
        elseif r >= 0.5 and top_y > h - r then
            add_arc(w - r, r, r, -HALF_PI, 0)
            add(string.format("l %s %s", fmt(w), fmt(h - r)))
            add_arc(w - r, h - r, r, 0, a_top)
        else
            add_arc(w - r, r, r, -HALF_PI, 0)
            add(string.format("l %s %s", fmt(w), fmt(top_y)))
        end

        local x_tip = w + s
        local dx_t  = x_tip - x_top
        local dx_b  = x_tip - x_bot
        if c < 0.01 then
            add(string.format("l %s %s %s %s", fmt(x_tip), fmt(mid_y), fmt(x_bot), fmt(bot_y)))
        elseif sweep_up then
            local tip_y = mid_y - base_h * 0.55 * c
            add(string.format(
                "b %s %s %s %s %s %s b %s %s %s %s %s %s",
                fmt(x_top + dx_t * (0.20 + 0.15 * c)), fmt(top_y + base_h * 0.18 * c),
                fmt(x_top + dx_t * (0.55 + 0.15 * c)), fmt(tip_y + base_h * 0.18 * c),
                fmt(x_tip), fmt(tip_y),
                fmt(x_bot + dx_b * (0.70 + 0.20 * c)), fmt(tip_y + (bot_y - tip_y) * (0.45 + 0.25 * c)),
                fmt(x_bot + dx_b * (0.30 + 0.35 * c)), fmt(bot_y - base_h * 0.05 * c),
                fmt(x_bot), fmt(bot_y)
            ))
        else
            local tip_y = mid_y + base_h * 0.55 * c
            add(string.format(
                "b %s %s %s %s %s %s b %s %s %s %s %s %s",
                fmt(x_top + dx_t * (0.30 + 0.35 * c)), fmt(top_y + base_h * 0.05 * c),
                fmt(x_top + dx_t * (0.70 + 0.20 * c)), fmt(tip_y - (tip_y - top_y) * (0.45 + 0.25 * c)),
                fmt(x_tip), fmt(tip_y),
                fmt(x_bot + dx_b * (0.55 + 0.15 * c)), fmt(tip_y - base_h * 0.18 * c),
                fmt(x_bot + dx_b * (0.20 + 0.15 * c)), fmt(bot_y - base_h * 0.18 * c),
                fmt(x_bot), fmt(bot_y)
            ))
        end

        if r >= 0.5 and bot_y < r then
            add_arc(w - r, r, r, a_bot, 0)
            add(string.format("l %s %s", fmt(w), fmt(h - r)))
            add_arc(w - r, h - r, r, 0, HALF_PI)
        elseif r >= 0.5 and bot_y > h - r then
            add_arc(w - r, h - r, r, a_bot, HALF_PI)
        else
            add(string.format("l %s %s", fmt(w), fmt(h - r)))
            add_arc(w - r, h - r, r, 0, HALF_PI)
        end
    else
        if is_tr then
            local tr_x = math.max(top_start_x, w - ax)
            local tr_y = ay
            add(string.format("l %s 0", fmt(tr_x)))
            if c < 0.01 then
                add(string.format("l %s 0 %s %s", fmt(w + s), fmt(w), fmt(tr_y)))
            elseif sweep_up then
                add(string.format(
                    "b %s %s %s %s %s 0 b %s %s %s %s %s %s",
                    fmt(w - (w - tr_x) * 0.25), fmt(s * 0.14 * c),
                    fmt(w + s * (0.35 + 0.15 * c)), fmt(s * 0.18 * c),
                    fmt(w + s),
                    fmt(w + s * (0.35 + 0.45 * c)), fmt(tr_y * (0.35 - 0.25 * c)),
                    fmt(w + s * 0.15 * c), fmt(tr_y * (1 - 0.55 * c)),
                    fmt(w), fmt(tr_y)
                ))
            else
                local tip_y = tr_y * 0.35 * c
                add(string.format(
                    "b %s 0 %s %s %s %s b %s %s %s %s %s %s",
                    fmt(w - (w - tr_x) * 0.20),
                    fmt(w + s * (0.45 + 0.25 * c)), fmt(tip_y * (1 - 0.65 * c)),
                    fmt(w + s), fmt(tip_y),
                    fmt(w + s * (0.55 + 0.15 * c)), fmt(tip_y + (tr_y - tip_y) * 0.15),
                    fmt(w + s * (0.20 + 0.15 * c)), fmt(tr_y - (tr_y - tip_y) * 0.30),
                    fmt(w), fmt(tr_y)
                ))
            end
        else
            add(string.format("l %s 0", fmt(w - r)))
            add_arc(w - r, r, r, -HALF_PI, 0)
        end

        if is_br then
            local br_y = h - ay
            local br_x = math.max(r, w - ax)
            local dy = h - br_y
            add(string.format("l %s %s", fmt(w), fmt(br_y)))
            if c < 0.01 then
                add(string.format("l %s %s %s %s", fmt(w + s), fmt(h), fmt(br_x), fmt(h)))
            elseif not sweep_up then
                add(string.format(
                    "b %s %s %s %s %s %s b %s %s %s %s %s %s",
                    fmt(w + s * 0.15 * c), fmt(br_y + dy * 0.55 * c),
                    fmt(w + s * (0.35 + 0.45 * c)), fmt(h - dy * (0.35 - 0.25 * c)),
                    fmt(w + s), fmt(h),
                    fmt(w + s * (0.35 + 0.15 * c)), fmt(h - s * 0.18 * c),
                    fmt(w - (w - br_x) * 0.25), fmt(h - s * 0.14 * c),
                    fmt(br_x), fmt(h)
                ))
            else
                local tip_y = h - dy * 0.35 * c
                add(string.format(
                    "b %s %s %s %s %s %s b %s %s %s %s %s %s",
                    fmt(w + s * (0.20 + 0.15 * c)), fmt(br_y + (tip_y - br_y) * 0.30),
                    fmt(w + s * (0.55 + 0.15 * c)), fmt(tip_y - (tip_y - br_y) * 0.15),
                    fmt(w + s), fmt(tip_y),
                    fmt(w + s * (0.45 + 0.25 * c)), fmt(h - (h - tip_y) * (1 - 0.65 * c)),
                    fmt(w - (w - br_x) * 0.20), fmt(h),
                    fmt(br_x), fmt(h)
                ))
            end
        else
            add(string.format("l %s %s", fmt(w), fmt(h - r)))
            add_arc(w - r, h - r, r, 0, HALF_PI)
        end
    end

    -- ========================================================================
    -- LEFT HALF
    -- ========================================================================
    if is_sl then
        local top_y, bot_y, base_h = side_tail_span()
        local mid_y = (top_y + bot_y) / 2
        local x_top, a_top = left_boundary_at(top_y)
        local x_bot, a_bot = left_boundary_at(bot_y)

        add(string.format("l %s %s", fmt(r), fmt(h)))

        if r >= 0.5 and bot_y > h - r then
            add_arc(r, h - r, r, HALF_PI, a_bot)
        elseif r >= 0.5 and bot_y < r then
            add_arc(r, h - r, r, HALF_PI, math.pi)
            add(string.format("l 0 %s", fmt(r)))
            add_arc(r, r, r, math.pi, a_bot)
        else
            add_arc(r, h - r, r, HALF_PI, math.pi)
            add(string.format("l 0 %s", fmt(bot_y)))
        end

        local x_tip = -s
        local dx_b  = x_bot - x_tip
        local dx_t  = x_top - x_tip
        if c < 0.01 then
            add(string.format("l %s %s %s %s", fmt(x_tip), fmt(mid_y), fmt(x_top), fmt(top_y)))
        elseif sweep_up then
            local tip_y = mid_y - base_h * 0.55 * c
            add(string.format(
                "b %s %s %s %s %s %s b %s %s %s %s %s %s",
                fmt(x_bot - dx_b * (0.30 + 0.35 * c)), fmt(bot_y - base_h * 0.05 * c),
                fmt(x_bot - dx_b * (0.70 + 0.20 * c)), fmt(tip_y + (bot_y - tip_y) * (0.45 + 0.25 * c)),
                fmt(x_tip), fmt(tip_y),
                fmt(x_top - dx_t * (0.55 + 0.15 * c)), fmt(tip_y + base_h * 0.18 * c),
                fmt(x_top - dx_t * (0.20 + 0.15 * c)), fmt(top_y + base_h * 0.18 * c),
                fmt(x_top), fmt(top_y)
            ))
        else
            local tip_y = mid_y + base_h * 0.55 * c
            add(string.format(
                "b %s %s %s %s %s %s b %s %s %s %s %s %s",
                fmt(x_bot - dx_b * (0.20 + 0.15 * c)), fmt(bot_y - base_h * 0.18 * c),
                fmt(x_bot - dx_b * (0.55 + 0.15 * c)), fmt(tip_y - base_h * 0.18 * c),
                fmt(x_tip), fmt(tip_y),
                fmt(x_top - dx_t * (0.70 + 0.20 * c)), fmt(tip_y - (tip_y - top_y) * (0.45 + 0.25 * c)),
                fmt(x_top - dx_t * (0.30 + 0.35 * c)), fmt(top_y + base_h * 0.05 * c),
                fmt(x_top), fmt(top_y)
            ))
        end

        if r >= 0.5 and top_y > h - r then
            add_arc(r, h - r, r, a_top, math.pi)
            add(string.format("l 0 %s", fmt(r)))
            add_arc(r, r, r, math.pi, 3 * HALF_PI)
        elseif r >= 0.5 and top_y < r then
            add_arc(r, r, r, a_top, 3 * HALF_PI)
        else
            add(string.format("l 0 %s", fmt(r)))
            add_arc(r, r, r, math.pi, 3 * HALF_PI)
        end
    else
        if is_bl then
            local bl_x = math.min(w - r, ax)
            local bl_y = h - ay
            local dy = h - bl_y
            add(string.format("l %s %s", fmt(bl_x), fmt(h)))
            if c < 0.01 then
                add(string.format("l %s %s 0 %s", fmt(-s), fmt(h), fmt(bl_y)))
            elseif not sweep_up then
                add(string.format(
                    "b %s %s %s %s %s %s b %s %s %s %s 0 %s",
                    fmt(bl_x * 0.25), fmt(h - s * 0.14 * c),
                    fmt(-s * (0.35 + 0.15 * c)), fmt(h - s * 0.18 * c),
                    fmt(-s), fmt(h),
                    fmt(-s * (0.35 + 0.45 * c)), fmt(h - dy * (0.35 - 0.25 * c)),
                    fmt(-s * 0.15 * c), fmt(bl_y + dy * 0.55 * c),
                    fmt(bl_y)
                ))
            else
                local tip_y = h - dy * 0.35 * c
                add(string.format(
                    "b %s %s %s %s %s %s b %s %s %s %s 0 %s",
                    fmt(bl_x * 0.20), fmt(h),
                    fmt(-s * (0.45 + 0.25 * c)), fmt(h - (h - tip_y) * (1 - 0.65 * c)),
                    fmt(-s), fmt(tip_y),
                    fmt(-s * (0.55 + 0.15 * c)), fmt(tip_y - (tip_y - bl_y) * 0.15),
                    fmt(-s * (0.20 + 0.15 * c)), fmt(bl_y + (tip_y - bl_y) * 0.30),
                    fmt(bl_y)
                ))
            end
        else
            add(string.format("l %s %s", fmt(r), fmt(h)))
            add_arc(r, h - r, r, HALF_PI, math.pi)
        end

        if is_tl then
            local tl_y = ay
            add(string.format("l 0 %s", fmt(tl_y)))
            if c < 0.01 then
                add(string.format("l %s 0 %s 0", fmt(-s), fmt(top_start_x)))
            elseif sweep_up then
                add(string.format(
                    "b %s %s %s %s %s 0 b %s %s %s %s %s 0",
                    fmt(-s * 0.15 * c), fmt(tl_y * (1 - 0.55 * c)),
                    fmt(-s * (0.35 + 0.45 * c)), fmt(tl_y * (0.35 - 0.25 * c)),
                    fmt(-s),
                    fmt(-s * (0.35 + 0.15 * c)), fmt(s * 0.18 * c),
                    fmt(top_start_x * 0.25), fmt(s * 0.14 * c),
                    fmt(top_start_x)
                ))
            else
                local tip_y = tl_y * 0.35 * c
                add(string.format(
                    "b %s %s %s %s %s %s b %s %s %s 0 %s 0",
                    fmt(-s * (0.20 + 0.15 * c)), fmt(tl_y - (tl_y - tip_y) * 0.30),
                    fmt(-s * (0.55 + 0.15 * c)), fmt(tip_y + (tl_y - tip_y) * 0.15),
                    fmt(-s), fmt(tip_y),
                    fmt(-s * (0.45 + 0.25 * c)), fmt(tip_y * (1 - 0.65 * c)),
                    fmt(top_start_x * 0.20),
                    fmt(top_start_x)
                ))
            end
        else
            add(string.format("l 0 %s", fmt(r)))
            add_arc(r, r, r, math.pi, 3 * HALF_PI)
        end
    end

    return table.concat(cmds, " ")
end

-- ============================================================================
-- GUI Dialog
-- ============================================================================

local function show_dialog(cfg)
    local tail_pos_items   = { "Top", "Near Top", "Middle", "Near Bottom", "Bottom" }
    local tail_dir_items   = { "Bottom to Top", "Top to Bottom" }
    local avatar_aln_items = { "Top", "Middle", "Bottom" }

    local dialog_config = {
        -- Colors & Layout
        { class = "label", label = "Left Text Color:",  x = 0, y = 0, width = 1, height = 1 },
        { class = "color", name  = "left_text_color",   value = cfg.left_text_color,  x = 1, y = 0, width = 1, height = 1 },
        { class = "label", label = "Left Box Color:",   x = 2, y = 0, width = 1, height = 1 },
        { class = "color", name  = "left_box_color",    value = cfg.left_box_color,   x = 3, y = 0, width = 1, height = 1 },

        { class = "label", label = "Right Text Color:", x = 0, y = 1, width = 1, height = 1 },
        { class = "color", name  = "right_text_color",  value = cfg.right_text_color, x = 1, y = 1, width = 1, height = 1 },
        { class = "label", label = "Right Box Color:",  x = 2, y = 1, width = 1, height = 1 },
        { class = "color", name  = "right_box_color",   value = cfg.right_box_color,  x = 3, y = 1, width = 1, height = 1 },

        { class = "label",     label = "Box Pad X (px):",     x = 0, y = 2, width = 1, height = 1 },
        { class = "floatedit", name  = "padding",             value = cfg.padding, min = 0, max = 200, x = 1, y = 2, width = 1, height = 1 },
        { class = "label",     label = "Box Pad Y (px):",     x = 2, y = 2, width = 1, height = 1 },
        { class = "floatedit", name  = "padding_y",           value = cfg.padding_y, min = 0, max = 200, x = 3, y = 2, width = 1, height = 1 },

        { class = "label",     label = "Line Spacing (px):",  x = 0, y = 3, width = 1, height = 1 },
        { class = "floatedit", name  = "spacing",             value = cfg.spacing, min = 0, max = 500, x = 1, y = 3, width = 1, height = 1 },
        { class = "label",     label = "Clip Margin (px):",   x = 2, y = 3, width = 1, height = 1 },
        { class = "floatedit", name  = "clip_margin",         value = cfg.clip_margin, min = 0, max = 500, x = 3, y = 3, width = 1, height = 1 },

        { class = "label",     label = "Corner Radius (px):", x = 0, y = 4, width = 1, height = 1 },
        { class = "intedit",   name  = "corner_radius",       value = cfg.corner_radius, min = 0, max = 100, x = 1, y = 4, width = 1, height = 1 },

        -- Line Breaks & Auto-Wrap
        { class = "label",    label = "─── Line Breaks & Wrapping ───", x = 0, y = 5, width = 4, height = 1 },
        { class = "checkbox", name  = "ignore_line_breaks", label = "Ignore line breaks", value = cfg.ignore_line_breaks, x = 0, y = 6, width = 2, height = 1 },
        { class = "checkbox", name  = "auto_wrap_enable",   label = "Auto-wrap > Clip %", value = cfg.auto_wrap_enable,   x = 2, y = 6, width = 1, height = 1 },
        { class = "intedit",  name  = "max_width_pct",      value = cfg.max_width_pct, min = 15, max = 100, x = 3, y = 6, width = 1, height = 1 },

        -- Username (Actor Field)
        { class = "label",    label = "─── Username (Actor Field) ───", x = 0, y = 7, width = 4, height = 1 },
        { class = "label",    label = "Position:",        x = 0, y = 8, width = 1, height = 1 },
        { class = "dropdown", name  = "username_mode",    items = { "Off", "Above", "Next to" }, value = cfg.username_mode, x = 1, y = 8, width = 1, height = 1 },
        { class = "label",    label = "Username Color:",  x = 2, y = 8, width = 1, height = 1 },
        { class = "color",    name  = "username_color",   value = cfg.username_color, x = 3, y = 8, width = 1, height = 1 },
        { class = "label",    label = "Size (% of text):", x = 0, y = 9, width = 1, height = 1 },
        { class = "intedit",  name  = "username_size_pct", value = cfg.username_size_pct, min = 10, max = 200, x = 1, y = 9, width = 1, height = 1 },

        -- Read Indicator & Avatar
        { class = "label",     label = "─── Read & Avatar (Effect: Read / Avatar) ───", x = 0, y = 10, width = 4, height = 1 },
        { class = "label",     label = "Read Color:",       x = 0, y = 11, width = 1, height = 1 },
        { class = "color",     name  = "read_color",        value = cfg.read_color, x = 1, y = 11, width = 1, height = 1 },
        { class = "label",     label = "Read Size (%):",    x = 2, y = 11, width = 1, height = 1 },
        { class = "intedit",   name  = "read_size_pct",     value = cfg.read_size_pct, min = 10, max = 300, x = 3, y = 11, width = 1, height = 1 },

        { class = "label",     label = "Avatar Size (px):", x = 0, y = 12, width = 1, height = 1 },
        { class = "floatedit", name  = "avatar_size",       value = cfg.avatar_size, min = 8, max = 300, x = 1, y = 12, width = 1, height = 1 },
        { class = "label",     label = "Avatar Gap (px):",  x = 2, y = 12, width = 1, height = 1 },
        { class = "floatedit", name  = "avatar_gap",        value = cfg.avatar_gap, min = 0, max = 200, x = 3, y = 12, width = 1, height = 1 },

        { class = "label",     label = "Avatar Align:",     x = 0, y = 13, width = 1, height = 1 },
        { class = "dropdown",  name  = "avatar_align",      items = avatar_aln_items, value = cfg.avatar_align, x = 1, y = 13, width = 1, height = 1 },

        -- Balloon Tails
        { class = "label",     label = "─── Balloon Tails ───", x = 0, y = 14, width = 4, height = 1 },

        { class = "checkbox",  name  = "left_arrow_enable",  label = "Left Tail",          value = cfg.left_arrow_enable, x = 0, y = 15, width = 1, height = 1 },
        { class = "dropdown",  name  = "left_arrow_pos",     items = tail_pos_items,       value = cfg.left_arrow_pos, x = 1, y = 15, width = 1, height = 1 },
        { class = "label",     label = "Left Curve (%):",    x = 2, y = 15, width = 1, height = 1 },
        { class = "intedit",   name  = "left_arrow_curve",   value = cfg.left_arrow_curve, min = 0, max = 100, x = 3, y = 15, width = 1, height = 1 },

        { class = "label",     label = "Left Width (px):",   x = 0, y = 16, width = 1, height = 1 },
        { class = "floatedit", name  = "left_arrow_size",    value = cfg.left_arrow_size,  min = 1, max = 200, x = 1, y = 16, width = 1, height = 1 },
        { class = "label",     label = "Left Height (px):",  x = 2, y = 16, width = 1, height = 1 },
        { class = "floatedit", name  = "left_arrow_height",  value = cfg.left_arrow_height, min = 1, max = 200, x = 3, y = 16, width = 1, height = 1 },

        { class = "label",     label = "Left Curve Dir:",    x = 0, y = 17, width = 1, height = 1 },
        { class = "dropdown",  name  = "left_arrow_dir",     items = tail_dir_items,       value = cfg.left_arrow_dir, x = 1, y = 17, width = 3, height = 1 },

        { class = "checkbox",  name  = "right_arrow_enable", label = "Right Tail",         value = cfg.right_arrow_enable, x = 0, y = 18, width = 1, height = 1 },
        { class = "dropdown",  name  = "right_arrow_pos",    items = tail_pos_items,       value = cfg.right_arrow_pos, x = 1, y = 18, width = 1, height = 1 },
        { class = "label",     label = "Right Curve (%):",   x = 2, y = 18, width = 1, height = 1 },
        { class = "intedit",   name  = "right_arrow_curve",  value = cfg.right_arrow_curve, min = 0, max = 100, x = 3, y = 18, width = 1, height = 1 },

        { class = "label",     label = "Right Width (px):",  x = 0, y = 19, width = 1, height = 1 },
        { class = "floatedit", name  = "right_arrow_size",   value = cfg.right_arrow_size,  min = 1, max = 200, x = 1, y = 19, width = 1, height = 1 },
        { class = "label",     label = "Right Height (px):", x = 2, y = 19, width = 1, height = 1 },
        { class = "floatedit", name  = "right_arrow_height", value = cfg.right_arrow_height, min = 1, max = 200, x = 3, y = 19, width = 1, height = 1 },

        { class = "label",     label = "Right Curve Dir:",   x = 0, y = 20, width = 1, height = 1 },
        { class = "dropdown",  name  = "right_arrow_dir",    items = tail_dir_items,       value = cfg.right_arrow_dir, x = 1, y = 20, width = 3, height = 1 }
    }

    local btn, res = aegisub.dialog.display(dialog_config, { "Apply", "Cancel" })
    if btn ~= "Apply" then
        return nil
    end
    return res
end

-- ============================================================================
-- Main Macro Entry Point
-- ============================================================================

local function run_phone_sign(sub, sel)
    if #sel < 1 then
        aegisub.dialog.display(
            {{ class = "label", label = [=[Please select at least one line (Line 1 must contain the base tags and 4-point \clip).]=] }},
            { "OK" }
        )
        return sel
    end

    local meta, styles = karaskel.collect_head(sub, false)
    local res_y        = meta.res_y or 1080
    local layout_res_y = get_layout_res_y(sub, res_y)
    local focal_d      = 312.5 * (res_y / layout_res_y)

    -- 1. Inspect Line 1 (Template + Clip)
    local first_line = sub[sel[1]]
    local base_style = styles[first_line.style] or styles["Default"]
    if not base_style then
        for _, st in pairs(styles) do
            base_style = st
            break
        end
    end

    local clip_pts = extract_clip_points(first_line.text)
    if not clip_pts then
        aegisub.dialog.display(
            {{ class = "label", label = [=[Error: The first selected line must contain a 4-point vectorial \clip(m x1 y1 l x2 y2 x3 y3 x4 y4).]=] }},
            { "OK" }
        )
        return sel
    end

    -- 2. Scan selected lines for "Read" and "Avatar" template lines
    local read_template = nil
    local default_avatar_raw = {}
    local actor_avatars_raw  = {}
    local first_actor_key    = nil

    for _, line_num in ipairs(sel) do
        local line = sub[line_num]
        local info = parse_effect(line.effect)
        if info.is_read_template and not read_template then
            read_template = parse_read_template(line.text)
        elseif info.is_avatar_template then
            local akey = trim(line.actor):lower()
            if akey == "" then
                table.insert(default_avatar_raw, line)
            else
                if not actor_avatars_raw[akey] then
                    actor_avatars_raw[akey] = {}
                    if not first_actor_key then first_actor_key = akey end
                end
                table.insert(actor_avatars_raw[akey], line)
            end
        end
    end

    -- Default Read fallback if no "Read" template line is selected
    if not read_template then
        read_template = {
            is_shape = false,
            text     = "Read"
        }
    end

    -- Compile multi-line avatars
    local default_avatar = compile_avatar_group(default_avatar_raw)
    local actor_avatars  = {}
    for akey, raw_list in pairs(actor_avatars_raw) do
        actor_avatars[akey] = compile_avatar_group(raw_list)
    end
    local fallback_avatar = default_avatar or (first_actor_key and actor_avatars[first_actor_key] or nil)

    local function resolve_avatar(actor_str)
        local akey = trim(actor_str):lower()
        if akey ~= "" and actor_avatars[akey] then
            return actor_avatars[akey]
        end
        return fallback_avatar
    end

    -- 3. Show GUI with remembered settings
    local cfg = load_config()
    local res = show_dialog(cfg)
    if not res then
        return sel
    end
    save_config(res)

    local pad_x         = res.padding
    local pad_y         = res.padding_y
    local spacing       = res.spacing
    local clip_margin   = res.clip_margin
    local corner_radius = res.corner_radius
    local avatar_target = res.avatar_size
    local avatar_gap    = res.avatar_gap

    local left_txt_ass  = html_to_ass_color(res.left_text_color)
    local left_box_ass  = html_to_ass_color(res.left_box_color)
    local right_txt_ass = html_to_ass_color(res.right_text_color)
    local right_box_ass = html_to_ass_color(res.right_box_color)
    local uname_ass     = html_to_ass_color(res.username_color)
    local read_ass      = html_to_ass_color(res.read_color)

    local uname_scale   = res.username_size_pct / 100.0
    local read_scale    = res.read_size_pct / 100.0

    -- 4. Extract base transform & font proportions from Line 1
    local base = extract_base_tags(first_line.text, base_style)

    local ox, oy = base.ox, base.oy
    if not ox or not oy then
        if base.px and base.py then
            ox, oy = base.px, base.py
        else
            ox = (clip_pts[1].x + clip_pts[2].x + clip_pts[3].x + clip_pts[4].x) / 4
            oy = (clip_pts[1].y + clip_pts[2].y + clip_pts[3].y + clip_pts[4].y) / 4
        end
    end

    -- 5. Map the 4 screen-space clip corners into local (pre-rotation) ASS space
    local local_pts = {}
    for _, pt in ipairs(clip_pts) do
        local lx, ly = screen_to_local(pt.x, pt.y, ox, oy, base.frx, base.fry, base.frz, focal_d)
        table.insert(local_pts, { x = lx, y = ly })
    end
    local tl, tr, bl, br = order_quad_corners(local_pts)
    local area_top = (tl.y + tr.y) / 2

    -- 6. Build measurement styles for messages, usernames, and read text
    local measure_style = copy_table(base_style)
    measure_style.scale_x = base.fscx
    measure_style.scale_y = base.fscy
    if base.fs  then measure_style.fontsize = base.fs end
    if base.fsp then measure_style.spacing  = base.fsp end
    if base.fn  then measure_style.fontname = base.fn end
    if base.b   then measure_style.bold     = (tonumber(base.b) ~= 0) end
    if base.i   then measure_style.italic   = (tonumber(base.i) ~= 0) end

    local uname_style = copy_table(measure_style)
    uname_style.scale_x = base.fscx * uname_scale
    uname_style.scale_y = base.fscy * uname_scale

    local read_style = copy_table(measure_style)
    read_style.scale_x = base.fscx * read_scale
    read_style.scale_y = base.fscy * read_scale

    -- Pre-measure Read template dimensions
    local read_w, read_h, read_text_norm = 0, 0, ""
    if read_template then
        if read_template.is_shape then
            read_w = read_template.width * read_scale
            read_h = read_template.height * read_scale
        else
            read_text_norm, read_w, read_h = format_and_measure_text(read_template.text, read_style, false, nil)
        end
    end

    local font_tags = ""
    if base.fn  then font_tags = font_tags .. [[\fn]]  .. base.fn end
    if base.fs  then font_tags = font_tags .. [[\fs]]  .. fmt(base.fs) end
    if base.fsp then font_tags = font_tags .. [[\fsp]] .. fmt(base.fsp) end
    if base.b   then font_tags = font_tags .. [[\b]]   .. base.b end
    if base.i   then font_tags = font_tags .. [[\i]]   .. base.i end

    local persp_tags = string.format(
        [=[\org(%s,%s)\frx%s\fry%s\frz%s\fax%s]=],
        fmt(ox), fmt(oy),
        fmt(base.frx), fmt(base.fry), fmt(base.frz), fmt(base.fax)
    )
    local text_scale_tags  = string.format([=[\fscx%s\fscy%s]=], fmt(base.fscx), fmt(base.fscy))
    local uname_scale_tags = string.format([=[\fscx%s\fscy%s]=], fmt(base.fscx * uname_scale), fmt(base.fscy * uname_scale))
    local read_txt_scale   = string.format([=[\fscx%s\fscy%s]=], fmt(base.fscx * read_scale), fmt(base.fscy * read_scale))
    local read_shp_scale   = string.format([=[\fscx%s\fscy%s]=], fmt(res.read_size_pct), fmt(res.read_size_pct))

    -- 7. Generate elements for all message lines
    local generated_lines = {}
    local current_y = base.py or (area_top + clip_margin)

    local UNAME_V_GAP = 4
    local UNAME_H_GAP = 8
    local READ_H_GAP  = 6

    for idx, line_num in ipairs(sel) do
        local orig = sub[line_num]
        local eff_info = parse_effect(orig.effect)
        local clean_text = trim(orig.text:gsub("{[^}]*}", ""))

        local is_template = eff_info.is_read_template or eff_info.is_avatar_template
        if (not is_template) and (not (idx == 1 and clean_text == "")) then
            local is_right   = eff_info.is_right
            local has_read   = eff_info.has_read
            local has_avatar = eff_info.has_avatar

            local tail_enable = is_right and res.right_arrow_enable or res.left_arrow_enable
            local tail_w      = is_right and res.right_arrow_size   or res.left_arrow_size
            local tail_h      = is_right and res.right_arrow_height or res.left_arrow_height
            local tail_pos    = is_right and res.right_arrow_pos    or res.left_arrow_pos
            local tail_curve  = is_right and res.right_arrow_curve  or res.left_arrow_curve
            local tail_dir    = is_right and res.right_arrow_dir    or res.left_arrow_dir
            local tail_offset = (tail_enable and tail_w > 0 and tail_h > 0) and tail_w or 0

            local actor_name = trim(orig.actor)
            local use_uname  = (actor_name ~= "" and res.username_mode ~= "Off")
            local uname_norm, uname_w, uname_h = "", 0, 0
            if use_uname then
                uname_norm, uname_w, uname_h = format_and_measure_text(actor_name, uname_style, false, nil)
            end

            -- Resolve multi-line avatar if requested on this line
            local avatar_group = has_avatar and resolve_avatar(actor_name) or nil
            local av_scale, av_w, av_h, av_shift = 1, 0, 0, 0
            if avatar_group then
                av_scale = avatar_target / math.max(avatar_group.width, avatar_group.height)
                av_w     = avatar_group.width * av_scale
                av_h     = avatar_group.height * av_scale
                av_shift = av_w + avatar_gap
            end

            local txt_color = is_right and right_txt_ass or left_txt_ass
            local box_color = is_right and right_box_ass or left_box_ass

            -- Measure text first (using estimated Y for optional auto-wrap width)
            local est_y = current_y
            local est_clip_w = math.max(10, edge_x_at_y(tr, br, est_y) - edge_x_at_y(tl, bl, est_y))
            local max_text_w = nil
            if res.auto_wrap_enable then
                local max_box_w = est_clip_w * (res.max_width_pct / 100.0)
                max_text_w = math.max(10, max_box_w - (2 * pad_x))
            end

            local formatted_text, block_w, block_h = format_and_measure_text(
                clean_text,
                measure_style,
                res.ignore_line_breaks,
                max_text_w
            )
            local box_w = block_w + (2 * pad_x)
            local box_h = block_h + (2 * pad_y)

            -- Determine vertical coordinates for bubble, username, and avatar
            local box_y, uname_y, avatar_y
            if idx == 1 and base.py then
                local text_top = anchor_y_to_top(base.py, base.an, block_h)
                box_y = text_top - pad_y
                if use_uname and res.username_mode == "Above" then
                    uname_y = box_y - UNAME_V_GAP - uname_h
                end
                if avatar_group then
                    if res.avatar_align == "Middle" then
                        avatar_y = box_y + (box_h - av_h) / 2
                    elseif res.avatar_align == "Bottom" then
                        avatar_y = box_y + box_h - av_h
                    else
                        avatar_y = box_y
                    end
                end
            else
                if use_uname and res.username_mode == "Above" then
                    uname_y = current_y
                    box_y   = uname_y + uname_h + UNAME_V_GAP
                else
                    box_y = current_y
                end
                if avatar_group then
                    if res.avatar_align == "Middle" then
                        avatar_y = box_y + (box_h - av_h) / 2
                    elseif res.avatar_align == "Bottom" then
                        avatar_y = box_y + box_h - av_h
                    else
                        avatar_y = box_y
                    end
                    -- Shift the row downward if a tall avatar would overlap the previous row
                    if avatar_y < current_y then
                        local shift = current_y - avatar_y
                        avatar_y = avatar_y + shift
                        box_y    = box_y + shift
                        if uname_y then
                            uname_y = uname_y + shift
                        end
                    end
                end
            end

            local raw_left   = edge_x_at_y(tl, bl, box_y)
            local raw_right  = edge_x_at_y(tr, br, box_y)
            local left_edge  = raw_left + clip_margin
            local right_edge = raw_right - clip_margin

            local av_x    = nil
            local uname_x = nil
            local box_x   = nil

            if avatar_group and use_uname and res.username_mode == "Next to" then
                -- Avatar + Username stacked vertically in an outer column, bubble shifted inward
                local col_w    = math.max(av_w, uname_w)
                local av_raw_l = edge_x_at_y(tl, bl, avatar_y) + clip_margin
                local av_raw_r = edge_x_at_y(tr, br, avatar_y) - clip_margin

                uname_y = avatar_y + av_h + UNAME_V_GAP
                local u_raw_l = edge_x_at_y(tl, bl, uname_y) + clip_margin
                local u_raw_r = edge_x_at_y(tr, br, uname_y) - clip_margin

                if is_right then
                    av_x    = av_raw_r - col_w + (col_w - av_w) / 2
                    uname_x = u_raw_r  - col_w + (col_w - uname_w) / 2
                    box_x   = math.max(left_edge, right_edge - col_w - avatar_gap - tail_offset - box_w)
                else
                    av_x    = av_raw_l + (col_w - av_w) / 2
                    uname_x = u_raw_l  + (col_w - uname_w) / 2
                    box_x   = left_edge + col_w + avatar_gap + tail_offset
                end
            else
                -- Standard Avatar horizontal position (if present)
                if avatar_group then
                    local av_left_edge  = edge_x_at_y(tl, bl, avatar_y) + clip_margin
                    local av_right_edge = edge_x_at_y(tr, br, avatar_y) - clip_margin
                    av_x = is_right and (av_right_edge - av_w) or av_left_edge
                end

                if use_uname and res.username_mode == "Above" then
                    local u_left  = edge_x_at_y(tl, bl, uname_y) + clip_margin + av_shift + tail_offset
                    local u_right = edge_x_at_y(tr, br, uname_y) - clip_margin - av_shift - tail_offset
                    uname_x = is_right and (u_right - uname_w) or u_left
                    if is_right then
                        box_x = math.max(left_edge, right_edge - av_shift - tail_offset - box_w)
                    else
                        box_x = left_edge + av_shift + tail_offset
                    end
                elseif use_uname and res.username_mode == "Next to" then
                    -- No avatar on this line: username sits next to the bubble
                    uname_y = box_y
                    if is_right then
                        uname_x = right_edge - uname_w
                        box_x   = math.max(left_edge, uname_x - UNAME_H_GAP - tail_offset - box_w)
                    else
                        uname_x = left_edge
                        box_x   = uname_x + uname_w + UNAME_H_GAP + tail_offset
                    end
                else
                    if is_right then
                        box_x = math.max(left_edge, right_edge - av_shift - tail_offset - box_w)
                    else
                        box_x = left_edge + av_shift + tail_offset
                    end
                end
            end

            -- 1) Generate multi-line avatar (if present)
            if avatar_group and av_x and avatar_y then
                local av_fsc = fmt(av_scale * 100.0)
                for _, part in ipairs(avatar_group.parts) do
                    local av_line = copy_table(orig)
                    av_line.layer = orig.layer + part.layer_offset
                    av_line.text = string.format(
                        [=[{\an7\pos(%s,%s)%s\fscx%s\fscy%s%s\p1}%s{\p0}]=],
                        fmt(av_x), fmt(avatar_y),
                        persp_tags, av_fsc, av_fsc,
                        part.visual_tags, part.drawing
                    )
                    table.insert(generated_lines, av_line)
                end
            end

            -- 2) Username line (if present)
            if use_uname and uname_x and uname_y then
                local uname_line = copy_table(orig)
                uname_line.layer = orig.layer + 1
                uname_line.text = string.format(
                    [=[{\an7\pos(%s,%s)%s%s%s\1c%s}%s]=],
                    fmt(uname_x), fmt(uname_y),
                    persp_tags, uname_scale_tags, font_tags,
                    uname_ass, uname_norm
                )
                table.insert(generated_lines, uname_line)
            end

            local text_y = box_y + pad_y
            local text_x = box_x + pad_x + (base.fax * pad_y)

            -- 3) Seamless bubble + customizable balloon tail (\p1) on orig.layer
            local box_line = copy_table(orig)
            box_line.layer = orig.layer
            box_line.text = string.format(
                [=[{\an7\pos(%s,%s)%s\fscx100\fscy100\bord0\shad0\1c%s\p1}%s{\p0}]=],
                fmt(box_x),
                fmt(box_y),
                persp_tags,
                box_color,
                build_box_drawing(box_w, box_h, corner_radius, is_right, tail_enable, tail_w, tail_h, tail_pos, tail_curve, tail_dir)
            )
            table.insert(generated_lines, box_line)

            -- 4) Message text on orig.layer + 1
            local txt_line = copy_table(orig)
            txt_line.layer = orig.layer + 1
            txt_line.text = string.format(
                [=[{\an7\pos(%s,%s)%s%s%s\1c%s}%s]=],
                fmt(text_x),
                fmt(text_y),
                persp_tags,
                text_scale_tags,
                font_tags,
                txt_color,
                formatted_text
            )
            table.insert(generated_lines, txt_line)

            -- 5) Read indicator (uses "Read" template line if present, else defaults to "Read")
            if has_read and read_template then
                local read_y = box_y + box_h - read_h
                local fax_shift = base.fax * (read_y - box_y)
                local read_x
                if is_right then
                    read_x = box_x - READ_H_GAP - read_w + fax_shift
                else
                    read_x = box_x + box_w + READ_H_GAP + fax_shift
                end

                local read_line = copy_table(orig)
                read_line.layer = orig.layer + 1
                if read_template.is_shape then
                    read_line.text = string.format(
                        [=[{\an7\pos(%s,%s)%s%s\bord0\shad0\1c%s\p1}%s{\p0}]=],
                        fmt(read_x), fmt(read_y),
                        persp_tags, read_shp_scale,
                        read_ass, read_template.drawing
                    )
                else
                    read_line.text = string.format(
                        [=[{\an7\pos(%s,%s)%s%s%s\1c%s}%s]=],
                        fmt(read_x), fmt(read_y),
                        persp_tags, read_txt_scale, font_tags,
                        read_ass, read_text_norm
                    )
                end
                table.insert(generated_lines, read_line)
            end

            -- Advance vertical cursor below the tallest element (bubble, username, or avatar)
            local row_bottom = box_y + box_h
            if use_uname and uname_y then
                row_bottom = math.max(row_bottom, uname_y + uname_h)
            end
            if avatar_group and avatar_y then
                row_bottom = math.max(row_bottom, avatar_y + av_h)
            end
            current_y = row_bottom + spacing
        end
    end

    -- 8. Replace original selected lines (deletes Line 1 clip, Read, and Avatar template lines)
    local insert_pos = sel[1]
    for i = #sel, 1, -1 do
        sub.delete(sel[i])
    end

    local new_sel = {}
    for i, new_line in ipairs(generated_lines) do
        local target_idx = insert_pos + i - 1
        sub.insert(target_idx, new_line)
        table.insert(new_sel, target_idx)
    end

    aegisub.set_undo_point(script_name)
    return new_sel
end

if haveDepCtrl then
    depRec:registerMacro(run_phone_sign)
else
    aegisub.register_macro(script_name, script_description, run_phone_sign)
end