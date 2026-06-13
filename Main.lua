-- =============================================================================
-- ExpiryTracker
-- Requires Syndicator. Add "SavedVariables: ExpiryTrackerDB" to your .toc
-- =============================================================================

local VERY_SOON, SOON        = SECONDS_PER_HOUR * 1, SECONDS_PER_HOUR * 3
local RECENT,    MAIL_EXPIRY = SECONDS_PER_DAY  * 1, SECONDS_PER_DAY  * 30
local DASH = "|cff808080—|r"

-- Formatters
local activeFormatter = CreateFromMixins(SecondsFormatterMixin)
activeFormatter:Init(
    SECONDS_PER_MIN,
    SecondsFormatter.Abbreviation.Truncate,
    SecondsFormatterConstants.RoundUpLastUnit,
    SecondsFormatterConstants.ConvertToLower,
    SecondsFormatterConstants.RoundUpIntervals
)
activeFormatter:SetMinInterval(SecondsFormatter.Interval.Minutes)

local expiredFormatter = CreateFromMixins(activeFormatter)
expiredFormatter:SetMinInterval(SecondsFormatter.Interval.Hours)
expiredFormatter:SetApproximationSeconds(SECONDS_PER_HOUR)
expiredFormatter:SetCanRoundUpLastUnit(SecondsFormatterConstants.DontRoundUpLastUnit)
expiredFormatter:SetCanRoundUpIntervals(SecondsFormatterConstants.DontRoundUpIntervals)
expiredFormatter:SetDefaultAbbreviation(SecondsFormatter.Abbreviation.None)

local longExpiredFormatter = CreateFromMixins(expiredFormatter)
longExpiredFormatter:SetMinInterval(SecondsFormatter.Interval.Days)
longExpiredFormatter:SetApproximationSeconds(SECONDS_PER_DAY)

local function FormatGoldWithCommas(rawMoney)
    if not rawMoney or rawMoney == 0 then return DASH end
    local gold   = floor(abs(rawMoney) / 10000)
    local silver = floor(abs(rawMoney) / 100) % 100
    local copper = abs(rawMoney) % 100
    local res = ""
    if gold   > 0             then res = res .. BreakUpLargeNumbers(gold) .. "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t " end
    if silver > 0 or gold > 0 then res = res .. silver .. "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t " end
    res = res .. copper .. "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"
    return res
end

-- =============================================================================
-- SavedVariables + Mailbox Tracking
-- =============================================================================

ExpiryTrackerDB = ExpiryTrackerDB or {}

local function GetConfig()
    ExpiryTrackerDB.config = ExpiryTrackerDB.config or {}
    local c = ExpiryTrackerDB.config
    if c.warnDays          == nil then c.warnDays          = 3    end
    if c.urgentDays        == nil then c.urgentDays        = 1    end
    if c.snoozeMins        == nil then c.snoozeMins        = 2    end
    if c.showChat          == nil then c.showChat          = true end
    if c.enablePopup       == nil then c.enablePopup       = true end
    if c.showMinimapButton == nil then c.showMinimapButton = true end
    if c.showCompartment   == nil then c.showCompartment   = true end
    return c
end

local function GetCharacterKey(name, realm)
    return (name or UnitName("player")) .. "-" .. (realm or GetRealmName())
end

local function ScanMailbox()
    local totalGold          = 0
    local oldestExpiry       = 0
    local auctionItemMailCount = 0
    for i = 1, GetInboxNumItems() do
        local _, _, sender, _, money, _, daysLeft, hasItem = GetInboxHeaderInfo(i)
        if sender == "Auction House" and hasItem then
            auctionItemMailCount = auctionItemMailCount + 1
        end
        if money and money > 0 then
            totalGold = totalGold + money
            if daysLeft then
                local expiry = time() + floor(daysLeft * 86400)
                if oldestExpiry == 0 or expiry < oldestExpiry then
                    oldestExpiry = expiry
                end
            end
        end
    end
    return totalGold, oldestExpiry, auctionItemMailCount
end

local function UpdateMailboxData()
    local key = GetCharacterKey()
    local gold, oldestExpiry, auctionMailCount = ScanMailbox()
    if gold > 0 or auctionMailCount > 0 or ExpiryTrackerDB[key] then
        ExpiryTrackerDB[key] = ExpiryTrackerDB[key] or {}
        ExpiryTrackerDB[key].gold             = gold
        ExpiryTrackerDB[key].oldestMailExpiry = oldestExpiry
        ExpiryTrackerDB[key].lastMailCheck    = time()
        ExpiryTrackerDB[key].auctionMailCount = auctionMailCount
    end
end

-- =============================================================================
-- Alert System
-- =============================================================================

local function CalcTrueExpired(c, charKey)
    local now = time()
    local syndicatorExpired = 0
    local oldestExpiredTime = 0
    if c.auctions then
        for _, a in ipairs(c.auctions) do
            local exp = a.expirationTime or 0
            if exp > 0 and exp < now then
                syndicatorExpired = syndicatorExpired + 1
                if exp > oldestExpiredTime then
                    oldestExpiredTime = exp
                end
            end
        end
    end
    local db = ExpiryTrackerDB[charKey] or {}
    local lastCheck = db.lastMailCheck or 0
    if db.auctionMailCount ~= nil and lastCheck >= oldestExpiredTime then
        return math.min(syndicatorExpired, db.auctionMailCount)
    end
    return syndicatorExpired
end

