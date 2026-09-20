local ADDON_NAME = "AutoGossipSelect"

local enabled = true
local cinematicSkipEnabled = true
local busy = false

-- Lorewalking reminder
local lorewalkingSoundEnabled = true
local lorewalkingSoundDelay = 67
local lorewalkingTimer = nil
local lorewalkingSecondsRemaining = 0

-- XP/hour display
local xpDisplayEnabled = true
local xpSamples = {}
local xpCurrentXP = nil
local xpCurrentMaxXP = nil
local xpLevel = nil

-- Explicit text matches.
local PRIORITY = {
    "lorewalking",
    "teleport",
}

local QUEST_TEXTS = {
    "time to leave!",
    "tell me",
    "what now?",
}

local function Msg(text)
    print("|cff00ccff[AutoGossipSelect]|r " .. tostring(text))
end

local function Normalize(text)
    if not text then
        return ""
    end

    text = tostring(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    return text:lower()
end

-- Use a timer API that is available in current WoW clients.
local function Now()
    if GetTime then
        return GetTime()
    end
    if GetTimePreciseSec then
        return GetTimePreciseSec()
    end
    return time()
end

----------------------------------------------------------------
-- STATIC LOREWALKING INSTRUCTIONS
----------------------------------------------------------------

local progressionSteps = {
    "Click the \"Loa\" option",
    "Click Li Li after notification",
    "Click Li Li Stormstout",
    "Exit bench, then accept \"The Warpack\" quest",
    "Leave Lorewalking",
    "Click Li Li, then continue \"Loa\" story, then click Li Li again",
    "Turn in the Warpack, and pick up \"Heretics\" and \"The Full Prophecy\"",
    "Turn in \"Heretics\" and \"The Full Prophecy\", then accept \"City of Gold\"",
    "Turn in \"City of Gold\" and accept \"The King's Gambit\"",
    "Go through the gate and speak to King Rastakhan, twice, then head upstairs to the right",
    "Speak to Li Li Stormstout and accept \"Lorewalking: Death of Drakkari\"",
    "Accept To Speak With Har'koa",
    "Fly to Har'koa",
    "Leave lorewalking and start over",
}

----------------------------------------------------------------
-- STATIC INSTRUCTION LIST WINDOW
----------------------------------------------------------------

local instructionFrame = CreateFrame(
    "Frame",
    "AutoGossipSelectInstructionFrame",
    UIParent,
    "BackdropTemplate"
)

instructionFrame:SetSize(560, 430)
instructionFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
instructionFrame:SetMovable(true)
instructionFrame:EnableMouse(true)
instructionFrame:RegisterForDrag("LeftButton")
instructionFrame:SetClampedToScreen(true)
instructionFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})

instructionFrame:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)

instructionFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
end)

instructionFrame.compactButton = CreateFrame(
    "Button", nil, instructionFrame, "UIPanelButtonTemplate"
)
instructionFrame.compactButton:SetSize(110, 22)
instructionFrame.compactButton:SetPoint("TOPLEFT", 18, -10)
instructionFrame.compactButton:SetText("Compact")

instructionFrame.timerText = instructionFrame:CreateFontString(
    nil, "OVERLAY", "GameFontNormal"
)
instructionFrame.timerText:SetPoint("LEFT", instructionFrame.compactButton, "RIGHT", 14, 0)
instructionFrame.timerText:SetText("")
instructionFrame.timerText:Hide()

local function UpdateLorewalkingTimerDisplay()
    if lorewalkingTimer and lorewalkingSecondsRemaining > 0 then
        instructionFrame.timerText:SetText(
            string.format("Sound in: %ds", lorewalkingSecondsRemaining)
        )
        instructionFrame.timerText:Show()
    else
        instructionFrame.timerText:SetText("")
        instructionFrame.timerText:Hide()
    end
end

instructionFrame.content = CreateFrame(
    "Frame",
    "AutoGossipSelectInstructionContent",
    instructionFrame
)

