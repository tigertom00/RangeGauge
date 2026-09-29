-- RangeGauge: a small target-range indicator for WoW: Forever beta (interface 16001).
--
-- Forever runs the modern Mainline API, not the vanilla 1.12 API that older range
-- checkers (e.g. Egnar on Turtle WoW) had to work around with class-specific tricks
-- like watching a hunter's Wing Clip cooldown on a hardcoded action bar slot.
-- Here CheckInteractDistance and C_Spell.IsSpellInRange return plain (non-secret)
-- values against a hostile target, so we can just ask the API directly.
--
-- Known beta limitation (as of build ~1.60.1.700xx): C_SwingTimer.IsTargetWithinSwingRange
-- always returns nil, so there is no exact 5-yard melee check. We approximate melee
-- with the closest available interact-distance bucket (duel range, ~9.9 yd) and
-- confirm real melee contact from PLAYER_SWING events when they fire.

local UPDATE_INTERVAL = 0.2

-- Auto Shot's spell ID is stable across WoW versions. On this beta it has been
-- confirmed to report a real 8-35 yard range (including the vanilla dead zone),
-- so Hunters get an exact read instead of the generic bucket fallback.
local AUTO_SHOT_SPELL_ID = 75

-- CheckInteractDistance bucket indices (unchanged from Classic/Retail):
local INTERACT_DUEL = 3    -- ~9.9 yd  -- closest bucket to true melee range
local INTERACT_TRADE = 2   -- ~11.11 yd
local INTERACT_INSPECT = 1 -- ~28 yd

local _, playerClass = UnitClass("player")

local userSpellID = nil -- set with /rg spell <name or id> for a precise class-specific check

local lastMainHandSwing = 0
local mainHandSwingDuration = 0

-- Registering an event the client doesn't know about throws and aborts the whole
-- file on this beta, so anything not rock-solid goes through pcall.
local function SafeRegisterEvent(f, event)
    pcall(f.RegisterEvent, f, event)
end

local DEFAULT_DB = {
    point = "CENTER",
    relPoint = "CENTER",
    x = 0,
    y = -150,
    width = 150,
    height = 34,
    locked = false,
    spellID = nil,
    colorMode = "text", -- "text" or "bg"
}

local colorMode = DEFAULT_DB.colorMode

local frame = CreateFrame("Frame", "RangeGaugeFrame", UIParent, "BackdropTemplate")
frame:SetSize(150, 34)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    RangeGaugeDB.point, RangeGaugeDB.relPoint, RangeGaugeDB.x, RangeGaugeDB.y = point, relPoint, x, y
end)
frame:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
frame:SetBackdropColor(0, 0, 0, 0.6)

local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
text:SetPoint("CENTER")
frame.text = text

local function SetState(label, r, g, b)
    text:SetText(label)
    if colorMode == "bg" then
        text:SetTextColor(1, 1, 1)
        frame:SetBackdropColor(r, g, b, 0.85)
    else
        text:SetTextColor(r, g, b)
        frame:SetBackdropColor(0, 0, 0, 0.6)
    end
end

-- Resize grip, bottom-right corner. Only usable while the frame is unlocked.
frame:SetResizable(true)
if frame.SetResizeBounds then
    frame:SetResizeBounds(80, 24, 400, 120) -- modern API (retail 10.x+)
else
    frame:SetMinResize(80, 24) -- fallback for older API shape, just in case
    frame:SetMaxResize(400, 120)
end

local resizer = CreateFrame("Button", nil, frame)
resizer:SetSize(16, 16)
resizer:SetPoint("BOTTOMRIGHT", -2, 2)
resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
resizer:SetScript("OnMouseDown", function()
    frame:StartSizing("BOTTOMRIGHT")
end)
resizer:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    RangeGaugeDB.width, RangeGaugeDB.height = frame:GetSize()
end)

local function SetLocked(locked)
    frame:EnableMouse(not locked)
    if locked then
        resizer:Hide()
    else
        resizer:Show()
    end
end

-- Track real melee contact via PLAYER_SWING, since C_SwingTimer's range check
-- is currently non-functional on this build (EnableRangeCheck succeeds but
-- IsTargetWithinSwingRange always returns nil).
local swingFrame = CreateFrame("Frame")
SafeRegisterEvent(swingFrame, "PLAYER_SWING")
swingFrame:SetScript("OnEvent", function(_, event, duration, swingType)
    if event == "PLAYER_SWING" and swingType == Enum.PlayerSwingType.MainHand then
        lastMainHandSwing = GetTime()
        mainHandSwingDuration = duration or mainHandSwingDuration
    end
end)

local function RecentMainHandSwing()
    if mainHandSwingDuration <= 0 then
        return false
    end
    return (GetTime() - lastMainHandSwing) < mainHandSwingDuration
end

