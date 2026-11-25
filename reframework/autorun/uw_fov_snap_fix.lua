-- Ultrawide FOV snap fix for Resident Evil 4 Remake (REFramework script).
--
-- What goes wrong without it
-- --------------------------
-- REFramework's ultrawide fix widens the camera every frame. RE4's inventory
-- and item-pickup screens are built for the stock camera, so REFramework
-- pauses the fix while those screens are drawn, plus 100 ms afterwards.
--
-- When such a screen closes, the camera is back in the game world straight
-- away, but the screen keeps fading out for 0.2 to 0.55 s. During that fade:
--   * the live game is drawn with the stock (zoomed-in) camera, and
--   * on top of it the game fades out a frozen copy of the screen that was
--     taken when the menu opened, i.e. with the wide camera.
-- So the picture cross-fades from wide (copy) to zoomed-in (live) and then
-- jumps back to wide when the fix resumes.
--
-- What this script does
-- ---------------------
-- 1. As soon as the camera is back in the game world it applies the same
--    wide camera REFramework would.
-- 2. The frozen screen copy ("AcBackGround") is a quad the game places in
--    front of the camera, sized to exactly fill the stock view. It is
--    enlarged to fill the wide view, so it still hides the scene settling
--    after the camera cut and fades out as intended.
-- 3. Other camera-drawn menu panels (the grey smoke backdrop on pickups)
--    would shrink to a rectangle, so they are skipped during the fade. Flat
--    panels are untouched and fade normally.
-- 4. The game nudges the FOV by about a degree around menus and the map
--    (a dip and a one-frame pop after menus, a slow ease after the map).
--    The FOV is held steady through those, and any real change is followed
--    with a short glide instead of a jump.
--
-- To remove: delete this file from reframework/autorun.

local VERSION = 12
local CONFIG_FILE = "uw_fov_snap_fix_v12.json"

-- GUI objects REFramework treats as "a menu showing the game scene is open".
local MENU_GUI = {
    AcBackGround = true,   -- frozen copy of the screen drawn behind menus
    Gui_ArmouryTab = true, -- typewriter storage
    Gui_ui3030 = true,     -- inventory
    Gui_ui3040 = true,     -- item pickup
}

local VIEW_TYPE_WORLD = 1

local cfg = {
    -- Master switch. When false the script does nothing at all: no camera
    -- changes, no panel changes, no logging. Plain REFramework behaviour.
    enabled = true,
    resize_background = true, -- keep the frozen screen copy and enlarge it
    steady_map_fov = true,    -- hold the FOV steady while the map opens and closes
    diagnostics = false,      -- writes camera/GUI state to the REFramework log, for troubleshooting
}

local function load_config()
    local ok, data = pcall(json.load_file, CONFIG_FILE)
    if ok and type(data) == "table" then
        for key, _ in pairs(cfg) do
            if type(data[key]) == "boolean" then cfg[key] = data[key] end
        end
    end
end

local function save_config()
    pcall(json.dump_file, CONFIG_FILE, cfg)
end

load_config()

local graphics = nil
pcall(function() graphics = REFGraphics.get() end)

-- REFramework keeps its fix off for this long after the last menu frame.
local BUILTIN_PAUSE_SECONDS = 0.1
-- A menu panel was drawn this recently: the menu is still on screen.
local MENU_DRAWING_SECONDS = 0.05
-- Only step in while a menu is on screen or shortly after.
local ACTIVE_WINDOW_SECONDS = 0.3
-- Keep the FOV steady for this long after the map was last drawn.
local MAP_HOLD_SECONDS = 1.2
-- Camera height below which it is showing the inventory scene (0, -100, 0).
local MENU_SCENE_MAX_Y = -50.0
-- Longest a menu keeps fading after the camera returns (measured: up to 0.55 s).
local FADE_OUT_MAX_SECONDS = 1.5
-- FOV changes up to this many degrees around menus and the map are treated
-- as the game's cosmetic nudge and ignored. Larger ones (aiming, sprinting)
-- are followed.
local FOV_HOLD_TOLERANCE = 1.5
-- Time constant of the glide used when the FOV does have to change.
local SMOOTH_TIME_CONSTANT = 0.06
local SMOOTH_STALE_SECONDS = 0.25
-- The enlarged screen copy is made this much bigger than strictly needed so
-- that no edge can show.
local BACKGROUND_OVERSCAN = 1.003