instructionFrame.content:SetPoint("TOPLEFT", 18, -48)
instructionFrame.content:SetWidth(524)

instructionFrame.stepLines = {}

local instructionY = 0

for i, step in ipairs(progressionSteps) do
    local line = instructionFrame.content:CreateFontString(
        nil, "OVERLAY", "GameFontHighlight"
    )

    line:SetPoint("TOPLEFT", 4, -instructionY)
    line:SetWidth(516)
    line:SetJustifyH("LEFT")
    line:SetWordWrap(true)
    line:SetText(string.format("%d. %s", i, tostring(step)))

    instructionFrame.stepLines[i] = line

    -- Measure the wrapped text so every line gets enough vertical space.
    local lineHeight = line:GetStringHeight()
    instructionY = instructionY + math.max(28, lineHeight + 8)
end

instructionFrame.content:SetHeight(math.max(1, instructionY))

instructionFrame.closeButton = CreateFrame(
    "Button", nil, instructionFrame, "UIPanelCloseButton"
)
instructionFrame.closeButton:SetPoint("TOPRIGHT", -4, -4)

local compactMode = false
local UpdateXPDisplay

local function ShowInstructionList()
    instructionFrame:Show()
end

local function HideInstructionList()
    instructionFrame:Hide()
end

local function ToggleInstructionList()
    if instructionFrame:IsShown() then
        HideInstructionList()
    else
        ShowInstructionList()
    end
end

----------------------------------------------------------------
-- MINIMAP BUTTON
----------------------------------------------------------------

local minimapButton = CreateFrame(
    "Button",
    "AutoGossipSelectMinimapButton",
    Minimap
)

minimapButton:SetSize(31, 31)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(Minimap:GetFrameLevel() + 8)

-- Make the button orbit outside the minimap edge like the surrounding buttons.
local minimapButtonAngle = math.rad(220)
local minimapButtonRadius = 108

local function UpdateMinimapButtonPosition()
    local angle = minimapButtonAngle
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint(
        "CENTER", Minimap, "CENTER",
        math.cos(angle) * minimapButtonRadius,
        math.sin(angle) * minimapButtonRadius
    )
end

UpdateMinimapButtonPosition()

minimapButton:SetMovable(true)
minimapButton:RegisterForDrag("LeftButton")
minimapButton:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function(button)
        local mx, my = Minimap:GetCenter()
        local bx, by = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        bx, by = bx / scale, by / scale
        minimapButtonAngle = math.atan2(by - my, bx - mx)
        UpdateMinimapButtonPosition()
    end)
end)

minimapButton:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

-- Clean circular minimap icon.
-- Do not crop MiniMap-TrackingBorder: it is not a simple standalone ring.
minimapButton.icon = minimapButton:CreateTexture(nil, "ARTWORK")
minimapButton.icon:SetSize(22, 22)
minimapButton.icon:SetPoint("CENTER", 0, 0)
minimapButton.icon:SetTexture("Interface\\Icons\\INV_Misc_Book_11")
minimapButton.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

-- Circularly mask the square inventory icon.
minimapButton.iconMask = minimapButton:CreateMaskTexture()
minimapButton.iconMask:SetAllPoints(minimapButton.icon)
minimapButton.iconMask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
minimapButton.icon:AddMaskTexture(minimapButton.iconMask)

-- Simple Blizzard minimap-style ring. Use the full texture without atlas cropping.
minimapButton.border = minimapButton:CreateTexture(nil, "OVERLAY")
minimapButton.border:SetSize(31, 31)
minimapButton.border:SetPoint("CENTER", 0, 0)
minimapButton.border:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
minimapButton.border:SetBlendMode("ADD")
minimapButton.border:SetAlpha(0.55)

-- Stronger highlight only while hovering.
minimapButton.highlight = minimapButton:CreateTexture(nil, "HIGHLIGHT")
minimapButton.highlight:SetSize(31, 31)
minimapButton.highlight:SetPoint("CENTER", 0, 0)
minimapButton.highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
minimapButton.highlight:SetBlendMode("ADD")