local function Update()
    if not UnitExists("target") then
        frame:Hide()
        return
    end
    frame:Show()

    if UnitIsDead("target") then
        SetState("Target Dead", 0.6, 0.6, 0.6)
        return
    end

    -- Hunters: Auto Shot gives a real 8-35 yd read with dead-zone detection.
    if playerClass == "HUNTER" then
        local inRange = C_Spell.IsSpellInRange(AUTO_SHOT_SPELL_ID, "target")
        if inRange == false then
            if CheckInteractDistance("target", INTERACT_DUEL) then
                SetState("DEAD ZONE", 1, 0.5, 0)
            else
                SetState("Out of Range", 1, 0.2, 0.2)
            end
            return
        elseif inRange == true then
            SetState("In Range", 0.2, 1, 0.2)
            return
        end
        -- inRange == nil (e.g. spell not usable right now): fall through below.
    end

    -- Optional user-picked spell for a precise, class-specific range check.
    if userSpellID then
        local inRange = C_Spell.IsSpellInRange(userSpellID, "target")
        if inRange ~= nil then
            if inRange then
                SetState("In Range", 0.2, 1, 0.2)
            else
                SetState("Out of Range", 1, 0.2, 0.2)
            end
            return
        end
    end

    -- Generic fallback: interact-distance buckets, melee confirmed by real swings.
    -- Note: 0-range melee abilities report "in range" at any distance on this
    -- build, so they are deliberately not used here.
    if RecentMainHandSwing() or CheckInteractDistance("target", INTERACT_DUEL) then
        SetState("Melee", 0.2, 1, 0.2)
    elseif CheckInteractDistance("target", INTERACT_TRADE) then
        SetState("Close", 1, 1, 0.2)
    elseif CheckInteractDistance("target", INTERACT_INSPECT) then
        SetState("Spell Range", 0.4, 0.8, 1)
    else
        SetState("Out of Range", 1, 0.2, 0.2)
    end
end

local elapsedSince = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    elapsedSince = elapsedSince + elapsed
    if elapsedSince >= UPDATE_INTERVAL then
        elapsedSince = 0
        Update()
    end
end)

local targetEvents = CreateFrame("Frame")
SafeRegisterEvent(targetEvents, "PLAYER_TARGET_CHANGED")
targetEvents:SetScript("OnEvent", Update)

local loadFrame = CreateFrame("Frame")
SafeRegisterEvent(loadFrame, "ADDON_LOADED")
loadFrame:SetScript("OnEvent", function(_, event, addonName)
    if event ~= "ADDON_LOADED" or addonName ~= "RangeGauge" then
        return
    end
    RangeGaugeDB = RangeGaugeDB or {}
    for key, value in pairs(DEFAULT_DB) do
        if RangeGaugeDB[key] == nil then
            RangeGaugeDB[key] = value
        end
    end

    frame:ClearAllPoints()
    frame:SetPoint(RangeGaugeDB.point, UIParent, RangeGaugeDB.relPoint, RangeGaugeDB.x, RangeGaugeDB.y)
    frame:SetSize(RangeGaugeDB.width, RangeGaugeDB.height)
    SetLocked(RangeGaugeDB.locked)
    userSpellID = RangeGaugeDB.spellID
    colorMode = RangeGaugeDB.colorMode

    loadFrame:UnregisterEvent("ADDON_LOADED")
end)

SLASH_RANGEGAUGE1 = "/rg"
SLASH_RANGEGAUGE2 = "/rangegauge"
SlashCmdList["RANGEGAUGE"] = function(msg)
    msg = (msg or ""):trim()
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if cmd == "spell" and rest ~= "" then
        local spellID = tonumber(rest)
        local info = C_Spell.GetSpellInfo(spellID or rest)
        if info and info.spellID then
            userSpellID = info.spellID
            RangeGaugeDB.spellID = info.spellID
            print("|cff33ff99RangeGauge|r: tracking range for '" .. info.name .. "' (id " .. info.spellID .. ")")
        else
            print("|cff33ff99RangeGauge|r: couldn't find a spell named or numbered '" .. rest .. "'")
        end
    elseif cmd == "clear" then
        userSpellID = nil
        RangeGaugeDB.spellID = nil
        print("|cff33ff99RangeGauge|r: cleared custom spell, using generic range detection")
    elseif cmd == "lock" then
        SetLocked(true)
        RangeGaugeDB.locked = true
        print("|cff33ff99RangeGauge|r: frame locked")
    elseif cmd == "unlock" then
        SetLocked(false)
        RangeGaugeDB.locked = false
        print("|cff33ff99RangeGauge|r: frame unlocked, drag it to move, or drag the bottom-right corner to resize")
    elseif cmd == "colormode" then
        if rest == "bg" or rest == "background" then
            colorMode = "bg"
            RangeGaugeDB.colorMode = "bg"
            print("|cff33ff99RangeGauge|r: colored background mode")
        elseif rest == "text" then
            colorMode = "text"
            RangeGaugeDB.colorMode = "text"
            print("|cff33ff99RangeGauge|r: colored text mode")
        else
            print("|cff33ff99RangeGauge|r: usage /rg colormode text|bg (currently '" .. colorMode .. "')")
        end
        Update()
    else
        print("|cff33ff99RangeGauge|r commands: /rg spell <name or id>, /rg clear, /rg lock, /rg unlock, /rg colormode text|bg")
    end
end

Update()
