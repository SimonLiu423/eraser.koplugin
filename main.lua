--[[
    Eraser Plugin for KOReader

    Enables highlight deletion by holding the Eraser button and swiping over highlights,
    mimicking the behavior of a real eraser.

    How it works:
    1. Press and hold the Eraser button (hardware button on stylus-enabled devices)
    2. Touch and drag (with finger or stylus) over any highlights
    3. Highlights are deleted instantly and silently
    4. Release the button to return to normal interaction

    Note: Currently tested on Kobo devices (Libra Colour). Other devices with
    an Eraser button may work if KOReader intercepts the button's input event.
--]]

local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")
local Screen = require("device").screen

local Eraser = InputContainer:extend {
    name = "eraser",
    is_doc_only = true, -- Only active when a document is open
}

function Eraser:init()
    self.ui.menu:registerToMainMenu(self)

    -- Track eraser button state
    self.eraser_active = false

    -- Register gesture events to intercept touch input when eraser is active
    -- Supports both instant drag (pan) and long-press drag (hold/hold_pan)
    local hold_pan_rate = G_reader_settings:readSetting("hold_pan_rate")
    if not hold_pan_rate then
        hold_pan_rate = Screen.low_pan_rate and 5.0 or 30.0
    end

    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    local full_screen_range = Geom:new {
        x = 0, y = 0,
        w = screen_width,
        h = screen_height,
    }

    -- Register gesture handlers (full screen range)
    -- - hold: long-press detection
    -- - hold_pan: long-press + drag
    -- - pan: instant drag without long-press
    self.ges_events = {
        EraserHold = {
            GestureRange:new {
                ges = "hold",
                range = full_screen_range,
            }
        },
        EraserHoldPan = {
            GestureRange:new {
                ges = "hold_pan",
                range = full_screen_range,
                rate = hold_pan_rate,
            }
        },
        EraserPan = {
            GestureRange:new {
                ges = "pan",
                range = full_screen_range,
                rate = hold_pan_rate,
            }
        },
    }

    logger.dbg("Eraser: Plugin initialized with gesture events (hold_pan_rate:", hold_pan_rate, "Hz)")
end

function Eraser:onKeyPress(key)
    -- Activate eraser mode when Eraser button is pressed
    if key.key == "Eraser" then
        logger.dbg("Eraser: Eraser button PRESSED - activating eraser mode")
        self.eraser_active = true
    end

    return false
end

function Eraser:onKeyRelease(key)
    -- Deactivate eraser mode when Eraser button is released
    if key.key == "Eraser" and self.eraser_active then
        logger.dbg("Eraser: Eraser button RELEASED - deactivating eraser mode")
        self.eraser_active = false
        return true
    end

    return false
end

function Eraser:inside_box(pos, box)
    if not pos then return false end
    local x, y = pos.x, pos.y
    return box.x <= x and box.y <= y
        and box.x + box.w >= x
        and box.y + box.h >= y
end

function Eraser:deleteHighlightsAtPosition(pos)
    -- Delete highlights at the given screen position
    if not self.ui or not self.ui.highlight or not self.ui.highlight.view then
        return false
    end

    local highlight_module = self.ui.highlight
    local visible_boxes = highlight_module.view.highlight.visible_boxes

    if not visible_boxes or #visible_boxes == 0 then
        return false
    end

    -- Transform screen coordinates to page coordinates
    local page_pos = highlight_module.view:screenToPageTransform(pos)
    local deleted_any = false

    for _, box in ipairs(visible_boxes) do
        if self:inside_box(page_pos, box.rect) then
            logger.dbg("Eraser: Deleting highlight at index", box.index)
            highlight_module:deleteHighlight(box.index)
            deleted_any = true
        end
    end

    if deleted_any then
        UIManager:setDirty(self.ui.dialog, "ui")
    end
end

function Eraser:onEraserHold(arg, ges)
    -- Delete highlights on long-press when eraser is active
    if self.eraser_active then
        logger.dbg("Eraser: Processing hold in eraser mode at pos:", ges.pos)
        if ges and ges.pos then
            self:deleteHighlightsAtPosition(ges.pos)
        end
        return true
    end

    return false
end

function Eraser:onEraserHoldPan(arg, ges)
    -- Delete highlights continuously during long-press drag
    if self.eraser_active then
        logger.dbg("Eraser: Processing hold-pan in eraser mode at pos:", ges.pos)
        if ges and ges.pos then
            self:deleteHighlightsAtPosition(ges.pos)
        end
        return true
    end
    return false
end

function Eraser:onEraserPan(arg, ges)
    -- Delete highlights during instant drag (no long-press required)
    if self.eraser_active then
        if ges and ges.pos then
            self:deleteHighlightsAtPosition(ges.pos)
        end
        return true
    end
    return false
end

function Eraser:onSuspend()
    -- Deactivate on suspend to prevent stuck state if button is held during sleep
    if self.eraser_active then
        self.eraser_active = false
        logger.dbg("Eraser: Deactivated eraser mode on suspend")
    end
end

function Eraser:onResume()
    -- Ensure inactive state on resume
    self.eraser_active = false
end

return Eraser