local last_menu_time = -1000.0
local last_map_time = -1000.0
local last_menu_scene_time = -1000.0
local pre = nil            -- camera state before REFramework's fix ran this frame
local applied = nil        -- camera values this script must put back this frame
local planned_vfov = nil   -- wide vertical FOV this script wants for this frame
local hold_base_fov = nil  -- FOV being held steady during the current episode
local gameplay_fov = nil   -- last FOV seen with no menu or map involved
local smooth_vfov = nil
local smooth_time = 0.0
local world_panel_drawn = false -- a camera-drawn menu panel was drawn unskipped, unresized
local world_panel_drawn_copy = false

local bg_transform = nil
local bg_transform_addr = nil
local bg_original_scale = nil
local bg_scaled = false

local applied_count = 0
local held_count = 0
local hidden_count = 0
local bg_resize_count = 0
local last_error = nil
local view_type_cache = {}

-- Diagnostics state
local DIAG_WINDOW_SECONDS = 2.0
local frame_index = 0
local gui_now = {}
local gui_prev = {}
local menu_now = {}
local hidden_now = {}
local last_diag_signature = nil
local diag_lines = 0

local function flag(obj, method)
    local ok, value = pcall(obj.call, obj, method)
    if ok and value ~= nil then return value end
    return true
end

local function guarded(fn)
    local ok, err = pcall(fn)
    if not ok then last_error = tostring(err) end
end

local function try(fn, fallback)
    local ok, value = pcall(fn)
    if ok and value ~= nil then return value end
    return fallback
end

local function camera_position(cam)
    return cam:call("get_GameObject"):call("get_Transform"):call("get_Position")
end

local function is_menu_panel(name)
    return name == "AcBackGround" or string.find(name, "^Gui_ui3%d%d%d") ~= nil
end

local function is_map_panel(name)
    return string.find(name, "^Gui_ui05") ~= nil
end

local function view_type_of(name, element)
    local cached = view_type_cache[name]
    if cached ~= nil then return cached end
    local vt = try(function() return element:call("get_View"):call("get_ViewType") end, -1)
    view_type_cache[name] = vt
    return vt
end

local function fix_enabled()
    return graphics ~= nil and graphics:is_ultrawide_fix_enabled()
end

local function is_wide(aspect)
    return aspect ~= nil and aspect > (16.0 / 9.0) + 0.01
end

-- Vertical FOV REFramework's fix uses: the vertical view of a 16:9 screen.
-- RE4 already scales its horizontal FOV up to 21:9, hence the clamp.
local function wide_vfov(hfov, aspect)
    local fov_aspect = math.max(16.0 / 9.0, math.min(aspect, 21.0 / 9.0))
    return math.deg(2.0 * math.atan(math.tan(math.rad(hfov) / 2.0) / fov_aspect))
end

-- Move the filtered FOV towards a target and return it.
local function smooth_towards(target, now)
    if smooth_vfov == nil or (now - smooth_time) > SMOOTH_STALE_SECONDS then
        smooth_vfov = target
    else
        local alpha = 1.0 - math.exp(-(now - smooth_time) / SMOOTH_TIME_CONSTANT)
        smooth_vfov = smooth_vfov + (target - smooth_vfov) * alpha
    end
    smooth_time = now
    return smooth_vfov
end

local reset_state -- defined below

local function restore_background()
    if not bg_scaled then return end
    bg_scaled = false
    if bg_transform == nil or bg_original_scale == nil then return end
    pcall(function()
        bg_transform:call("set_LocalScale",
            Vector3f.new(bg_original_scale.x, bg_original_scale.y, bg_original_scale.z))
    end)
end