local function BuildAlerts()
    local cfg    = GetConfig()
    local now    = time()
    local warnAt = now + (cfg.warnDays * 86400)
    local byKey  = {}

    -- Step 1: expired auctions from Syndicator
    if Syndicator and Syndicator.API then
        for _, name in ipairs(Syndicator.API.GetAllCharacters()) do
            local c = Syndicator.API.GetCharacter(name)
            if c then
                local realm    = c.details.realm     or "Unknown"
                local charName = c.details.character or "Unknown"
                local key      = charName .. "-" .. realm
                local trueExpired = CalcTrueExpired(c, key)
                if trueExpired > 0 then
                    local db      = ExpiryTrackerDB[key] or {}
                    byKey[key] = {
                        key        = key,
                        charName   = charName,
                        realm      = realm,
                        expired    = trueExpired,
                        goldExpiry = db.oldestMailExpiry or 0,
                        gold       = db.gold or 0,
                    }
                end
            end
        end
    end

    -- Step 2: characters with mailbox gold
    for key, db in pairs(ExpiryTrackerDB) do
        if key ~= "config" and key ~= "snooze" and key ~= "minimapAngle"
           and key ~= "mainWindowPos" and key ~= "alertPopupPos" and key ~= "minimap" then
            local goldExp = db.oldestMailExpiry or 0
            local gold    = db.gold or 0
            if gold > 0 and (goldExp == 0 or goldExp < warnAt) then
                if not byKey[key] then
                    local charName, realm = strsplit("-", key, 2)
                    byKey[key] = {
                        key        = key,
                        charName   = charName,
                        realm      = realm or "Unknown",
                        expired    = 0,
                        goldExpiry = goldExp,
                        gold       = gold,
                    }
                end
            end
        end
    end

    local alerts = {}
    for _, v in pairs(byKey) do tinsert(alerts, v) end

    -- Current character first if they have expired auctions, then by expired count
    local currentKey = GetCharacterKey()
    table.sort(alerts, function(a, b)
        if a.key == currentKey and a.expired > 0 then return true end
        if b.key == currentKey and b.expired > 0 then return false end
        if a.expired ~= b.expired then return a.expired > b.expired end
        local aE = (a.goldExpiry and a.goldExpiry > 0) and a.goldExpiry or math.huge
        local bE = (b.goldExpiry and b.goldExpiry > 0) and b.goldExpiry or math.huge
        return aE < bE
    end)

    return alerts
end

local RunLoginChecks  -- forward declaration

-- =============================================================================
-- Popup
-- =============================================================================

local alertPopup = nil

local function GetSoonestExpiryForChar(charName, realm, now)
    if not (Syndicator and Syndicator.API) then return 0 end
    for _, name in ipairs(Syndicator.API.GetAllCharacters()) do
        local c = Syndicator.API.GetCharacter(name)
        if c and c.details then
            local cRealm = c.details.realm     or ""
            local cName  = c.details.character or ""
            if cName:lower() == charName:lower() and cRealm:lower() == realm:lower() then
                local soonest = 0
                if c.auctions then
                    for _, a in ipairs(c.auctions) do
                        local exp = a.expirationTime or 0
                        if exp > 0 and (soonest == 0 or exp < soonest) then soonest = exp end
                    end
                end
                return soonest
            end
        end
    end
    return 0
end

local function CreateAlertPopup()
    if alertPopup then return alertPopup end

    local f = CreateFrame("Frame", "ExpiryTrackerAlertFrame", UIParent, "BackdropTemplate")
    f:SetSize(480, 260)
    f:SetFrameStrata("DIALOG")
    if not ExpiryTrackerDB.alertPopupPos then
        f:SetPoint("CENTER")
    else
        local p = ExpiryTrackerDB.alertPopupPos
        f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    end
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ExpiryTrackerDB.alertPopupPos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    f:SetFrameLevel(100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetBackdropColor(1, 1, 1, 1)
    tinsert(UISpecialFrames, f:GetName())

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -20)

    f.scrollBox = CreateFrame("Frame", nil, f, "WowScrollBoxList")
    f.scrollBar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar")
    f.scrollBox:SetPoint("TOPLEFT",     f, "TOPLEFT",     18,  -42)
    f.scrollBox:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -44,  52)
    f.scrollBar:SetPoint("TOPRIGHT",    f, "TOPRIGHT",    -18,  -42)
    f.scrollBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18,   52)

    f.view = CreateScrollBoxListLinearView()
    f.view:SetElementExtent(18)
    ScrollUtil.InitScrollBoxListWithScrollBar(f.scrollBox, f.scrollBar, f.view)
    f.scrollBar:SetHideIfUnscrollable(true)

    f.snoozeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.snoozeBtn:SetSize(120, 26)
    f.snoozeBtn:SetPoint("BOTTOM", 0, 14)

    f.openBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.openBtn:SetSize(120, 26)
    f.openBtn:SetPoint("BOTTOMLEFT", 20, 14)
    f.openBtn:SetText("Open Summary")
    f.openBtn:SetScript("OnClick", function()
        f:Hide()
        if ExpiryTrackerFrame then ExpiryTrackerFrame:Show() end
    end)

    f.dismissBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.dismissBtn:SetSize(120, 26)
    f.dismissBtn:SetPoint("BOTTOMRIGHT", -20, 14)
    f.dismissBtn:SetText("Dismiss")
    f.dismissBtn:SetScript("OnClick", function() f:Hide() end)

    alertPopup = f
    return f
end