-- Right-click addon options menu.
local minimapMenu = CreateFrame("Frame", "AutoGossipSelectMinimapMenu", UIParent, "BackdropTemplate")
minimapMenu:SetSize(210, 270)
minimapMenu:SetFrameStrata("DIALOG")
minimapMenu:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
minimapMenu:Hide()

local function AddMinimapMenuButton(text, onClick)
    local button = CreateFrame("Button", nil, minimapMenu, "UIPanelButtonTemplate")
    button:SetSize(180, 28)
    button:SetText(text)
    button:SetScript("OnClick", function()
        onClick()
        minimapMenu:Hide()
    end)
    return button
end

local menuTitle = minimapMenu:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
menuTitle:SetPoint("TOP", 0, -12)
menuTitle:SetText("AutoGossipSelect")

local menuButtons = {}
local function RefreshMinimapMenu()
    for _, button in ipairs(menuButtons) do
        button:Hide()
    end
    menuButtons = {}

    local function Add(text, action)
        local button = AddMinimapMenuButton(text, action)
        button:SetPoint("TOP", 0, -42 - (#menuButtons * 31))
        menuButtons[#menuButtons + 1] = button
    end

    Add("Auto Select: " .. (enabled and "ON" or "OFF"), function()
        enabled = not enabled
        if not enabled and lorewalkingTimer then
            lorewalkingTimer:Cancel()
            lorewalkingTimer = nil
            lorewalkingSecondsRemaining = 0
            UpdateLorewalkingTimerDisplay()
        end
        Msg("Auto select: " .. (enabled and "ON" or "OFF"))
    end)

    Add("XP/hr Display: " .. (xpDisplayEnabled and "ON" or "OFF"), function()
        xpDisplayEnabled = not xpDisplayEnabled
        UpdateXPDisplay()
        Msg("XP/hr display: " .. (xpDisplayEnabled and "ON" or "OFF"))
    end)

    Add("Cinematic Skip: " .. (cinematicSkipEnabled and "ON" or "OFF"), function()
        cinematicSkipEnabled = not cinematicSkipEnabled
        Msg("Cinematic auto-skip: " .. (cinematicSkipEnabled and "ON" or "OFF"))
    end)

    Add("Reminder Sound: " .. (lorewalkingSoundEnabled and "ON" or "OFF"), function()
        lorewalkingSoundEnabled = not lorewalkingSoundEnabled
        if not lorewalkingSoundEnabled and lorewalkingTimer then
            lorewalkingTimer:Cancel()
            lorewalkingTimer = nil
            lorewalkingSecondsRemaining = 0
            UpdateLorewalkingTimerDisplay()
        end
        Msg("Lorewalking reminder sound: " .. (lorewalkingSoundEnabled and "ON" or "OFF"))
    end)

    Add("Reset XP/hr", function()
        StartXPTracking()
        Msg("XP/hr tracking reset.")
    end)

    Add("Instructions", function()
        ShowInstructionList()
    end)
end

local function ToggleMinimapMenu()
    if minimapMenu:IsShown() then
        minimapMenu:Hide()
        return
    end

    RefreshMinimapMenu()
    minimapMenu:ClearAllPoints()
    minimapMenu:SetPoint("TOPRIGHT", minimapButton, "BOTTOMLEFT", -4, -4)
    minimapMenu:Show()
end

minimapButton:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        ToggleMinimapMenu()
    else
        ToggleInstructionList()
    end
end)
minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")

minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("AutoGossipSelect")
    GameTooltip:AddLine(
        instructionFrame:IsShown()
            and "Click to hide instructions"
            or "Click to show instructions",
        1, 1, 1
    )
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

----------------------------------------------------------------
-- XP / HOUR
----------------------------------------------------------------

local xpFrame = CreateFrame(
    "Frame",
    "AutoGossipSelectXPFrame",
    instructionFrame
)

xpFrame:SetSize(120, 24)
xpFrame:SetPoint("TOPRIGHT", instructionFrame, "TOPRIGHT", -48, -14)
xpFrame:EnableMouse(true)

xpFrame.text = xpFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
xpFrame.text:SetPoint("CENTER")
xpFrame.text:SetTextColor(1, 1, 1, 1)
xpFrame.text:SetText("XP/hr: --")

local function SetCompactMode(compact)
    compactMode = compact and true or false

    if compactMode then
        -- Title replaced by compact/instructions button
        instructionFrame.content:Hide()
        instructionFrame.compactButton:SetText("Instructions")

        instructionFrame:SetSize(190, 90)

        xpFrame:ClearAllPoints()
        xpFrame:SetPoint("CENTER", instructionFrame, "CENTER", 0, 0)
        xpFrame:SetSize(170, 30)
    else
        -- Title replaced by compact/instructions button
        instructionFrame.content:Show()
        instructionFrame.compactButton:SetText("Compact")

        instructionFrame:SetSize(
            560,
            math.min(760, instructionFrame.content:GetHeight() + 76)
        )

        xpFrame:ClearAllPoints()
        xpFrame:SetPoint("TOPRIGHT", instructionFrame, "TOPRIGHT", -48, -14)
        xpFrame:SetSize(120, 24)
    end

    UpdateXPDisplay()
end

instructionFrame.compactButton:SetScript("OnClick", function()
    SetCompactMode(not compactMode)
end)

-- Keep the instruction window hidden when the addon loads.
-- It can be opened with /ags instructions or the minimap button.
instructionFrame:Hide()

local StartXPTracking

local xpResetButton = CreateFrame(
    "Button",
    "AutoGossipSelectXPResetButton",
    xpFrame,
    "UIPanelButtonTemplate"
)

xpResetButton:SetSize(90, 22)
xpResetButton:SetPoint("TOP", xpFrame, "BOTTOM", 0, -4)
xpResetButton:SetText("Reset XP")
xpResetButton:Hide()

xpResetButton:SetScript("OnClick", function()
    StartXPTracking()
    xpResetButton:Hide()
    Msg("XP/hr tracking reset.")
end)

xpFrame:SetScript("OnMouseDown", function()
    xpResetButton:SetShown(not xpResetButton:IsShown())
end)

-- Use a rolling window instead of lifetime XP since login.
local XP_WINDOW_SECONDS = 300
local XP_MIN_SAMPLE_SECONDS = 30

local function AddXPSample(timestamp, amount)
    if amount and amount > 0 then
        xpSamples[#xpSamples + 1] = {
            time = timestamp,
            xp = amount,
        }
    end
end

local function PruneXPSamples(now)
    local cutoff = now - XP_WINDOW_SECONDS
    local first = 1

    while first <= #xpSamples and xpSamples[first].time < cutoff do
        first = first + 1
    end

    if first > 1 then
        local remaining = {}

        for i = first, #xpSamples do
            remaining[#remaining + 1] = xpSamples[i]
        end

        xpSamples = remaining
    end
end

local function GetXPPerHour()
    if not xpCurrentXP then
        return nil
    end

    local now = Now()
    PruneXPSamples(now)

    if #xpSamples == 0 then
        return nil
    end

    local totalXP = 0
    local oldestTime = now

    for _, sample in ipairs(xpSamples) do
        totalXP = totalXP + sample.xp

        if sample.time < oldestTime then
            oldestTime = sample.time
        end
    end

    local elapsed = now - oldestTime

    if elapsed < XP_MIN_SAMPLE_SECONDS then
        return nil
    end

    return totalXP / (elapsed / 3600)
end

UpdateXPDisplay = function()
    if not xpDisplayEnabled then
        xpFrame:Hide()
        return
    end

    xpFrame:Show()

    local xph = GetXPPerHour()

    if not xph then
        xpFrame.text:SetText("XP/hr: --")
    elseif xph >= 1000000 then
        xpFrame.text:SetText(string.format("XP/hr: %.2fm", xph / 1000000))
    elseif xph >= 1000 then
        xpFrame.text:SetText(string.format("XP/hr: %.1fk", xph / 1000))
    else
        xpFrame.text:SetText(string.format("XP/hr: %.0f", xph))
    end
end

StartXPTracking = function()
    xpSamples = {}
    xpCurrentXP = UnitXP("player")
    xpCurrentMaxXP = UnitXPMax("player")
    xpLevel = UnitLevel("player")
    UpdateXPDisplay()
end

local function RecordXPUpdate()
    local newXP = UnitXP("player")
    local newMaxXP = UnitXPMax("player")
    local newLevel = UnitLevel("player")
    local now = Now()

    if xpCurrentXP == nil then
        xpCurrentXP = newXP
        xpCurrentMaxXP = newMaxXP
        xpLevel = newLevel
        UpdateXPDisplay()
        return
    end

    local gained = 0

    if newLevel == xpLevel then
        gained = newXP - xpCurrentXP
    elseif newLevel > xpLevel then
        if xpCurrentMaxXP and xpCurrentXP then
            gained = math.max(0, xpCurrentMaxXP - xpCurrentXP)
        end

        if newLevel - xpLevel > 1 then
            -- We do not have historical max-XP values for skipped levels.
            -- Add the current level's XP but do not invent missing values.
            gained = gained + math.max(0, newXP)
        else
            gained = gained + math.max(0, newXP)
        end
    else
        gained = 0
    end

    if gained > 0 then
        AddXPSample(now, gained)
    end

    xpCurrentXP = newXP
    xpCurrentMaxXP = newMaxXP
    xpLevel = newLevel

    UpdateXPDisplay()
end

local xpTicker = C_Timer.NewTicker(1, function()
    UpdateXPDisplay()
end)

----------------------------------------------------------------
-- LOREWALKING SOUND
----------------------------------------------------------------

local function IsInAllowedCity()
    local mapID = C_Map.GetBestMapForUnit("player")

    -- Allowed cities: Silvermoon (2393), Orgrimmar (84), Stormwind (841)
    return mapID == 2393 or mapID == 84 or mapID == 841
end

local function PlayLorewalkingReminder()
    if not lorewalkingSoundEnabled then
        return
    end

    if not IsInAllowedCity() then
        if lorewalkingTimer then
            lorewalkingTimer:Cancel()
            lorewalkingTimer = nil
        end
        return
    end

    local success = C_Sound.PlaySound(
        SOUNDKIT.RAID_WARNING,
        "Master",
        false,
        false
    )

    if not success then
        Msg("WARNING: Sound failed to play.")
    end

    Msg(
        "Lorewalking reminder: "
        .. tostring(lorewalkingSoundDelay)
        .. " seconds elapsed."
    )
end

local function StartLorewalkingTimer()
    if not IsInAllowedCity() then
        return
    end

    if not lorewalkingSoundEnabled then
        return
    end

    -- Lorewalking is already active; do not restart the reminder timer.
    if lorewalkingTimer then
        return
    end

    Msg(
        "Lorewalking started. Reminder in "
        .. tostring(lorewalkingSoundDelay)
        .. " seconds."
    )

    lorewalkingSecondsRemaining = lorewalkingSoundDelay
    UpdateLorewalkingTimerDisplay()

    lorewalkingTimer = C_Timer.NewTicker(1, function(ticker)
        lorewalkingSecondsRemaining = lorewalkingSecondsRemaining - 1
        UpdateLorewalkingTimerDisplay()

        if not IsInAllowedCity() then
            ticker:Cancel()
            lorewalkingTimer = nil
            lorewalkingSecondsRemaining = 0
            UpdateLorewalkingTimerDisplay()
            return
        end

        if lorewalkingSecondsRemaining > 0 then
            return
        end

        ticker:Cancel()
        lorewalkingTimer = nil
        lorewalkingSecondsRemaining = 0
        UpdateLorewalkingTimerDisplay()

        PlayLorewalkingReminder()

    end)
end

----------------------------------------------------------------
-- GOSSIP SELECTION
----------------------------------------------------------------

local function FindTextOption()
    local options = C_GossipInfo.GetOptions() or {}

    for _, wanted in ipairs(PRIORITY) do
        for _, option in ipairs(options) do
            if option.name and option.gossipOptionID then
                local name = Normalize(option.name)

                if name:find(wanted, 1, true) then
                    local desiredPos = name:find(wanted, 1, true)
                    local exitPos = name:find("exit", 1, true)

                    if not exitPos or exitPos > desiredPos then
                        return option, wanted
                    end
                end
            end
        end
    end

    return nil
end

local function SelectOption(option)
    if not option or not option.gossipOptionID then
        return false
    end

    busy = true

    Msg("Selecting: " .. tostring(option.name))

    C_GossipInfo.SelectOption(option.gossipOptionID)

    C_Timer.After(0.40, function()
        busy = false
    end)

    return true
end

local function SelectQuest()
    local options = C_GossipInfo.GetOptions() or {}

    -- Select only the requested quest-related gossip options.
    local questTexts = {
        "time to leave!",
        "tell me",
        "what now?",
    }

    for _, wanted in ipairs(questTexts) do
        for _, option in ipairs(options) do
            if option and option.name and option.gossipOptionID then
                local name = Normalize(option.name)

                if name == wanted or name:find(wanted, 1, true) then
                    return SelectOption(option)
                end
            end
        end
    end

    return false
end

local function ProcessGossip()
    if not enabled or busy then
        return
    end

    if not C_GossipInfo or not C_GossipInfo.GetOptions then
        return
    end

    local option, matchedText = FindTextOption()

    if option then
        if matchedText == "lorewalking" then
            if SelectOption(option) then
                StartLorewalkingTimer()
            end
            return
        end

        if matchedText == "teleport" then
            SelectOption(option)
            return
        end
    end

    SelectQuest()
end

----------------------------------------------------------------
-- CINEMATIC AUTO-SKIP
----------------------------------------------------------------

local function SkipCinematic()
    if not cinematicSkipEnabled then
        return
    end

    if CinematicFrame and CinematicFrame:IsShown() then
        if CinematicFrame_CancelCinematic then
            CinematicFrame_CancelCinematic()
            return
        end

        if CinematicFrame_Close then
            CinematicFrame_Close()
            return
        end
    end

    if MovieFrame and MovieFrame:IsShown() then
        if MovieFrame_StopMovie then
            MovieFrame_StopMovie()
            return
        end

        if MovieFrame_Close then
            MovieFrame_Close()
            return
        end
    end

    if CinematicFrame and CinematicFrame:IsShown() then
        CinematicFrame:Hide()
    end

    if MovieFrame and MovieFrame:IsShown() then
        MovieFrame:Hide()
    end
end

local function ScheduleCinematicSkip()
    SkipCinematic()
    C_Timer.After(0.10, SkipCinematic)
    C_Timer.After(0.25, SkipCinematic)
    C_Timer.After(0.50, SkipCinematic)
end

----------------------------------------------------------------
-- EVENTS
----------------------------------------------------------------

local frame = CreateFrame("Frame")

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_XP_UPDATE")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("GOSSIP_SHOW")
frame:RegisterEvent("GOSSIP_OPTIONS_REFRESHED")
frame:RegisterEvent("CINEMATIC_START")
frame:RegisterEvent("PLAY_MOVIE")

frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        StartXPTracking()
        UpdateXPDisplay()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        return
    end

    if event == "PLAYER_LEVEL_UP" then
        RecordXPUpdate()
        return
    end

    if event == "PLAYER_XP_UPDATE" then
        RecordXPUpdate()
        return
    end

    if event == "CINEMATIC_START" or event == "PLAY_MOVIE" then
        ScheduleCinematicSkip()
        return
    end

    if event == "GOSSIP_SHOW" or event == "GOSSIP_OPTIONS_REFRESHED" then
        C_Timer.After(0.10, ProcessGossip)
    end
end)

----------------------------------------------------------------
-- SLASH COMMANDS
----------------------------------------------------------------

SLASH_AUTOGOSSIPSELECT1 = "/ags"

SlashCmdList["AUTOGOSSIPSELECT"] = function(msg)
    msg = Normalize(msg)

    if msg == "on" then
        enabled = true
        Msg("Auto select enabled.")

    elseif msg == "off" then
        enabled = false

        if lorewalkingTimer then
            lorewalkingTimer:Cancel()
            lorewalkingTimer = nil
        end

        lorewalkingSecondsRemaining = 0
        UpdateLorewalkingTimerDisplay()

        Msg("Auto select disabled.")

    elseif msg == "instructions" or msg == "window" or msg == "show" then
        ToggleInstructionList()

    elseif msg == "xp" then
        xpDisplayEnabled = not xpDisplayEnabled
        UpdateXPDisplay()
        Msg("XP/hr display: " .. (xpDisplayEnabled and "ON" or "OFF"))

    elseif msg == "cinematic on" then
        cinematicSkipEnabled = true
        Msg("Cinematic auto-skip enabled.")

    elseif msg == "cinematic off" then
        cinematicSkipEnabled = false
        Msg("Cinematic auto-skip disabled.")

    elseif msg == "cinematic test" then
        ScheduleCinematicSkip()

    elseif msg == "xp reset" then
        StartXPTracking()
        Msg("XP/hr tracking reset.")

    elseif msg == "sound on" then
        lorewalkingSoundEnabled = true
        Msg("Lorewalking reminder sound enabled.")

    elseif msg == "sound off" then
        lorewalkingSoundEnabled = false

        if lorewalkingTimer then
            lorewalkingTimer:Cancel()
            lorewalkingTimer = nil
        end

        lorewalkingSecondsRemaining = 0
        UpdateLorewalkingTimerDisplay()

        Msg("Lorewalking reminder sound disabled.")

    elseif msg == "sound test" then
        PlayLorewalkingReminder()

    elseif msg:match("^sound %d+$") then
        local seconds = tonumber(msg:match("^sound (%d+)$"))

        if seconds and seconds > 0 then
            lorewalkingSoundDelay = seconds
            Msg(
                "Lorewalking reminder delay: "
                .. tostring(seconds)
                .. " seconds."
            )
        end

    elseif msg == "minimap" then
        ToggleInstructionList()

    elseif msg == "status" then
        Msg("Auto select: " .. (enabled and "ON" or "OFF"))
        Msg("XP/hr display: " .. (xpDisplayEnabled and "ON" or "OFF"))
        Msg("Cinematic skip: " .. (cinematicSkipEnabled and "ON" or "OFF"))
        Msg("Lorewalking sound: " .. (lorewalkingSoundEnabled and "ON" or "OFF"))
        Msg("Lorewalking delay: " .. tostring(lorewalkingSoundDelay) .. " seconds")

    else
        Msg("/ags on")
        Msg("/ags off")
        Msg("/ags instructions")
        Msg("/ags xp")
        Msg("/ags xp reset")
        Msg("/ags cinematic on")
        Msg("/ags cinematic off")
        Msg("/ags cinematic test")
        Msg("/ags sound on")
        Msg("/ags sound off")
        Msg("/ags sound test")
        Msg("/ags sound 60")
        Msg("/ags minimap")
        Msg("/ags status")
    end
end

----------------------------------------------------------------
-- INITIALIZE
----------------------------------------------------------------

-- Begin XP/hr tracking immediately when the addon is loaded.
if UnitXP and UnitXPMax and UnitLevel then
    StartXPTracking()
end

UpdateXPDisplay()

Msg("Loaded.")
Msg("Quest matches: Time to leave!, Tell Me, What now?")
Msg("Cinematic auto-skip: ON")