-- Forget everything in progress; used when the master switch is turned off.
reset_state = function()
    restore_background()
    -- "applied" is left alone: if the camera was changed this frame, the
    -- UnlockScene handler still has to put it back.
    planned_vfov = nil
    hold_base_fov = nil
    smooth_vfov = nil
    world_panel_drawn = false
    last_menu_time = -1000.0
    last_map_time = -1000.0
    last_menu_scene_time = -1000.0
end

-- True while the camera is back in the game world shortly after having been
-- in the inventory scene, i.e. while a menu is fading out over gameplay.
local function fading_over_gameplay()
    if not fix_enabled() then return false end
    if os.clock() - last_menu_scene_time > FADE_OUT_MAX_SECONDS then return false end
    local cam = sdk.get_primary_camera()
    if cam == nil then return false end
    local pos = camera_position(cam)
    return pos ~= nil and pos.y >= MENU_SCENE_MAX_Y
end

------------------------------------------------------------------------
-- GUI drawing
------------------------------------------------------------------------

re.on_pre_gui_draw_element(function(element, context)
    local draw = true
    if cfg.enabled then
        guarded(function()
            local go = element:call("get_GameObject")
            if go == nil then return end
            local name = go:call("get_Name")
            if name == nil then return end
            local drawn = flag(go, "get_DrawSelf") and flag(go, "get_UpdateSelf")
            if not drawn then return end

            if MENU_GUI[name] then
                last_menu_time = os.clock()
                menu_now[name] = true
            end
            if is_map_panel(name) then
                last_map_time = os.clock()
            end

            if is_menu_panel(name) and view_type_of(name, element) == VIEW_TYPE_WORLD then
                local is_background = name == "AcBackGround"
                if is_background then
                    local tr = go:call("get_Transform")
                    if tr ~= nil and tr:get_address() ~= bg_transform_addr then
                        bg_transform = tr:add_ref()
                        bg_transform_addr = tr:get_address()
                    end
                end
                if try(fading_over_gameplay, false) then
                    -- The background copy stays (it is enlarged instead); the
                    -- other camera-drawn panels are skipped.
                    if not (is_background and cfg.resize_background) then
                        draw = false
                        hidden_count = hidden_count + 1
                        hidden_now[name] = true
                    end
                else
                    world_panel_drawn = true
                end
            end

            if cfg.diagnostics and draw then gui_now[name] = true end
        end)
    end
    return draw
end)

------------------------------------------------------------------------
-- Camera
------------------------------------------------------------------------

-- Decide, before the scene is locked for rendering, which wide vertical FOV
-- this frame should use. Returns nil when the script has no opinion.
local function plan_frame(aspect, in_world, now)
    if not is_wide(aspect) or not in_world then
        hold_base_fov = nil
        smooth_vfov = nil
        return nil
    end

    local menu_recent = (now - last_menu_time) <= ACTIVE_WINDOW_SECONDS
    local menu_drawing = (now - last_menu_time) <= MENU_DRAWING_SECONDS
    local map_recent = cfg.steady_map_fov and (now - last_map_time) <= MAP_HOLD_SECONDS

    if not (menu_recent or map_recent) then
        -- Nothing going on: remember the gameplay FOV, finish any glide.
        hold_base_fov = nil
        gameplay_fov = pre.fov
        if smooth_vfov == nil then return nil end
        local target = wide_vfov(pre.fov, aspect)
        local value = smooth_towards(target, now)
        if math.abs(value - target) < 0.02 then
            smooth_vfov = nil
            return nil
        end
        return value
    end

    if hold_base_fov == nil then
        -- After a menu the camera comes back at its resting FOV. For the map,
        -- use the FOV from just before it opened.
        if map_recent and not menu_recent and gameplay_fov ~= nil then
            hold_base_fov = gameplay_fov
        else
            hold_base_fov = pre.fov
        end
    end

    local hold = (menu_drawing or map_recent)
        and math.abs(pre.fov - hold_base_fov) <= FOV_HOLD_TOLERANCE
    local source = hold and hold_base_fov or pre.fov
    return smooth_towards(wide_vfov(source, aspect), now)