local function ShowAlertPopup(alerts, urgency)
    local cfg = GetConfig()
    if not cfg.enablePopup then return end

    local f   = CreateAlertPopup()
    local now = time()

    f.title:SetText("|cffff3030Expired Auctions|r")

    f.snoozeBtn:SetText("Snooze " .. cfg.snoozeMins .. " min")
    f.snoozeBtn:SetScript("OnClick", function()
        ExpiryTrackerDB.snooze = time() + (cfg.snoozeMins * 60)
        f:Hide()
        C_Timer.After(cfg.snoozeMins * 60 + 1, RunLoginChecks)
    end)

    local function ExpiryColor(diff)
        if diff < 0                            then return "|cffff3030" end
        if diff < (cfg.urgentDays * 86400)     then return "|cffff3030" end
        if diff < (cfg.warnDays   * 86400)     then return "|cffffff00" end
        return "|cffffffff"
    end

    local rows = {}
    for _, alert in ipairs(alerts) do
        tinsert(rows, { text = alert.charName .. " (" .. alert.realm .. ")", color = "|cffffffff" })

        if alert.expired > 0 then
            local auctionWord = alert.expired == 1 and "auction" or "auctions"
            local soonest = GetSoonestExpiryForChar(alert.charName, alert.realm, now)
            local expiryPart = ""
            if soonest > 0 then
                local diff = soonest - now
                local expiryText
                if diff < 0 then
                    local absDiff = abs(diff)
                    local fmt = absDiff < RECENT and expiredFormatter or longExpiredFormatter
                    expiryText = format("%s ago", fmt:Format(absDiff))
                else
                    expiryText = format("%s - %s", activeFormatter:Format(diff), date("%a %H:%M", soonest))
                end
                expiryPart = "  " .. ExpiryColor(diff) .. expiryText .. "|r"
            end
            tinsert(rows, { text = "  " .. alert.expired .. " " .. auctionWord .. expiryPart, color = "|cffffffff" })
        end

        if (alert.goldExpiry or 0) > 0 and (alert.gold or 0) > 0 then
            local diff = alert.goldExpiry - now
            if diff > 0 then
                local expireStr  = date("%a %b %d at %H:%M", alert.goldExpiry)
                local expiryPart = "  expires " .. ExpiryColor(diff) .. expireStr .. "|r"
                tinsert(rows, { text = "  Mail gold: " .. FormatGoldWithCommas(alert.gold) .. expiryPart, color = "|cffffffff" })
            end
        end

        tinsert(rows, { text = "", color = "" })
    end

    f.view:SetElementInitializer("Frame", function(rowFrame, data)
        if not rowFrame.fs then
            rowFrame.fs = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            rowFrame.fs:SetJustifyH("LEFT")
            rowFrame.fs:SetPoint("LEFT",  2, 0)
            rowFrame.fs:SetPoint("RIGHT", -2, 0)
        end
        rowFrame.fs:SetText((data.color or "") .. (data.text or "") .. (data.color ~= "" and "|r" or ""))
    end)
    f.scrollBox:SetDataProvider(CreateDataProvider(rows))
    f:Show()
end

-- =============================================================================
-- Login checks
-- =============================================================================

local loginCheckDone = false

RunLoginChecks = function()
    local cfg = GetConfig()
    local now = time()

    local snoozeUntil = ExpiryTrackerDB.snooze or 0
    if now < snoozeUntil then
        C_Timer.After(snoozeUntil - now + 1, RunLoginChecks)
        return
    end

    local alerts = BuildAlerts()
    if #alerts == 0 then return end

    if not loginCheckDone and cfg.showChat then
        loginCheckDone = true
        local expiredChars = {}
        for _, alert in ipairs(alerts) do
            if alert.expired > 0 then
                local soonest = GetSoonestExpiryForChar(alert.charName, alert.realm, now)
                local expStr = ""
                if soonest > 0 then
                    local diff = soonest - now
                    local expiryText, expiryColor
                    if diff < 0 then
                        local absDiff = abs(diff)
                        local fmt = absDiff < RECENT and expiredFormatter or longExpiredFormatter
                        expiryText  = format("%s ago", fmt:Format(absDiff))
                        expiryColor = "|cffff3030"
                    else
                        expiryText = format("%s - %s", activeFormatter:Format(diff), date("%a %H:%M", soonest))
                        if diff < (cfg.urgentDays * 86400) then
                            expiryColor = "|cffff3030"
                        elseif diff < (cfg.warnDays * 86400) then
                            expiryColor = "|cffffff00"
                        else
                            expiryColor = "|cffffffff"
                        end
                    end
                    expStr = "  " .. expiryColor .. expiryText .. "|r"
                end
                tinsert(expiredChars, alert.charName .. " (" .. alert.realm .. "): " .. alert.expired .. " expired" .. expStr)
            end
        end
        if #expiredChars > 0 then
            print("|cffff9900[ExpiryTracker]|r Expired auctions waiting in mailbox:")
            for _, line in ipairs(expiredChars) do print("  " .. line) end
        end
    end

    local warnAt     = now + (cfg.warnDays   * 86400)
    local urgAt      = now + (cfg.urgentDays * 86400)
    local popupList  = {}
    local hasExpired, hasUrgent, hasWarn = false, false, false

    for _, alert in ipairs(alerts) do
        local goldExp     = alert.goldExpiry or 0
        local isExpired   = alert.expired > 0
        local isUrgent    = goldExp > 0 and goldExp < urgAt
        local isWarn      = goldExp > 0 and goldExp < warnAt
        local isGoldKnown = (alert.gold or 0) > 0

        if isExpired or isUrgent or isWarn or isGoldKnown then
            tinsert(popupList, alert)
            if isExpired then hasExpired = true end
            if isUrgent  then hasUrgent  = true end
            if isWarn    then hasWarn    = true end
        end
    end

    if #popupList > 0 then
        ShowAlertPopup(popupList, hasUrgent and "urgent" or (hasExpired and "expired" or "warn"))
    end
end

-- =============================================================================
-- Events
-- =============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("MAIL_SHOW")
eventFrame:RegisterEvent("MAIL_CLOSED")
eventFrame:RegisterEvent("MAIL_INBOX_UPDATE")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        -- RunLoginChecks after a short delay to let Syndicator finish loading
        C_Timer.After(5, RunLoginChecks)
        -- UpdateMinimapButton is called inside ContinueOnAddOnLoaded which
        -- runs at the same time — no need to call it here
        if Syndicator and Syndicator.CallbackRegistry then
            Syndicator.CallbackRegistry:RegisterCallback("AuctionsCacheUpdate", function()
                if ExpiryTrackerFrame and ExpiryTrackerFrame:IsShown() then
                    ExpiryTrackerFrame:GetScript("OnShow")()
                end
            end, eventFrame)
            Syndicator.CallbackRegistry:RegisterCallback("MailCacheUpdate", function()
                C_Timer.After(0.5, function()
                    if ExpiryTrackerFrame and ExpiryTrackerFrame:IsShown() then
                        ExpiryTrackerFrame:GetScript("OnShow")()
                    end
                end)
            end, eventFrame)
        end
        eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")

    elseif event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE" then
        UpdateMailboxData()
        if ExpiryTrackerFrame and ExpiryTrackerFrame:IsShown() then
            ExpiryTrackerFrame:GetScript("OnShow")()
        end

    elseif event == "MAIL_CLOSED" then
        C_Timer.After(0.3, function()
            UpdateMailboxData()
            if ExpiryTrackerFrame and ExpiryTrackerFrame:IsShown() then
                ExpiryTrackerFrame:GetScript("OnShow")()
            end
        end)

    elseif event == "AUCTION_HOUSE_CLOSED" then
        C_Timer.After(1, function()
            if ExpiryTrackerFrame and ExpiryTrackerFrame:IsShown() then
                ExpiryTrackerFrame:GetScript("OnShow")()
            end
        end)
    end
