script_name = "AutoPhone"
script_description = "Automates positioned phone chat signs with perspective-matched bubbles, seamless tails, usernames, read indicators, and optional auto-wrapping."
script_author = "Magi"
script_version = "2.1.1"
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

    -- Left bubble arrow
    left_arrow_enable  = false,
    left_arrow_size    = 12,
    left_arrow_pos     = "Top",
    left_arrow_curved  = true,

    -- Right bubble arrow
    right_arrow_enable = false,
    right_arrow_size   = 12,
    right_arrow_pos    = "Top",
    right_arrow_curved = true
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
-- ASS Tag & Vector Clip Parsing
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
        fs   = fs,
        fsp  = fsp,
        fn   = fn,
        b    = b,
        i    = i
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

local function parse_effect(eff_raw)
    local eff = trim(eff_raw):lower():gsub("%s+", " ")
    if eff == "read" then
        return { is_read_template = true }
    end

    local is_right = (eff == "right" or eff == "r" or eff == "right read" or eff == "r read")
    local has_read = (eff == "left read" or eff == "l read" or eff == "right read" or eff == "r read")
    return {
        is_read_template = false,
        is_right         = is_right,
        has_read         = has_read
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

    -- Split into paragraphs on \N
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
-- Single-Contour Seamless Bubble + Arrow Drawing (\p1)
-- ============================================================================

local function build_box_drawing(w, h, radius, is_right, arrow_enable, arrow_size, arrow_pos, arrow_curved)
    local has_arrow = arrow_enable and (arrow_size or 0) > 0
    local s = has_arrow and arrow_size or 0
    local r = math.max(0, math.min(radius or 0, w / 2, h / 2))

    local r_tl, r_tr, r_br, r_bl = r, r, r, r
    if has_arrow and arrow_pos == "Middle" then
        local min_base = math.min(h * 0.6, s * 1.1)
        local max_side_r = math.max(0, (h - min_base) / 2)
        if is_right then
            r_tr = math.min(r_tr, max_side_r)
            r_br = math.min(r_br, max_side_r)
        else
            r_tl = math.min(r_tl, max_side_r)
            r_bl = math.min(r_bl, max_side_r)
        end
    end

    local is_tl = has_arrow and (not is_right) and (arrow_pos == "Top")
    local is_bl = has_arrow and (not is_right) and (arrow_pos == "Bottom")
    local is_ml = has_arrow and (not is_right) and (arrow_pos == "Middle")
    local is_tr = has_arrow and is_right and (arrow_pos == "Top")
    local is_br = has_arrow and is_right and (arrow_pos == "Bottom")
    local is_mr = has_arrow and is_right and (arrow_pos == "Middle")

    local K = 0.55228475
    local cmds = {}
    local function add(str) table.insert(cmds, str) end

    local ax = math.min(w * 0.5, math.max(r, s * 0.9))
    local ay = math.min(h * 0.5, math.max(r, s * 1.15))

    local top_start_x = is_tl and ax or r_tl
    add(string.format("m %s 0", fmt(top_start_x)))

    -- 1. Top edge -> Top-Right corner (or Top-Right arrow)
    if is_tr then
        local tr_x = math.max(top_start_x, w - ax)
        local tr_y = math.min(h - r_br, ay)
        add(string.format("l %s 0", fmt(tr_x)))
        if arrow_curved then
            add(string.format(
                "b %s %s %s 0 %s 0 b %s %s %s %s %s %s",
                fmt(w - (w - tr_x) * 0.25), fmt(s * 0.08),
                fmt(w + s * 0.35),
                fmt(w + s),
                fmt(w + s * 0.35), fmt(tr_y * 0.12),
                fmt(w), fmt(tr_y * 0.45),
                fmt(w), fmt(tr_y)
            ))
        else
            add(string.format("l %s 0 %s %s", fmt(w + s), fmt(w), fmt(tr_y)))
        end
    else
        add(string.format("l %s 0", fmt(w - r_tr)))
        if r_tr >= 0.5 then
            local c = r_tr * (1 - K)
            add(string.format("b %s 0 %s %s %s %s", fmt(w - c), fmt(w), fmt(c), fmt(w), fmt(r_tr)))
        end
    end

    -- 2. Right edge (with optional Middle-Right arrow)
    if is_mr then
        local mid_y = h / 2
        local half_b = math.min((h - r_tr - r_br) / 2, s * 0.6)
        local top_y = mid_y - half_b
        local bot_y = mid_y + half_b
        add(string.format("l %s %s", fmt(w), fmt(top_y)))
        if arrow_curved then
            add(string.format(
                "b %s %s %s %s %s %s b %s %s %s %s %s %s",
                fmt(w + s * 0.25), fmt(top_y + half_b * 0.45),
                fmt(w + s * 0.65), fmt(mid_y - half_b * 0.18),
                fmt(w + s), fmt(mid_y),
                fmt(w + s * 0.65), fmt(mid_y + half_b * 0.18),
                fmt(w + s * 0.25), fmt(bot_y - half_b * 0.45),
                fmt(w), fmt(bot_y)
            ))
        else
            add(string.format("l %s %s %s %s", fmt(w + s), fmt(mid_y), fmt(w), fmt(bot_y)))
        end
    end

    -- 3. Bottom-Right corner (or Bottom-Right arrow)
    if is_br then
        local br_y = math.max(r_tr, h - ay)
        local br_x = math.max(r_bl, w - ax)
        add(string.format("l %s %s", fmt(w), fmt(br_y)))
        if arrow_curved then
            add(string.format(
                "b %s %s %s %s %s %s b %s %s %s %s %s %s",
                fmt(w), fmt(br_y + (h - br_y) * 0.55),
                fmt(w + s * 0.35), fmt(h - (h - br_y) * 0.12),
                fmt(w + s), fmt(h),
                fmt(w + s * 0.35), fmt(h),
                fmt(w - (w - br_x) * 0.25), fmt(h - s * 0.08),
                fmt(br_x), fmt(h)
            ))
        else
            add(string.format("l %s %s %s %s", fmt(w + s), fmt(h), fmt(br_x), fmt(h)))
        end
    else
        add(string.format("l %s %s", fmt(w), fmt(h - r_br)))
        if r_br >= 0.5 then
            local c = r_br * (1 - K)
            add(string.format("b %s %s %s %s %s %s", fmt(w), fmt(h - c), fmt(w - c), fmt(h), fmt(w - r_br), fmt(h)))
        end
    end

    -- 4. Bottom edge -> Bottom-Left corner (or Bottom-Left arrow)
    if is_bl then
        local bl_x = math.min(w - r_br, ax)
        local bl_y = math.max(r_tl, h - ay)
        add(string.format("l %s %s", fmt(bl_x), fmt(h)))
        if arrow_curved then
            add(string.format(
                "b %s %s %s %s %s %s b %s %s 0 %s 0 %s",
                fmt(bl_x * 0.25), fmt(h - s * 0.08),
                fmt(-s * 0.35), fmt(h),
                fmt(-s), fmt(h),
                fmt(-s * 0.35), fmt(h - (h - bl_y) * 0.12),
                fmt(bl_y + (h - bl_y) * 0.55),
                fmt(bl_y)
            ))
        else
            add(string.format("l %s %s 0 %s", fmt(-s), fmt(h), fmt(bl_y)))
        end
    else
        add(string.format("l %s %s", fmt(r_bl), fmt(h)))
        if r_bl >= 0.5 then
            local c = r_bl * (1 - K)
            add(string.format("b %s %s 0 %s 0 %s", fmt(c), fmt(h), fmt(h - c), fmt(h - r_bl)))
        end
    end

    -- 5. Left edge (with optional Middle-Left arrow)
    if is_ml then
        local mid_y = h / 2
        local half_b = math.min((h - r_tl - r_bl) / 2, s * 0.6)
        local top_y = mid_y - half_b
        local bot_y = mid_y + half_b
        add(string.format("l 0 %s", fmt(bot_y)))
        if arrow_curved then
            add(string.format(
                "b %s %s %s %s %s %s b %s %s %s %s 0 %s",
                fmt(-s * 0.25), fmt(bot_y - half_b * 0.45),
                fmt(-s * 0.65), fmt(mid_y + half_b * 0.18),
                fmt(-s), fmt(mid_y),
                fmt(-s * 0.65), fmt(mid_y - half_b * 0.18),
                fmt(-s * 0.25), fmt(top_y + half_b * 0.45),
                fmt(top_y)
            ))
        else
            add(string.format("l %s %s 0 %s", fmt(-s), fmt(mid_y), fmt(top_y)))
        end
    end

    -- 6. Top-Left corner (or Top-Left arrow) closing back to (top_start_x, 0)
    if is_tl then
        local tl_y = math.min(h - r_bl, ay)
        add(string.format("l 0 %s", fmt(tl_y)))
        if arrow_curved then
            add(string.format(
                "b 0 %s %s %s %s 0 b %s 0 %s %s %s 0",
                fmt(tl_y * 0.45),
                fmt(-s * 0.35), fmt(tl_y * 0.12),
                fmt(-s),
                fmt(-s * 0.35),
                fmt(top_start_x * 0.25), fmt(s * 0.08),
                fmt(top_start_x)
            ))
        else
            add(string.format("l %s 0 %s 0", fmt(-s), fmt(top_start_x)))
        end
    else
        add(string.format("l 0 %s", fmt(r_tl)))
        if r_tl >= 0.5 then
            local c = r_tl * (1 - K)
            add(string.format("b 0 %s %s 0 %s 0", fmt(c), fmt(c), fmt(r_tl)))
        end
    end

    return table.concat(cmds, " ")
end

-- ============================================================================
-- GUI Dialog
-- ============================================================================

local function show_dialog(cfg)
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

        { class = "label",     label = "Box Padding (px):",   x = 0, y = 2, width = 1, height = 1 },
        { class = "floatedit", name  = "padding",             value = cfg.padding, min = 0, max = 200, x = 1, y = 2, width = 1, height = 1 },
        { class = "label",     label = "Line Spacing (px):",  x = 2, y = 2, width = 1, height = 1 },
        { class = "floatedit", name  = "spacing",             value = cfg.spacing, min = 0, max = 500, x = 3, y = 2, width = 1, height = 1 },

        { class = "label",     label = "Clip Margin (px):",   x = 0, y = 3, width = 1, height = 1 },
        { class = "floatedit", name  = "clip_margin",         value = cfg.clip_margin, min = 0, max = 500, x = 1, y = 3, width = 1, height = 1 },
        { class = "label",     label = "Corner Radius (px):", x = 2, y = 3, width = 1, height = 1 },
        { class = "intedit",   name  = "corner_radius",       value = cfg.corner_radius, min = 0, max = 100, x = 3, y = 3, width = 1, height = 1 },

        -- Line Breaks & Auto-Wrap
        { class = "label",    label = "─── Line Breaks & Wrapping ───", x = 0, y = 4, width = 4, height = 1 },
        { class = "checkbox", name  = "ignore_line_breaks", label = "Ignore line breaks", value = cfg.ignore_line_breaks, x = 0, y = 5, width = 2, height = 1 },
        { class = "checkbox", name  = "auto_wrap_enable",   label = "Auto-wrap > Clip %", value = cfg.auto_wrap_enable,   x = 2, y = 5, width = 1, height = 1 },
        { class = "intedit",  name  = "max_width_pct",      value = cfg.max_width_pct, min = 15, max = 100, x = 3, y = 5, width = 1, height = 1 },

        -- Username (Actor Field)
        { class = "label",    label = "─── Username (Actor Field) ───", x = 0, y = 6, width = 4, height = 1 },
        { class = "label",    label = "Position:",        x = 0, y = 7, width = 1, height = 1 },
        { class = "dropdown", name  = "username_mode",    items = { "Off", "Above", "Next to" }, value = cfg.username_mode, x = 1, y = 7, width = 1, height = 1 },
        { class = "label",    label = "Username Color:",  x = 2, y = 7, width = 1, height = 1 },
        { class = "color",    name  = "username_color",   value = cfg.username_color, x = 3, y = 7, width = 1, height = 1 },
        { class = "label",    label = "Size (% of text):", x = 0, y = 8, width = 1, height = 1 },
        { class = "intedit",  name  = "username_size_pct", value = cfg.username_size_pct, min = 10, max = 200, x = 1, y = 8, width = 1, height = 1 },

        -- Read Indicator
        { class = "label",   label = "─── Read Indicator (Effect: Read / Left Read / Right Read) ───", x = 0, y = 9, width = 4, height = 1 },
        { class = "label",   label = "Read Color:",       x = 0, y = 10, width = 1, height = 1 },
        { class = "color",   name  = "read_color",        value = cfg.read_color, x = 1, y = 10, width = 1, height = 1 },
        { class = "label",   label = "Read Size (%):",    x = 2, y = 10, width = 1, height = 1 },
        { class = "intedit", name  = "read_size_pct",     value = cfg.read_size_pct, min = 10, max = 300, x = 3, y = 10, width = 1, height = 1 },

        -- Bubble Arrows
        { class = "label",     label = "─── Bubble Arrows (Tails) ───", x = 0, y = 11, width = 4, height = 1 },

        { class = "checkbox",  name  = "left_arrow_enable",  label = "Left Arrow",   value = cfg.left_arrow_enable, x = 0, y = 12, width = 1, height = 1 },
        { class = "checkbox",  name  = "left_arrow_curved",  label = "Curved",       value = cfg.left_arrow_curved, x = 1, y = 12, width = 1, height = 1 },
        { class = "label",     label = "Left Size (px):",    x = 2, y = 12, width = 1, height = 1 },
        { class = "floatedit", name  = "left_arrow_size",    value = cfg.left_arrow_size, min = 1, max = 100, x = 3, y = 12, width = 1, height = 1 },
        { class = "label",     label = "Left Arrow Pos:",    x = 0, y = 13, width = 1, height = 1 },
        { class = "dropdown",  name  = "left_arrow_pos",     items = { "Top", "Middle", "Bottom" }, value = cfg.left_arrow_pos, x = 1, y = 13, width = 1, height = 1 },

        { class = "checkbox",  name  = "right_arrow_enable", label = "Right Arrow",  value = cfg.right_arrow_enable, x = 0, y = 14, width = 1, height = 1 },
        { class = "checkbox",  name  = "right_arrow_curved", label = "Curved",       value = cfg.right_arrow_curved, x = 1, y = 14, width = 1, height = 1 },
        { class = "label",     label = "Right Size (px):",   x = 2, y = 14, width = 1, height = 1 },
        { class = "floatedit", name  = "right_arrow_size",   value = cfg.right_arrow_size, min = 1, max = 100, x = 3, y = 14, width = 1, height = 1 },
        { class = "label",     label = "Right Arrow Pos:",   x = 0, y = 15, width = 1, height = 1 },
        { class = "dropdown",  name  = "right_arrow_pos",    items = { "Top", "Middle", "Bottom" }, value = cfg.right_arrow_pos, x = 1, y = 15, width = 1, height = 1 }
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

    -- 2. Scan selected lines for a "Read" template line (Effect == "Read")
    --    If none is found, default to plain text "Read"
    local read_template = nil
    for _, line_num in ipairs(sel) do
        local info = parse_effect(sub[line_num].effect)
        if info.is_read_template then
            read_template = parse_read_template(sub[line_num].text)
            break
        end
    end
    if not read_template then
        read_template = {
            is_shape = false,
            text     = "Read"
        }
    end

    -- 3. Show GUI with remembered settings
    local cfg = load_config()
    local res = show_dialog(cfg)
    if not res then
        return sel
    end
    save_config(res)

    local pad           = res.padding
    local spacing       = res.spacing
    local clip_margin   = res.clip_margin
    local corner_radius = res.corner_radius

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
    local current_y = area_top + clip_margin

    local UNAME_V_GAP = 4
    local UNAME_H_GAP = 8
    local READ_H_GAP  = 6

    for idx, line_num in ipairs(sel) do
        local orig = sub[line_num]
        local eff_info = parse_effect(orig.effect)
        local clean_text = trim(orig.text:gsub("{[^}]*}", ""))

        if (not eff_info.is_read_template) and (not (idx == 1 and clean_text == "")) then
            local is_right = eff_info.is_right
            local has_read = eff_info.has_read

            local arrow_enable = is_right and res.right_arrow_enable or res.left_arrow_enable
            local arrow_size   = is_right and res.right_arrow_size   or res.left_arrow_size
            local arrow_pos    = is_right and res.right_arrow_pos    or res.left_arrow_pos
            local arrow_curved = is_right and res.right_arrow_curved or res.left_arrow_curved
            local arrow_offset = (arrow_enable and arrow_size > 0) and arrow_size or 0

            local actor_name = trim(orig.actor)
            local use_uname  = (actor_name ~= "" and res.username_mode ~= "Off")
            local uname_norm, uname_w, uname_h = "", 0, 0
            if use_uname then
                uname_norm, uname_w, uname_h = format_and_measure_text(actor_name, uname_style, false, nil)
            end

            local txt_color = is_right and right_txt_ass or left_txt_ass
            local box_color = is_right and right_box_ass or left_box_ass

            local uname_line = nil
            local box_y = current_y

            -- If username is "Above", place it above the bubble first
            if use_uname and res.username_mode == "Above" then
                local uname_y = current_y
                local u_left  = edge_x_at_y(tl, bl, uname_y) + clip_margin + arrow_offset
                local u_right = edge_x_at_y(tr, br, uname_y) - clip_margin - arrow_offset
                local uname_x = is_right and (u_right - uname_w) or u_left

                uname_line = copy_table(orig)
                uname_line.layer = orig.layer + 1
                uname_line.text = string.format(
                    [=[{\an7\pos(%s,%s)%s%s%s\1c%s}%s]=],
                    fmt(uname_x), fmt(uname_y),
                    persp_tags, uname_scale_tags, font_tags,
                    uname_ass, uname_norm
                )

                box_y = uname_y + uname_h + UNAME_V_GAP
            end

            local raw_left   = edge_x_at_y(tl, bl, box_y)
            local raw_right  = edge_x_at_y(tr, br, box_y)
            local clip_w     = math.max(10, raw_right - raw_left)
            local left_edge  = raw_left + clip_margin
            local right_edge = raw_right - clip_margin

            -- Calculate optional max text width from user-defined Clip %
            local max_text_w = nil
            if res.auto_wrap_enable then
                local max_box_w = clip_w * (res.max_width_pct / 100.0)
                max_text_w = math.max(10, max_box_w - (2 * pad))
            end

            local formatted_text, block_w, block_h = format_and_measure_text(
                clean_text,
                measure_style,
                res.ignore_line_breaks,
                max_text_w
            )
            local box_w = block_w + (2 * pad)
            local box_h = block_h + (2 * pad)

            local box_x
            if use_uname and res.username_mode == "Next to" then
                local uname_y = box_y
                local uname_x
                if is_right then
                    uname_x = right_edge - uname_w
                    box_x = math.max(left_edge, uname_x - UNAME_H_GAP - arrow_offset - box_w)
                else
                    uname_x = left_edge
                    box_x = uname_x + uname_w + UNAME_H_GAP + arrow_offset
                end

                uname_line = copy_table(orig)
                uname_line.layer = orig.layer + 1
                uname_line.text = string.format(
                    [=[{\an7\pos(%s,%s)%s%s%s\1c%s}%s]=],
                    fmt(uname_x), fmt(uname_y),
                    persp_tags, uname_scale_tags, font_tags,
                    uname_ass, uname_norm
                )
            else
                if is_right then
                    box_x = math.max(left_edge, right_edge - arrow_offset - box_w)
                else
                    box_x = left_edge + arrow_offset
                end
            end

            local text_y = box_y + pad
            local text_x = box_x + pad + (base.fax * pad)

            -- 1) Username line (if present)
            if uname_line then
                table.insert(generated_lines, uname_line)
            end

            -- 2) Seamless bubble + arrow (\p1) on orig.layer
            local box_line = copy_table(orig)
            box_line.layer = orig.layer
            box_line.text = string.format(
                [=[{\an7\pos(%s,%s)%s\fscx100\fscy100\bord0\shad0\1c%s\p1}%s{\p0}]=],
                fmt(box_x),
                fmt(box_y),
                persp_tags,
                box_color,
                build_box_drawing(box_w, box_h, corner_radius, is_right, arrow_enable, arrow_size, arrow_pos, arrow_curved)
            )
            table.insert(generated_lines, box_line)

            -- 3) Message text on orig.layer + 1
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

            -- 4) Read indicator (uses "Read" template line if present, else defaults to "Read")
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

            -- Advance vertical cursor directly below the tallest element on this row
            local row_bottom = box_y + box_h
            if use_uname and res.username_mode == "Next to" then
                row_bottom = math.max(row_bottom, box_y + uname_h)
            end
            current_y = row_bottom + spacing
        end
    end

    -- 8. Replace original selected lines (also deletes Line 1 clip & Read template line)
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