end

re.on_pre_application_entry("LockScene", function()
    pre = nil
    planned_vfov = nil
    if not cfg.enabled then return end
    guarded(function()
        local cam = sdk.get_primary_camera()
        if cam == nil then return end
        pre = {
            addr = cam:get_address(),
            fov = cam:call("get_FOV"),
            vert = cam:call("get_VerticalEnable"),
        }
        local pos = camera_position(cam)
        local now = os.clock()
        local in_world = pos ~= nil and pos.y >= MENU_SCENE_MAX_Y
        if pos ~= nil and not in_world then
            last_menu_scene_time = now
        end

        if not fix_enabled() or pre.vert then
            restore_background()
            return
        end

        local aspect = cam:call("get_AspectRatio")
        planned_vfov = plan_frame(aspect, in_world, now)

        -- Enlarge the background copy on exactly the frames where this script
        -- will apply the wide view itself: camera back in the world, the
        -- built-in fix still paused by a menu, no unskipped camera-drawn panel.
        local want_resize = cfg.resize_background and bg_transform ~= nil
            and planned_vfov ~= nil
            and not world_panel_drawn
            and (now - last_menu_scene_time) <= FADE_OUT_MAX_SECONDS
            and (now - last_menu_time) <= BUILTIN_PAUSE_SECONDS

        if want_resize then
            if bg_original_scale == nil then
                local sc = bg_transform:call("get_LocalScale")
                bg_original_scale = { x = sc.x, y = sc.y, z = sc.z }
            end
            -- The game sized the quad for the stock view at the current FOV;
            -- scale it by the ratio between the wide and the stock view.
            local stock_half = math.tan(math.rad(pre.fov) / 2.0) / aspect
            local wide_half = math.tan(math.rad(planned_vfov) / 2.0)
            local k = wide_half / stock_half * BACKGROUND_OVERSCAN
            bg_transform:call("set_LocalScale",
                Vector3f.new(bg_original_scale.x * k, bg_original_scale.y * k, bg_original_scale.z))
            bg_scaled = true
            bg_resize_count = bg_resize_count + 1
        else
            restore_background()
        end
    end)
end)

local function sorted_keys(set)
    local keys = {}
    for k, _ in pairs(set) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