end)

-- =============================================================================
-- Tooltip helpers
-- =============================================================================

local function GetLinkType(link)
    if not link then return nil end
    return link:match("|H([^:]+):")
end

local function ShowLinkTooltip(owner, link)
    if not link then return end

    if GetLinkType(link) == "battlepet" then
        local speciesID, level, quality, health, power, speed =
            link:match("|Hbattlepet:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):")
        if speciesID then
            speciesID = tonumber(speciesID)
            level     = tonumber(level)
            quality   = tonumber(quality)
            health    = tonumber(health)
            power     = tonumber(power)
            speed     = tonumber(speed)

            local function TryShow()
                local fn = BattlePetToolTip_Show or BattlePetTooltip_Show
                if not fn then return false end
                fn(speciesID, level, quality, health, power, speed)
                return true
            end

            local shown = TryShow()
            if not shown then
                UIParentLoadAddOn("Blizzard_PetBattleUI")
                shown = TryShow()
            end

            if shown then
                local tip = BattlePetTooltip or FloatingBattlePetTooltip
                if tip then
                    local cx, cy = GetCursorPosition()
                    local scale  = UIParent:GetEffectiveScale()
                    tip:SetScript("OnUpdate", nil)
                    tip:ClearAllPoints()
                    tip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", (cx / scale) + 15, (cy / scale) + 15)
                end
            else
                local cx, cy = GetCursorPosition()
                local scale  = UIParent:GetEffectiveScale()
                GameTooltip:SetOwner(owner, "ANCHOR_NONE")
                GameTooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", (cx / scale) + 15, (cy / scale) + 15)
                GameTooltip:SetText(link:match("%[(.-)%]") or "Battle Pet")
                GameTooltip:Show()
            end
            return
        end
    end

    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    local cx, cy = GetCursorPosition()
    local scale  = UIParent:GetEffectiveScale()
    GameTooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", (cx / scale) + 15, (cy / scale) + 15)
    local ok = pcall(function() GameTooltip:SetHyperlink(link) end)
    if not ok then GameTooltip:SetText(link:match("%[(.-)%]") or "Unknown") end
    GameTooltip:Show()
end

local function HideLinkTooltip(link)
    if GetLinkType(link) == "battlepet" then
        local tip = BattlePetTooltip or FloatingBattlePetTooltip
        if tip then
            tip:SetScript("OnUpdate", nil)
            tip:Hide()
        end
    end
    GameTooltip:Hide()
end

-- =============================================================================
-- Debug
-- =============================================================================

