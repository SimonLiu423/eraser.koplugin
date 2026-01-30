--[[
    Eraser Plugin for KOReader

    Enables highlight deletion by holding the Eraser button and swiping over highlights,
    mimicking the behavior of a real eraser.

    How it works:
    1. Press and hold the Eraser button (hardware button on stylus-enabled devices)
    2. Touch and drag (with finger or stylus) over any highlights
    3. Highlights are deleted instantly and silently
    4. Release the button to return to normal interaction

    When the Eraser button is held, ALL touch gestures are blocked to create a dedicated
    "eraser mode" - this prevents accidental page turns, menu openings, or other interactions
    while erasing highlights.

    Note: Currently tested on Kobo devices (Libra Colour). Other devices with
    an Eraser button may work if KOReader intercepts the button's input event.
--]]

local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")

local Eraser = InputContainer:extend {
    name = "eraser",
    is_doc_only = true, -- Only active when a document is open
}

function Eraser:init()
    logger.info("========================================")
    logger.info("ERASER DIAGNOSTIC: init() called")
    logger.info("========================================")

    -- CRITICAL: Add plugin to ReaderUI widget tree so it receives ALL gesture events
    -- This ensures we catch gestures through BOTH touch zones AND ges_events system
    table.insert(self.ui, self)                -- Add to widget children for event propagation
    table.insert(self.ui.active_widgets, self) -- Always receive events even when hidden
    logger.info("ERASER DIAGNOSTIC: Added plugin to ReaderUI widget tree")

    self.ui.menu:registerToMainMenu(self)

    -- Track eraser button state
    self.eraser_active = false

    -- Track deleted highlights to prevent race conditions
    -- When rapidly deleting highlights, multiple pan events can try to delete the same highlight
    -- This set tracks what we've already deleted in this eraser session
    self.deleted_highlights = {}

    -- Define ges_events to catch gestures that might bypass touch zones
    -- This is especially important for edge gestures that open menus
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local full_screen_range = Geom:new {
        x = 0, y = 0,
        w = screen_width,
        h = screen_height,
    }

    self.ges_events = {
        -- Catch all swipe gestures (including edge swipes)
        EraserSwipe = {
            GestureRange:new {
                ges = "swipe",
                range = full_screen_range,
            }
        },
        -- Catch all pan gestures
        EraserPan = {
            GestureRange:new {
                ges = "pan",
                range = full_screen_range,
            }
        },
        -- Catch pan release
        EraserPanRelease = {
            GestureRange:new {
                ges = "pan_release",
                range = full_screen_range,
            }
        },
        -- Catch tap gestures
        EraserTap = {
            GestureRange:new {
                ges = "tap",
                range = full_screen_range,
            }
        },
        -- Catch double tap
        EraserDoubleTap = {
            GestureRange:new {
                ges = "double_tap",
                range = full_screen_range,
            }
        },
        -- Catch hold
        EraserHold = {
            GestureRange:new {
                ges = "hold",
                range = full_screen_range,
            }
        },
        -- Catch hold pan
        EraserHoldPan = {
            GestureRange:new {
                ges = "hold_pan",
                range = full_screen_range,
            }
        },
        -- Catch hold release
        EraserHoldRelease = {
            GestureRange:new {
                ges = "hold_release",
                range = full_screen_range,
            }
        },
        -- Catch pinch/spread
        EraserPinch = {
            GestureRange:new {
                ges = "pinch",
                range = full_screen_range,
            }
        },
        EraserSpread = {
            GestureRange:new {
                ges = "spread",
                range = full_screen_range,
            }
        },
    }

    logger.info("ERASER DIAGNOSTIC: Defined ges_events for", 10, "gesture types")

    -- Diagnostic: Check what self.ui is
    logger.info("ERASER DIAGNOSTIC: self.ui type =", type(self.ui))
    logger.info("ERASER DIAGNOSTIC: self.ui.name =", self.ui.name or "nil")
    logger.info("ERASER DIAGNOSTIC: self type =", type(self))
    logger.info("ERASER DIAGNOSTIC: self.name =", self.name or "nil")

    -- Diagnostic: Check if registerTouchZones exists
    logger.info("ERASER DIAGNOSTIC: self.ui.registerTouchZones =", type(self.ui.registerTouchZones))
    logger.info("ERASER DIAGNOSTIC: self.ui.registerPostReaderReadyCallback =",
        type(self.ui.registerPostReaderReadyCallback))

    -- Diagnostic: Verify plugin is now in event chain
    logger.info("ERASER DIAGNOSTIC: Verifying plugin is in ReaderUI widget tree...")
    local found_in_tree = false
    if self.ui and type(self.ui) == "table" then
        for i, widget in ipairs(self.ui) do
            if widget == self then
                found_in_tree = true
                logger.info("ERASER DIAGNOSTIC: Plugin found at ui[" .. i .. "]")
                break
            end
        end
    end
    if found_in_tree then
        logger.info("ERASER DIAGNOSTIC: SUCCESS - Plugin is in widget tree!")
    else
        logger.warn("ERASER DIAGNOSTIC: WARNING - Plugin still not found in widget tree!")
    end

    -- Register touch zones AFTER all reader modules complete initialization
    -- This ensures our overrides take precedence over reader module zones
    self.ui:registerPostReaderReadyCallback(function()
        logger.info("========================================")
        logger.info("ERASER DIAGNOSTIC: postReaderReadyCallback FIRED")
        logger.info("========================================")
        self:registerTouchZonesAndFooter()
    end)

    logger.info("ERASER DIAGNOSTIC: init() completed")