local function write_diagnostics(note)
    local now = os.clock()
    local in_window = (now - math.max(last_menu_time, last_map_time)) < DIAG_WINDOW_SECONDS

    if in_window then
        local added, removed = {}, {}
        for name, _ in pairs(gui_now) do
            if not gui_prev[name] then added[#added + 1] = name end
        end
        for name, _ in pairs(gui_prev) do
            if not gui_now[name] then removed[#removed + 1] = name end
        end
        if #added > 0 or #removed > 0 then
            table.sort(added)
            table.sort(removed)
            log.info(string.format("[uwfix] f=%d t=%.3f gui+ [%s] gui- [%s]",
                frame_index, now, table.concat(added, ","), table.concat(removed, ",")))
            diag_lines = diag_lines + 1
        end
    end
    gui_prev = gui_now
    gui_now = {}

    local hidden = table.concat(sorted_keys(hidden_now), ",")
    hidden_now = {}

    if not in_window then
        menu_now = {}
        return
    end

    local cam = try(function() return sdk.get_primary_camera() end, nil)
    local fov_post, pos = -1, "?"
    if cam ~= nil then
        fov_post = try(function() return cam:call("get_FOV") end, -1)
        pos = try(function()
            local p = camera_position(cam)
            return string.format("%.2f,%.2f,%.2f", p.x, p.y, p.z)
        end, "?")
    end

    local signature = string.format(
        "menu=[%s] fov=%.2f>%.2f did=%s base=%s bg=%s hidden=[%s] pos=%s",
        table.concat(sorted_keys(menu_now), ","),
        pre and pre.fov or -1, fov_post, note,
        hold_base_fov and string.format("%.2f", hold_base_fov) or "-",
        bg_scaled and "resized" or "-", hidden, pos)
    menu_now = {}

    if signature ~= last_diag_signature then
        last_diag_signature = signature
        log.info(string.format("[uwfix] f=%d t=%.3f %s", frame_index, now, signature))
        diag_lines = diag_lines + 1
    end
end

-- Apply the planned FOV. Runs after REFramework's own fix for this frame.
local function apply_plan(cam, panels_on_screen)
    local fov = cam:call("get_FOV")
    local vert = cam:call("get_VerticalEnable")
    local builtin_active = vert or pre.vert or math.abs(fov - pre.fov) > 0.001

    if builtin_active then
        -- REFramework already set the wide view and will restore the camera
        -- itself. Only adjust the value, and only in vertical-FOV mode.
        if planned_vfov ~= nil and vert and not pre.vert and math.abs(planned_vfov - fov) >= 0.02 then
            cam:call("set_FOV", planned_vfov)
            held_count = held_count + 1
            return "builtin-held"
        end
        return "builtin"
    end

    if planned_vfov == nil then return "idle" end
    if (os.clock() - last_menu_time) > ACTIVE_WINDOW_SECONDS then return "idle" end
    if panels_on_screen then return "wait-panels" end

    cam:call("set_VerticalEnable", true)
    cam:call("set_FOV", planned_vfov)
    applied = { cam = cam, fov = fov, vert = vert }
    applied_count = applied_count + 1
    return "wide"
end

re.on_application_entry("LockScene", function()
    frame_index = frame_index + 1
    applied = nil
    world_panel_drawn_copy = world_panel_drawn
    world_panel_drawn = false
    if not cfg.enabled then return end

    local note = "off"
    local panels_on_screen = world_panel_drawn_copy

    if pre ~= nil and fix_enabled() then
        guarded(function()
            local cam = sdk.get_primary_camera()
            if cam == nil or cam:get_address() ~= pre.addr then
                note = "no-camera"
                return
            end
            note = apply_plan(cam, panels_on_screen)
        end)
    end

    if cfg.diagnostics then
        guarded(function() write_diagnostics(note) end)
    end
end)

-- Put the camera back before game logic runs again.
re.on_pre_application_entry("UnlockScene", function()
    if applied == nil then return end
    local a = applied
    applied = nil
    guarded(function()
        a.cam:call("set_FOV", a.fov)
        a.cam:call("set_VerticalEnable", a.vert)
    end)
end)

re.on_script_reset(function()
    restore_background()
end)

re.on_draw_ui(function()
    if imgui.tree_node("Ultrawide FOV snap fix") then
        local changed, value = imgui.checkbox("Enabled (master switch)", cfg.enabled)
        if changed then
            cfg.enabled = value
            if not value then reset_state() end
            save_config()
        end

        if not cfg.enabled then
            imgui.text("OFF: the script is doing nothing. This is plain REFramework.")
            imgui.text("Version " .. tostring(VERSION))
            imgui.tree_pop()
            return
        end

        changed, value = imgui.checkbox("Keep background during fade (resize it)", cfg.resize_background)
        if changed then
            cfg.resize_background = value
            if not value then restore_background() end
            save_config()
        end

        changed, value = imgui.checkbox("Steady FOV when the map opens and closes", cfg.steady_map_fov)
        if changed then
            cfg.steady_map_fov = value
            save_config()
        end

        changed, value = imgui.checkbox("Diagnostics (writes to REFramework log)", cfg.diagnostics)
        if changed then
            cfg.diagnostics = value
            save_config()
        end

        imgui.text("Version " .. tostring(VERSION))
        imgui.text("Frames corrected: " .. tostring(applied_count) .. ", FOV held steady: " .. tostring(held_count))
        imgui.text("Panels skipped: " .. tostring(hidden_count) .. ", background resizes: " .. tostring(bg_resize_count))
        if graphics == nil then
            imgui.text("Warning: could not reach REFramework's graphics module.")
        end
        if last_error ~= nil then
            imgui.text("Last error: " .. last_error)
        end

        imgui.tree_pop()
    end
end)

log.info("[uw_fov_snap_fix] loaded, version " .. tostring(VERSION))