local function RunDebugForChar(charName, realm)
    if not charName or not realm then
        print("|cffff9900[ExpiryTracker]|r Usage: /etrdebug CharName-Realm")
        return
    end
    local key = charName .. "-" .. realm
    print("|cffff9900[ExpiryTracker]|r Debug for: " .. key)
    local db = ExpiryTrackerDB[key]
    if db then
        print("  DB gold: " .. tostring(db.gold))
        print("  DB oldestMailExpiry: " .. tostring(db.oldestMailExpiry))
        print("  DB lastMailCheck: " .. tostring(db.lastMailCheck))
        print("  DB auctionMailCount: " .. tostring(db.auctionMailCount))
    else
        print("  DB entry: nil (mailbox never scanned on this char)")
        print("  All DB keys containing '" .. charName .. "':")
        for k, _ in pairs(ExpiryTrackerDB) do
            if type(k) == "string" and k:lower():find(charName:lower(), 1, true) then
                local v = ExpiryTrackerDB[k]
                print("    [" .. k .. "] auctionMailCount=" .. tostring(v.auctionMailCount))
            end
        end
    end
    if not (Syndicator and Syndicator.API) then
        print("  Syndicator: not loaded")
        return
    end
    local found = false
    for _, name in ipairs(Syndicator.API.GetAllCharacters()) do
        local c = Syndicator.API.GetCharacter(name)
        if c then
            local cN = c.details.character or ""
            local cR = c.details.realm     or ""
            if cN:lower() == charName:lower() and cR:lower() == realm:lower() then
                found = true
                print("  Syndicator key: " .. name)
                print("  Syndicator realm: " .. cR)
                print("  Syndicator auctions: " .. (c.auctions and #c.auctions or 0))
                print("  Syndicator money: " .. tostring(c.money))
                print("  Syndicator mail items: " .. (c.mail and #c.mail or 0))
            end
        end
    end
    if not found then
        print("  Syndicator: character NOT found")
        print("  All known characters:")
        for _, name in ipairs(Syndicator.API.GetAllCharacters()) do print("    " .. name) end
    end
end

SlashCmdList["ExpiryTrackerDebug"] = function(msg)
    local charName, realm = msg:match("^(%S+)%s+(.+)$")
    RunDebugForChar(charName, realm)
end
SLASH_ExpiryTrackerDebug1 = "/etrdebug"

-- =============================================================================
-- Minimap Button
-- =============================================================================

local minimapBtn = CreateFrame("Button", "ExpiryTrackerMinimapButton", Minimap)
minimapBtn:SetFrameStrata("MEDIUM")
minimapBtn:SetFixedFrameStrata(true)
minimapBtn:SetFrameLevel(8)
minimapBtn:SetFixedFrameLevel(true)
minimapBtn:SetSize(31, 31)
minimapBtn:RegisterForClicks("anyUp")
minimapBtn:RegisterForDrag("LeftButton")
minimapBtn:EnableMouse(true)
minimapBtn:Hide()

minimapBtn:SetHighlightTexture(136477)

local minimapBg = minimapBtn:CreateTexture(nil, "BACKGROUND")
minimapBg:SetTexture(136467)
minimapBg:SetSize(24, 24)
minimapBg:SetPoint("CENTER", 0, 0)

local minimapIcon = minimapBtn:CreateTexture(nil, "ARTWORK")
minimapIcon:SetTexture("Interface\\AddOns\\ExpiryTracker\\ExpiryTracker_icon")
minimapIcon:SetSize(18, 18)
minimapIcon:SetPoint("CENTER", 0, 0)

local minimapBorder = minimapBtn:CreateTexture(nil, "OVERLAY")
minimapBorder:SetTexture(136430)
minimapBorder:SetSize(50, 50)
minimapBorder:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 0, 0)

local function UpdateMinimapPos(angle)
    ExpiryTrackerDB.minimapAngle = angle
    local rad = math.rad(angle)
    local w   = (Minimap:GetWidth()  / 2) + 5
    local h   = (Minimap:GetHeight() / 2) + 5
    minimapBtn:ClearAllPoints()
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * w, math.sin(rad) * h)
end

minimapBtn:SetScript("OnClick", function(_, btn)
    if btn == "RightButton" then return end
    if ExpiryTrackerFrame then
        if ExpiryTrackerFrame:IsShown() then ExpiryTrackerFrame:Hide() else ExpiryTrackerFrame:Show() end
    end
end)

local isDragging = false
minimapBtn:SetScript("OnDragStart", function() isDragging = true end)
minimapBtn:SetScript("OnDragStop",  function() isDragging = false end)
minimapBtn:SetScript("OnUpdate", function()
    if not isDragging then return end
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale  = UIParent:GetEffectiveScale()
    UpdateMinimapPos(math.deg(math.atan2((py / scale) - my, (px / scale) - mx)))
end)

minimapBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("ExpiryTracker")
    GameTooltip:AddLine("Click to open/close", 1, 1, 1)
    GameTooltip:AddLine("Drag to reposition", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
minimapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local compartmentData = nil

local function UpdateCompartmentButton()
    if not AddonCompartmentFrame then return end
    local cfg = GetConfig()
    if cfg.showCompartment and not compartmentData then
        compartmentData = {
            text         = "ExpiryTracker",
            icon         = "Interface\\AddOns\\ExpiryTracker\\ExpiryTracker_icon",
            notCheckable = true,
            func         = function()
                if ExpiryTrackerFrame then
                    if ExpiryTrackerFrame:IsShown() then ExpiryTrackerFrame:Hide() else ExpiryTrackerFrame:Show() end
                end
            end,
        }
        AddonCompartmentFrame:RegisterAddon(compartmentData)
    elseif not cfg.showCompartment and compartmentData then
        local addons = AddonCompartmentFrame.registeredAddons
        if addons then
            for i = #addons, 1, -1 do
                if addons[i] == compartmentData then
                    table.remove(addons, i)
                    break
                end
            end
        end
        if AddonCompartmentFrame.UpdateDisplay then AddonCompartmentFrame:UpdateDisplay() end
        compartmentData = nil
    end
end

local function UpdateMinimapButton()
    local cfg = GetConfig()
    if cfg.showMinimapButton then
        minimapBtn:Show()
        UpdateMinimapPos(ExpiryTrackerDB.minimapAngle or 220)
    else
        minimapBtn:Hide()
    end
    UpdateCompartmentButton()
end

-- =============================================================================
-- UI
-- =============================================================================

EventUtil.ContinueOnAddOnLoaded("ExpiryTracker", function()

    local frame = CreateFrame("Frame", "ExpiryTrackerFrame", UIParent, "ButtonFrameTemplate")
    frame:Hide()
    ButtonFrameTemplate_HidePortrait(frame)
    ButtonFrameTemplate_HideButtonBar(frame)
    frame:SetTitle("Auction Expiration Times")
    frame:SetSize(775, 500)
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(10)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ExpiryTrackerDB.mainWindowPos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    if ExpiryTrackerDB.mainWindowPos then
        local p = ExpiryTrackerDB.mainWindowPos
        frame:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    else
        frame:SetPoint("CENTER")
    end
    tinsert(UISpecialFrames, frame:GetName())

    Mixin(frame.Inset, BackdropTemplateMixin)
    frame.Inset:SetBackdrop({
        bgFile   = "Interface\\FrameGeneral\\UI-Background-Rock-Tile",
        tile     = true,
        tileSize = 128,
    })
    frame.Inset:SetBackdropColor(0.6, 0.5, 0.4, 1)

    local currentTime = 0
    frame.selectedTab = 1

    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT",  frame.Inset, "TOPLEFT",   10, 20)
    header:SetPoint("TOPRIGHT", frame.Inset, "TOPRIGHT", -10, 20)
    header:SetHeight(20)

    local function MakeHeaderCol()
        local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetJustifyH("LEFT")
        return fs
    end

    header.cols = {}
    for i = 1, 6 do header.cols[i] = MakeHeaderCol() end

    local scrollBox = CreateFrame("Frame",      nil, frame, "WowScrollBoxList")
    local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
    scrollBox:SetPoint("TOPLEFT",     frame.Inset, "TOPLEFT",      5,  -5)
    scrollBox:SetPoint("BOTTOMRIGHT", frame.Inset, "BOTTOMRIGHT", -25,  5)
    scrollBar:SetPoint("TOPRIGHT",    frame.Inset, "TOPRIGHT",    -5,  -5)
    scrollBar:SetPoint("BOTTOMRIGHT", frame.Inset, "BOTTOMRIGHT", -5,   5)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtentCalculator(function(_, data)
        if data.isSpacer then return 15 end
        return 22
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    scrollBar:SetHideIfUnscrollable(true)

    -- ==========================================================================
    -- Config Panel
    -- ==========================================================================
    local configPanel = CreateFrame("Frame", nil, frame.Inset)
    configPanel:SetAllPoints()
    configPanel:Hide()

    local cfgScrollFrame = CreateFrame("ScrollFrame", nil, configPanel)
    cfgScrollFrame:SetPoint("TOPLEFT",     configPanel, "TOPLEFT",      5,  -5)
    cfgScrollFrame:SetPoint("BOTTOMRIGHT", configPanel, "BOTTOMRIGHT", -28,  5)

    local cfgScrollBar = CreateFrame("EventFrame", nil, configPanel, "MinimalScrollBar")
    cfgScrollBar:SetPoint("TOPRIGHT",    configPanel, "TOPRIGHT",    -8,  -5)
    cfgScrollBar:SetPoint("BOTTOMRIGHT", configPanel, "BOTTOMRIGHT", -8,   5)
    ScrollUtil.InitScrollFrameWithScrollBar(cfgScrollFrame, cfgScrollBar)
    cfgScrollBar:SetHideIfUnscrollable(true)

    local cfgContent = CreateFrame("Frame", nil, cfgScrollFrame)
    cfgContent:SetSize(cfgScrollFrame:GetWidth() or 700, 480)
    cfgScrollFrame:SetScrollChild(cfgContent)

    local descText = cfgContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    descText:SetPoint("TOPLEFT",  cfgContent, "TOPLEFT",  10, -10)
    descText:SetPoint("TOPRIGHT", cfgContent, "TOPRIGHT", -10, -10)
    descText:SetJustifyH("LEFT")
    descText:SetSpacing(4)
    descText:SetTextColor(1, 1, 1, 1)
    descText:SetText(
        "ExpiryTracker monitors your auction house activity across all characters using Syndicator (required). " ..
        "It monitors active and expired auction listings, mailbox gold from AH sales, and alerts you at login " ..
        "when items need attention. Open the Summary tab for a per-character overview, the Details tab for " ..
        "individual item expiry times. Mailbox gold is scanned when you visit the mailbox.\n\n" ..
        "Slash commands:  /etr  (open window)     /etrdebug CharName-Realm  (diagnose a character)"
    )

    local function MakeCheckbox(parent, key, label)
        local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cb.text:SetPoint("LEFT", cb, "RIGHT", 5, 0)
        cb.text:SetTextColor(1, 1, 1, 1)
        cb.text:SetText(label)
        cb:SetChecked(GetConfig()[key])
        cb:SetScript("OnClick", function(self) GetConfig()[key] = self:GetChecked() end)
        return cb
    end

    local function MakeSlider(parent, key, label, minVal, maxVal)
        local slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
        slider:SetWidth(240)
        slider:SetMinMaxValues(minVal, maxVal)
        slider:SetValueStep(1)
        slider:SetObeyStepOnDrag(true)
        local lbl = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 5)
        lbl:SetTextColor(1, 1, 1, 1)
        slider:SetScript("OnValueChanged", function(self, value)
            local val = math.floor(value)
            GetConfig()[key] = val
            lbl:SetText(label .. ": " .. val)
        end)
        slider:SetValue(GetConfig()[key])
        lbl:SetText(label .. ": " .. GetConfig()[key])
        return slider
    end

    local cb1 = MakeCheckbox(cfgContent, "showChat",         "Show chat message on login")
    cb1:SetPoint("TOPLEFT", descText, "BOTTOMLEFT", 0, -12)

    local cb2 = MakeCheckbox(cfgContent, "enablePopup",      "Enable expiration popup")
    cb2:SetPoint("TOPLEFT", cb1, "BOTTOMLEFT", 0, -4)

    local cb3 = MakeCheckbox(cfgContent, "showMinimapButton", "Show minimap button")
    cb3:SetPoint("TOPLEFT", cb2, "BOTTOMLEFT", 0, -4)
    cb3:SetScript("OnClick", function(self)
        GetConfig().showMinimapButton = self:GetChecked()
        UpdateMinimapButton()
    end)

    local cb4 = MakeCheckbox(cfgContent, "showCompartment", "Show addon compartment icon")
    cb4:SetPoint("TOPLEFT", cb3, "BOTTOMLEFT", 0, -4)
    cb4:SetScript("OnClick", function(self)
        GetConfig().showCompartment = self:GetChecked()
        UpdateCompartmentButton()
    end)

    local s1 = MakeSlider(cfgContent, "warnDays",   "Warning threshold (days)",  1, 30)
    s1:SetPoint("TOPLEFT", cb4, "BOTTOMLEFT", 0, -28)

    local s2 = MakeSlider(cfgContent, "urgentDays", "Urgent threshold (days)",   1, 7)
    s2:SetPoint("TOPLEFT", s1, "BOTTOMLEFT", 0, -52)

    local s3 = MakeSlider(cfgContent, "snoozeMins", "Snooze duration (minutes)", 1, 120)
    s3:SetPoint("TOPLEFT", s2, "BOTTOMLEFT", 0, -52)

    local debugLabel = cfgContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    debugLabel:SetPoint("TOPLEFT", s3, "BOTTOMLEFT", 0, -42)
    debugLabel:SetText("Debug: type CharName-Realm and click Run")
    debugLabel:SetTextColor(1, 1, 1, 1)

    local debugEdit = CreateFrame("EditBox", nil, cfgContent, "InputBoxTemplate")
    debugEdit:SetPoint("TOPLEFT", debugLabel, "BOTTOMLEFT", 0, -10)
    debugEdit:SetSize(200, 20)
    debugEdit:SetAutoFocus(false)
    debugEdit:SetMaxLetters(64)
    debugEdit:SetText("CharName-Realm")

    local debugBtn = CreateFrame("Button", nil, cfgContent, "UIPanelButtonTemplate")
    debugBtn:SetPoint("LEFT", debugEdit, "RIGHT", 8, 0)
    debugBtn:SetSize(60, 22)
    debugBtn:SetText("Run")
    debugBtn:SetScript("OnClick", function()
        local input = debugEdit:GetText()
        local charName, realm = input:match("^(.+)-(.+)$")
        RunDebugForChar(charName, realm)
    end)

    -- ==========================================================================
    -- Summary / Details headers and rendering
    -- ==========================================================================

    local summaryHeaders = {
        { offset = 0,   width = 140, text = "Realm"        },
        { offset = 145, width = 130, text = "Character"    },
        { offset = 280, width = 60,  text = "Expired"      },
        { offset = 345, width = 55,  text = "Active"       },
        { offset = 405, width = 150, text = "Mailbox Gold" },
        { offset = 560, width = 215, text = "Expiry"       },
    }

    local detailHeaders = {
        { offset = 0,   width = 310, text = "Item"      },
        { offset = 315, width = 140, text = "Realm"     },
        { offset = 460, width = 80,  text = "Character" },
        { offset = 545, width = 200, text = "Expiry"    },
    }

    local function ApplyHeaders(defs)
        for i, def in ipairs(defs) do
            local col = header.cols[i]
            col:ClearAllPoints()
            col:SetPoint("LEFT", def.offset, 0)
            col:SetWidth(def.width)
            col:SetText(def.text)
            col:Show()
        end
        for i = #defs + 1, #header.cols do header.cols[i]:Hide() end
    end

    local function FormatExpiry(expirationTime)
        if not expirationTime or expirationTime == 0 then return DASH end
        local diff = expirationTime - currentTime
        local text, color
        if diff < 0 then
            local absDiff = abs(diff)
            local fmt     = absDiff < RECENT and expiredFormatter or longExpiredFormatter
            text  = format("%s ago", fmt:Format(absDiff))
            color = absDiff > (MAIL_EXPIRY - 604800) and RED_FONT_COLOR or WARNING_FONT_COLOR
        else
            local displayDiff = diff
            if diff > SECONDS_PER_DAY and (diff % SECONDS_PER_DAY) > (SECONDS_PER_DAY - 60) then
                displayDiff = diff + 60
            end
            text  = format("%s - %s", activeFormatter:Format(displayDiff), date("%a %H:%M", expirationTime))
            color = diff < VERY_SOON and ORANGE_FONT_COLOR
                 or diff < SOON      and YELLOW_FONT_COLOR
                 or HIGHLIGHT_FONT_COLOR
        end
        return color:WrapTextInColorCode(text)
    end

    local function EnsureStrings(f, count)
        if not f.v then f.v = {} end
        if not f.line then
            f.line = f:CreateTexture(nil, "BACKGROUND")
            f.line:SetHeight(1)
            f.line:SetColorTexture(1, 1, 1, 0.2)
            f.line:SetPoint("LEFT",  f, "LEFT",  0, 0)
            f.line:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        end
        if not f.topLine then
            f.topLine = f:CreateTexture(nil, "BACKGROUND")
            f.topLine:SetHeight(1)
            f.topLine:SetColorTexture(1, 1, 1, 0.25)
            f.topLine:SetPoint("LEFT",  f, "TOPLEFT",  0, 0)
            f.topLine:SetPoint("RIGHT", f, "TOPRIGHT", 0, 0)
        end
        for i = 1, count do
            if not f.v[i] then
                f.v[i] = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                f.v[i]:SetJustifyH("LEFT")
            end
            f.v[i]:Show()
        end
        for i = count + 1, #f.v do f.v[i]:Hide() end

        if not f.linkBtn then
            f.linkBtn = CreateFrame("Button", nil, f)
            f.linkBtn:SetScript("OnEnter", function(self) ShowLinkTooltip(self, self.link) end)
            f.linkBtn:SetScript("OnLeave", function(self) HideLinkTooltip(self.link) end)
            f.linkBtn:SetScript("OnClick", function(self)
                if self.link and IsModifiedClick("CHATLINK") then ChatEdit_InsertLink(self.link) end
            end)
        end
    end

    local function SummaryInit(f, data)
        EnsureStrings(f, 6)
        f.linkBtn:Hide()

        if data.isSpacer then
            for i = 1, 6 do f.v[i]:SetText("") end
            f.line:Hide()
            f.topLine:Hide()
            return
        end

        f.line:Hide()
        f.topLine:SetShown(data.isTotal)

        local v = f.v
        v[1]:SetPoint("LEFT",   0, 0)  v[1]:SetWidth(140)
        v[2]:SetPoint("LEFT", 145, 0)  v[2]:SetWidth(130)
        v[3]:SetPoint("LEFT", 280, 0)  v[3]:SetWidth(60)
        v[4]:SetPoint("LEFT", 345, 0)  v[4]:SetWidth(55)
        v[5]:SetPoint("LEFT", 405, 0)  v[5]:SetWidth(150)
        v[6]:SetPoint("LEFT", 560, 0)  v[6]:SetWidth(215)

        if data.isTotal then
            v[1]:SetText("|cff00ccffTotals|r")
            v[2]:SetText("")
            v[3]:SetText(data.expired > 0 and RED_FONT_COLOR:WrapTextInColorCode(BreakUpLargeNumbers(data.expired))  or DASH)
            v[4]:SetText(data.active  > 0 and GREEN_FONT_COLOR:WrapTextInColorCode(BreakUpLargeNumbers(data.active)) or DASH)
            v[5]:SetText(FormatGoldWithCommas(data.gold))
            v[6]:SetText("")
        else
            local charKey = GetCharacterKey(data.character, data.realm)
            local dbEntry = ExpiryTrackerDB[charKey]
            local goldText = (dbEntry and dbEntry.gold and dbEntry.gold > 0)
                             and FormatGoldWithCommas(dbEntry.gold) or DASH
            local nameColor = data.expired > 0 and RED_FONT_COLOR or HIGHLIGHT_FONT_COLOR
            v[1]:SetText(nameColor:WrapTextInColorCode(data.realm))
            v[2]:SetText(nameColor:WrapTextInColorCode(data.character))
            v[3]:SetText(data.expired > 0 and RED_FONT_COLOR:WrapTextInColorCode(data.expired)  or DASH)
            v[4]:SetText(data.active  > 0 and GREEN_FONT_COLOR:WrapTextInColorCode(data.active) or DASH)
            v[5]:SetText(goldText)
            v[6]:SetText(FormatExpiry(data.soonestExpiry))
        end
    end

    local function DetailInit(f, data)
        EnsureStrings(f, 4)
        f.line:Hide()
        f.topLine:Hide()

        local v = f.v
        v[1]:SetPoint("LEFT",   0, 0)  v[1]:SetWidth(310)
        v[2]:SetPoint("LEFT", 315, 0)  v[2]:SetWidth(140)
        v[3]:SetPoint("LEFT", 460, 0)  v[3]:SetWidth(80)
        v[4]:SetPoint("LEFT", 545, 0)  v[4]:SetWidth(200)

        if data.isMailbox then
            f.linkBtn:Hide()
            v[1]:SetText(YELLOW_FONT_COLOR:WrapTextInColorCode("Mailbox Gold: ") .. FormatGoldWithCommas(data.gold))
            v[2]:SetText(data.realm or "")
            v[3]:SetText(data.character or "")
            v[4]:SetText(FormatExpiry(data.expirationTime))
        else
            local cleanLink = data.itemLink:gsub("|h%[(.-)%]|h", "|h%1|h")
            local qtyText   = (data.itemCount and data.itemCount > 1)
                              and ("  " .. LIGHTBLUE_FONT_COLOR:WrapTextInColorCode("x" .. data.itemCount))
                              or  ""
            v[1]:SetText(cleanLink .. qtyText)
            v[2]:SetText(data.realm)
            v[3]:SetText(data.character)
            v[4]:SetText(FormatExpiry(data.expirationTime))

            f.linkBtn:Show()
            f.linkBtn:ClearAllPoints()
            f.linkBtn:SetPoint("LEFT", v[1], "LEFT", 0, 0)
            f.linkBtn:SetHeight(v[1]:GetHeight() > 0 and v[1]:GetHeight() or 14)
            f.linkBtn:SetWidth(v[1]:GetStringWidth() + 4)
            f.linkBtn.link = data.itemLink
        end
    end

    local function Refresh()
        currentTime = time()

        if frame.selectedTab == 3 then
            configPanel:Show()
            header:Hide()
            scrollBox:Hide()
            scrollBar:Hide()
            return
        end
        configPanel:Hide()
        header:Show()
        scrollBox:Show()
        scrollBar:Show()

        local details, summary = {}, {}
        local totalExp, totalAct, totalGold = 0, 0, 0

        for _, name in ipairs(Syndicator.API.GetAllCharacters()) do
            local c = Syndicator.API.GetCharacter(name)
            if c then
                local realm    = c.details.realm     or "Unknown"
                local charName = c.details.character or "Unknown"
                local charKey  = charName .. "-" .. realm
                local charData = { realm = realm, character = charName, expired = 0, active = 0, soonestExpiry = 0 }
                local mostRecentExp = 0
                local soonestActive = 0

                if c.auctions then
                    for _, a in ipairs(c.auctions) do
                        local auction          = CopyTable(a)
                        auction.realm          = realm
                        auction.character      = charName
                        auction.expirationTime = auction.expirationTime or 0
                        if auction.expirationTime > 0 then
                            if auction.expirationTime < currentTime then
                                if auction.expirationTime > mostRecentExp then
                                    mostRecentExp = auction.expirationTime
                                end
                            else
                                charData.active = charData.active + 1
                                totalAct        = totalAct + 1
                                if soonestActive == 0 or auction.expirationTime < soonestActive then
                                    soonestActive = auction.expirationTime
                                end
                                tinsert(details, auction)
                            end
                        else
                            tinsert(details, auction)
                        end
                    end
                end

                local db          = ExpiryTrackerDB[charKey]
                local trueExpired = CalcTrueExpired(c, charKey)

                if c.auctions and trueExpired > 0 then
                    local addedExpired = 0
                    for _, a in ipairs(c.auctions) do
                        if addedExpired >= trueExpired then break end
                        local exp = a.expirationTime or 0
                        if exp > 0 and exp < currentTime then
                            local auction     = CopyTable(a)
                            auction.realm     = realm
                            auction.character = charName
                            tinsert(details, auction)
                            addedExpired = addedExpired + 1
                        end
                    end
                end

                charData.expired = trueExpired
                totalExp         = totalExp + trueExpired

                if trueExpired > 0 then
                    charData.soonestExpiry = mostRecentExp > 0 and mostRecentExp or soonestActive
                else
                    charData.soonestExpiry = soonestActive
                end

                if db and db.gold and db.gold > 0 then
                    totalGold = totalGold + db.gold
                    tinsert(details, {
                        isMailbox      = true,
                        character      = charName,
                        realm          = realm,
                        gold           = db.gold,
                        expirationTime = db.oldestMailExpiry or 0,
                    })
                    if charData.soonestExpiry == 0 and (db.oldestMailExpiry or 0) > 0 then
                        charData.soonestExpiry = db.oldestMailExpiry
                    end
                end

                local hasRelevantData = trueExpired > 0
                                      or charData.active > 0
                                      or (db and db.gold and db.gold > 0)
                if hasRelevantData then
                    summary[charKey] = charData
                end
            end
        end

        if frame.selectedTab == 1 then
            ApplyHeaders(summaryHeaders)
            local list = {}
            for _, v in pairs(summary) do tinsert(list, v) end
            table.sort(list, function(a, b) return a.realm < b.realm end)
            tinsert(list, { isSpacer = true })
            tinsert(list, { isTotal = true, expired = totalExp, active = totalAct, gold = totalGold })
            view:SetElementInitializer("Frame", SummaryInit)
            scrollBox:SetDataProvider(CreateDataProvider(list))
        else
            ApplyHeaders(detailHeaders)
            table.sort(details, function(a, b)
                if a.realm ~= b.realm then return a.realm < b.realm end
                if a.isMailbox ~= b.isMailbox then return not a.isMailbox end
                return (a.expirationTime or 0) < (b.expirationTime or 0)
            end)
            view:SetElementInitializer("Frame", DetailInit)
            scrollBox:SetDataProvider(CreateDataProvider(details))
        end
    end

    local function TabClick(self)
        PanelTemplates_SetTab(frame, self:GetID())
        frame.selectedTab = self:GetID()
        Refresh()
    end

    frame.Tabs = {}
    for i, label in ipairs({ "Summary", "Details", "Config" }) do
        local tab = CreateFrame("Button", "$parentTab" .. i, frame, "PanelTabButtonTemplate")
        tab:SetID(i)
        tab:SetText(label)
        tab:SetScript("OnClick", TabClick)
        if i == 1 then
            tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 5, 2)
        else
            tab:SetPoint("LEFT", frame.Tabs[i - 1], "RIGHT", -16, 0)
        end
        frame.Tabs[i] = tab
    end

    PanelTemplates_SetNumTabs(frame, 3)
    PanelTemplates_SetTab(frame, 1)
    PanelTemplates_UpdateTabs(frame)

    UpdateMinimapButton()

    frame:SetScript("OnShow", function()
        frame.selectedTab = 1
        PanelTemplates_SetTab(frame, 1)
        Refresh()
    end)
    SlashCmdList["ExpiryTracker"] = function() frame:Show() end
    SLASH_ExpiryTracker1 = "/etr"

end)