end

function Eraser:registerTouchZonesAndFooter()
    logger.info("========================================")
    logger.info("ERASER DIAGNOSTIC: registerTouchZonesAndFooter() called")
    logger.info("========================================")

    -- Register touch zones with overrides to intercept gestures BEFORE page navigation
    -- Called via postReaderReadyCallback to ensure we register AFTER all reader modules
    -- have completed their onReaderReady() processing, guaranteeing our overrides work

    local hold_pan_rate = G_reader_settings:readSetting("hold_pan_rate")
    if not hold_pan_rate then
        hold_pan_rate = Screen.low_pan_rate and 5.0 or 30.0
    end

    logger.info("ERASER DIAGNOSTIC: hold_pan_rate =", hold_pan_rate, "Hz")

    -- Full screen zone for all gestures
    local full_screen = {
        ratio_x = 0,
        ratio_y = 0,
        ratio_w = 1,
        ratio_h = 1,
    }

    -- List of touch zone IDs to override (intercept before they get the gesture)
    -- This ensures eraser mode blocks ALL interactions
    local zone_overrides = {
        -- Page navigation (PDF & EPUB)
        "paging_swipe", "paging_pan", "paging_pan_release",
        "rolling_swipe", "rolling_pan", "rolling_pan_release",
        "tap_forward", "tap_backward",

        -- Highlights
        "readerhighlight_tap", "readerhighlight_hold", "readerhighlight_swipe",

        -- Top menu (including edge swipes that open menus)
        "readermenu_tap", "readermenu_ext_tap",
        "readermenu_swipe", "readermenu_ext_swipe", -- Edge swipes to open menu
        "readermenu_pan", "readermenu_ext_pan",     -- Edge pans to open menu
        "tap_top_left_corner", "tap_top_right_corner",

        -- Bottom menu (config menu - edge swipes from bottom)
        "readerconfigmenu_tap", "readerconfigmenu_ext_tap",
        "readerconfigmenu_swipe", "readerconfigmenu_ext_swipe",
        "readerconfigmenu_pan", "readerconfigmenu_ext_pan",

        -- Footer
        "readerfooter_tap", "readerfooter_hold",

        -- Config panel
        "config_grip",

        -- Two-column mode
        "twocol_swipe", "twocol_pan",
    }

    logger.info("ERASER DIAGNOSTIC: zone_overrides list has", #zone_overrides, "items")

    -- Register touch zones for each gesture type
    local zones_to_register = {
        {
            id = "eraser_tap",
            ges = "tap",
            screen_zone = full_screen,
            overrides = zone_overrides,
            handler = function(ges) return self:handleEraserGesture(ges) end,
        },
        {
            id = "eraser_double_tap",
            ges = "double_tap",
            screen_zone = full_screen,
            overrides = zone_overrides,
            handler = function(ges) return self:handleEraserGesture(ges) end,
        },
        {
            id = "eraser_hold",
            ges = "hold",
            screen_zone = full_screen,
            overrides = zone_overrides,
            handler = function(ges) return self:handleEraserGesture(ges) end,
        },
        {
            id = "eraser_hold_pan",
            ges = "hold_pan",
            screen_zone = full_screen,
            rate = hold_pan_rate,
            overrides = zone_overrides,
            handler = function(ges) return self:handleEraserGesture(ges) end,
        },
        {
            id = "eraser_hold_release",
            ges = "hold_release",
            screen_zone = full_screen,
            overrides = zone_overrides,
            handler = function(ges) return self:handleEraserGesture(ges) end,
        },
        {
            id = "eraser_pan",
            ges = "pan",
            screen_zone = full_screen,
            rate = hold_pan_rate,
            overrides = zone_overrides,
            handler = function(ges) return self:handleEraserGesture(ges) end,
        },
        {
            id = "eraser_pan_release",
            ges = "pan_release",
            screen_zone = full_screen,
            overrides = zone_overrides,
            handler = function(ges) return self:handleEraserGesture(ges) end,
        },
        {
            id = "eraser_swipe",
            ges = "swipe",
            screen_zone = full_screen,
            overrides = zone_overrides,
            handler = function(ges) return self:handleEraserGesture(ges) end,
        },
        {
            id = "eraser_pinch",
            ges = "pinch",
            screen_zone = full_screen,
            overrides = zone_overrides,
            handler = function(ges) return self:handleEraserGesture(ges) end,
        },
        {
            id = "eraser_spread",
            ges = "spread",
            screen_zone = full_screen,
            overrides = zone_overrides,
            handler = function(ges) return self:handleEraserGesture(ges) end,
        },
    }

    logger.info("ERASER DIAGNOSTIC: About to register", #zones_to_register, "touch zones")
    logger.info("ERASER DIAGNOSTIC: Calling self.ui:registerTouchZones()...")

    self.ui:registerTouchZones(zones_to_register)

    logger.info("ERASER DIAGNOSTIC: registerTouchZones() call completed")

    -- Verify zones were registered
    logger.info("ERASER DIAGNOSTIC: Verifying zone registration...")
    if self.ui._zones then
        logger.info("ERASER DIAGNOSTIC: self.ui._zones exists")
        local eraser_zone_count = 0
        local all_zone_ids = {}
        for zone_id, _ in pairs(self.ui._zones) do
            table.insert(all_zone_ids, zone_id)
            if zone_id:match("^eraser_") then
                eraser_zone_count = eraser_zone_count + 1
                logger.info("ERASER DIAGNOSTIC: Found registered zone:", zone_id)
            end
        end
        logger.info("ERASER DIAGNOSTIC: Total eraser zones registered:", eraser_zone_count)
        logger.info("ERASER DIAGNOSTIC: Total zones in _zones:", #all_zone_ids)

        -- Log first 20 zone IDs to see what's registered
        logger.info("ERASER DIAGNOSTIC: Sample of all registered zone IDs:")
        for i = 1, math.min(20, #all_zone_ids) do
            logger.info("  - " .. all_zone_ids[i])
        end
    else
        logger.warn("ERASER DIAGNOSTIC: self.ui._zones is NIL!")
    end

    -- Check dependency graph
    if self.ui.touch_zone_dg then
        logger.info("ERASER DIAGNOSTIC: touch_zone_dg exists")
        local serialized = self.ui.touch_zone_dg:serialize()
        logger.info("ERASER DIAGNOSTIC: Serialized zone order has", #serialized, "zones")

        -- Find position of eraser zones in the order
        for i, zone_id in ipairs(serialized) do
            if zone_id:match("^eraser_") then
                logger.info("ERASER DIAGNOSTIC: Zone", zone_id, "is at position", i, "in processing order")
                -- Show what comes after it
                if i < #serialized then
                    logger.info("  Next zone:", serialized[i + 1])
                end
                if i > 1 then
                    logger.info("  Previous zone:", serialized[i - 1])
                end
                break -- Just log the first eraser zone's position
            end
        end
    else
        logger.warn("ERASER DIAGNOSTIC: touch_zone_dg is NIL!")
    end

    logger.info("ERASER DIAGNOSTIC: Touch zones registration verification complete")

    -- Register footer status indicator
    self:registerFooterIndicator()

    logger.info("ERASER DIAGNOSTIC: registerTouchZonesAndFooter() completed")
    logger.info("========================================")
end

function Eraser:registerFooterIndicator()
    -- Define footer content callback that returns eraser status
    self.footer_content_func = function()
        if self.eraser_active then
            -- Return eraser icon based on footer style preference
            if self.ui.view.footer.settings.item_prefix == "icons" then
                return "✏ " -- Pencil icon with space for icons mode
            elseif self.ui.view.footer.settings.item_prefix == "compact_items" then
                return "✏" -- Compact (no trailing space)
            else
                return "E" -- Letter prefix for text mode
            end
        end
        return nil -- Don't show anything when eraser is inactive
    end

    -- Register with footer (if it exists)
    if self.ui.view and self.ui.view.footer then
        self.ui.view.footer:addAdditionalFooterContent(self.footer_content_func)
    end
end

function Eraser:setEraserActive(active)
    -- Centralized state management with footer refresh
    if self.eraser_active == active then
        return -- No change, skip update
    end

    logger.info("Eraser: State changing from", self.eraser_active, "to", active)
    self.eraser_active = active

    -- Clear deleted highlights tracking when deactivating eraser mode
    if not active then
        self.deleted_highlights = {}
        logger.dbg("Eraser: Cleared deleted highlights tracking")
    end

    -- Trigger footer refresh to show/hide indicator
    UIManager:broadcastEvent(Event:new("RefreshAdditionalContent"))
end

function Eraser:handleEraserGesture(ges)
    -- Unified handler for all gestures when eraser mode is active
    -- Returns true to block the gesture, false/nil to pass through to normal handlers

    if not self.eraser_active then
        -- Eraser not active - let gesture pass through to normal handlers
        return false
    end

    -- Eraser is active - block ALL gestures to create dedicated "eraser mode"
    logger.dbg("Eraser: Blocking gesture", ges.ges, "in eraser mode")

    -- For gestures with position data, delete highlights at that position
    if ges.pos and (ges.ges == "pan" or ges.ges == "hold" or ges.ges == "hold_pan") then
        self:deleteHighlightsAtPosition(ges.pos)
    end

    -- Consume the gesture to prevent it from reaching other handlers
    return true
end

-- ges_events handlers - These catch gestures through the event system (not just touch zones)
-- This is critical for blocking edge gestures that open menus

function Eraser:onEraserSwipe(arg, ges)
    if self.eraser_active then
        logger.dbg("Eraser: Blocking swipe via ges_events")
        return true
    end
    return false
end

function Eraser:onEraserPan(arg, ges)
    if self.eraser_active then
        logger.dbg("Eraser: Blocking pan via ges_events")
        -- Delete highlights at pan position
        if ges and ges.pos then
            self:deleteHighlightsAtPosition(ges.pos)
        end
        return true
    end
    return false
end

function Eraser:onEraserPanRelease(arg, ges)
    if self.eraser_active then
        logger.dbg("Eraser: Blocking pan_release via ges_events")
        return true
    end
    return false
end

function Eraser:onEraserTap(arg, ges)
    if self.eraser_active then
        logger.dbg("Eraser: Blocking tap via ges_events")
        return true
    end
    return false
end

function Eraser:onEraserDoubleTap(arg, ges)
    if self.eraser_active then
        logger.dbg("Eraser: Blocking double_tap via ges_events")
        return true
    end
    return false
end

function Eraser:onEraserHold(arg, ges)
    if self.eraser_active then
        logger.dbg("Eraser: Blocking hold via ges_events")
        -- Delete highlights at hold position
        if ges and ges.pos then
            self:deleteHighlightsAtPosition(ges.pos)
        end
        return true
    end
    return false
end

function Eraser:onEraserHoldPan(arg, ges)
    if self.eraser_active then
        logger.dbg("Eraser: Blocking hold_pan via ges_events")
        -- Delete highlights at hold_pan position
        if ges and ges.pos then
            self:deleteHighlightsAtPosition(ges.pos)
        end
        return true
    end
    return false
end

function Eraser:onEraserHoldRelease(arg, ges)
    if self.eraser_active then
        logger.dbg("Eraser: Blocking hold_release via ges_events")
        return true
    end
    return false
end

function Eraser:onEraserPinch(arg, ges)
    if self.eraser_active then
        logger.dbg("Eraser: Blocking pinch via ges_events")
        return true
    end
    return false
end

function Eraser:onEraserSpread(arg, ges)
    if self.eraser_active then
        logger.dbg("Eraser: Blocking spread via ges_events")
        return true
    end
    return false
end

function Eraser:onKeyPress(key)
    -- Activate eraser mode when Eraser button is pressed
    if key.key == "Eraser" then
        logger.info("Eraser: Eraser button PRESSED - activating eraser mode")
        self:setEraserActive(true)
    end

    return false
end

function Eraser:onKeyRelease(key)
    -- Deactivate eraser mode when Eraser button is released
    if key.key == "Eraser" and self.eraser_active then
        logger.info("Eraser: Eraser button RELEASED - deactivating eraser mode")
        self:setEraserActive(false)
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

function Eraser:refreshVisibleBoxIndices(deleted_index)
    -- After deleting an annotation at deleted_index, all subsequent annotations
    -- shift down by 1 in the annotations array (due to table.remove).
    -- We need to:
    -- 1. REMOVE the deleted box from visible_boxes (its rect is now stale)
    -- 2. Update remaining boxes' indices to reflect the shift

    if not self.ui or not self.ui.highlight or not self.ui.highlight.view then
        logger.warn("Eraser: Cannot refresh indices - highlight view not available")
        return
    end

    local visible_boxes = self.ui.highlight.view.highlight.visible_boxes

    if not visible_boxes or #visible_boxes == 0 then
        logger.info("Eraser: No visible_boxes to refresh")
        return
    end

    -- Safety check: validate deleted_index is reasonable
    if not deleted_index or deleted_index < 1 then
        logger.warn("Eraser: Invalid deleted_index:", deleted_index)
        return
    end

    -- STEP 1: Remove ALL boxes that reference the deleted annotation
    -- Multi-line highlights create multiple boxes with the same index
    -- We must iterate backwards to safely remove items during iteration
    local removed_count = 0
    for i = #visible_boxes, 1, -1 do
        local box = visible_boxes[i]
        if box.index == deleted_index then
            table.remove(visible_boxes, i)
            removed_count = removed_count + 1
        end
    end

    if removed_count == 0 then
        logger.warn("Eraser: Could not find any boxes with index", deleted_index, "in visible_boxes")
    end

    -- STEP 2: Shift down indices for all boxes that point to annotations after the deleted one
    -- After table.remove in annotations array, all indices > deleted_index shift down by 1
    local shifted_count = 0
    for _, box in ipairs(visible_boxes) do
        if box.index and box.index > deleted_index then
            box.index = box.index - 1
            shifted_count = shifted_count + 1
        end
    end

    logger.dbg("Eraser: Refreshed visible_boxes - removed:", removed_count, "boxes, shifted:", shifted_count, "boxes")
end

function Eraser:deleteHighlightsAtPosition(pos)
    -- Delete highlights at the given screen position
    -- Uses deleted_highlights tracking to prevent race conditions when multiple pan events
    -- try to delete the same highlight rapidly

    if not self.ui or not self.ui.highlight or not self.ui.highlight.view then
        return false
    end

    local highlight_module = self.ui.highlight
    local visible_boxes = highlight_module.view.highlight.visible_boxes

    if not visible_boxes or #visible_boxes == 0 then
        return false
    end

    -- Validate that annotation system is available
    if not self.ui.annotation or not self.ui.annotation.annotations then
        logger.warn("Eraser: Annotation system not available")
        return false
    end

    -- Transform screen coordinates to page coordinates
    local page_pos = highlight_module.view:screenToPageTransform(pos)
    local deleted_any = false

    for _, box in ipairs(visible_boxes) do
        if self:inside_box(page_pos, box.rect) then
            -- Get the full annotation object to access datetime
            -- box only contains: index, rect, drawer, color, draw_mark, colorful
            -- The datetime field is in the annotation object, not in box
            local annotation = self.ui.annotation.annotations[box.index]

            if not annotation then
                logger.warn("Eraser: No annotation found for box index", box.index)
                goto continue
            end

            -- Use datetime as unique identifier - this is what KOReader uses internally
            -- in getMatchFunc() for identifying highlights uniquely
            local highlight_id = annotation.datetime

            if not highlight_id then
                -- Fallback: if datetime is missing (should never happen), create ID from index + page
                -- This is more unique than position-based ID
                highlight_id = string.format("idx_%d_page_%s",
                    box.index,
                    tostring(annotation.page or annotation.pageno or "unknown"))
                logger.dbg("Eraser: No datetime found for highlight, using fallback ID:", highlight_id)
            end

            -- Skip if we already deleted this highlight in this eraser session
            if not self.deleted_highlights[highlight_id] then
                -- Mark as deleted BEFORE attempting deletion to prevent race conditions
                self.deleted_highlights[highlight_id] = true

                -- CRITICAL: Store the index BEFORE deletion because it will be used
                -- to update visible_boxes after the deletion shifts the annotations array
                local deleted_index = box.index

                -- Wrap deletion in pcall for safety - protects against index becoming invalid
                -- between when we check inside_box and when we actually delete
                local success, err = pcall(function()
                    highlight_module:deleteHighlight(deleted_index)
                end)

                if success then
                    logger.info("Eraser: Deleted highlight at index", deleted_index)
                    deleted_any = true

                    -- CRITICAL: Remove ALL boxes for deleted annotation and update remaining indices
                    -- Multi-line highlights create multiple boxes with same index
                    -- After table.remove() in removeItemByIndex(), all annotations after
                    -- deleted_index shift down by 1. We must update visible_boxes to match.
                    self:refreshVisibleBoxIndices(deleted_index)
                else
                    -- If deletion failed, remove from tracking so user can try again
                    self.deleted_highlights[highlight_id] = nil
                    logger.warn("Eraser: Failed to delete highlight at index", deleted_index, ":", tostring(err))
                end
            else
                logger.dbg("Eraser: Skipping already-deleted highlight:", highlight_id)
            end

            ::continue::
        end
    end

    if deleted_any then
        UIManager:setDirty(self.ui.dialog, "ui")
    end
end

function Eraser:onSuspend()
    -- Deactivate on suspend to prevent stuck state if button is held during sleep
    if self.eraser_active then
        logger.info("Eraser: Deactivated eraser mode on suspend")
        self:setEraserActive(false)
    end
end

function Eraser:onResume()
    -- Ensure inactive state on resume
    self:setEraserActive(false)
end

function Eraser:onShowConfigMenu()
    -- Safety: Reset eraser state when config menu opens
    -- This event is broadcast when EITHER top or bottom menu opens
    -- This prevents stuck state if the menu consumes our KeyRelease event
    if self.eraser_active then
        logger.warn("Eraser: Menu opened while eraser active - auto-resetting state for safety")
        self:setEraserActive(false)
    end
    return false -- Don't consume - let menu open normally
end

function Eraser:onCloseDocument()
    -- Clean up when document is closed
    self:setEraserActive(false)

    -- Unregister footer content
    if self.ui.view and self.ui.view.footer and self.footer_content_func then
        self.ui.view.footer:removeAdditionalFooterContent(self.footer_content_func)
        self.footer_content_func = nil
    end
end

return Eraser
