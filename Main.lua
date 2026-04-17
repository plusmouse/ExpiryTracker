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
-- SavedVariables
-- Stores per-character: gold (coppers in mailbox) and oldestMailExpiry (unix time)
-- Both are populated by scanning the real mailbox when the player visits it.
-- Syndicator's c.mail only stores attached items, not money amounts or expiry,
-- so we must scan it ourselves via GetInboxHeaderInfo.
-- =============================================================================

ExpiryTrackerDB = ExpiryTrackerDB or {}

local function GetCharacterKey(name, realm)
    return (name or UnitName("player")) .. "-" .. (realm or GetRealmName())
end

local function ScanMailbox()
    local totalGold   = 0
    local oldestExpiry = 0
    local numItems    = GetInboxNumItems()

    for i = 1, numItems do
        -- GetInboxHeaderInfo returns:
        -- packageIcon, stationeryIcon, sender, subject, money, CODAmount,
        -- daysLeft, hasItem, isRead, wasRead, isPending
        local _, _, _, _, money, _, daysLeft = GetInboxHeaderInfo(i)

        if money and money > 0 then
            totalGold = totalGold + money
            -- daysLeft is a float (e.g. 29.5); convert to an absolute unix expiry time
            if daysLeft then
                local expiry = time() + floor(daysLeft * 86400)
                if oldestExpiry == 0 or expiry < oldestExpiry then
                    oldestExpiry = expiry
                end
            end
        end
    end

    return totalGold, oldestExpiry
end

local function UpdateMailboxData()
    local key = GetCharacterKey()
    ExpiryTrackerDB[key] = ExpiryTrackerDB[key] or {}
    local gold, oldestExpiry = ScanMailbox()
    ExpiryTrackerDB[key].gold            = gold
    ExpiryTrackerDB[key].oldestMailExpiry = oldestExpiry
    ExpiryTrackerDB[key].lastMailCheck   = time()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("MAIL_SHOW")
eventFrame:RegisterEvent("MAIL_INBOX_UPDATE")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        local key = GetCharacterKey()
        ExpiryTrackerDB[key] = ExpiryTrackerDB[key] or {}
    elseif event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE" then
        UpdateMailboxData()
    end
end)

-- =============================================================================
-- Tooltip helpers
-- AH pet listings store as battlepet: hyperlinks in Syndicator auction data.
-- BattlePetTooltip_Show(speciesID, level, quality, health, power, speed) is
-- the correct Blizzard global to call for these — it handles positioning itself.
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
        if speciesID and BattlePetTooltip_Show then
            BattlePetTooltip_Show(
                tonumber(speciesID),
                tonumber(level),
                tonumber(quality),
                tonumber(health),
                tonumber(power),
                tonumber(speed),
                owner,
                "ANCHOR_RIGHT"
            )
            return
        end
        -- Fallback: plain name
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:SetText(link:match("%[(.-)%]") or "Battle Pet")
        GameTooltip:Show()
    else
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        local ok = pcall(function() GameTooltip:SetHyperlink(link) end)
        if not ok then GameTooltip:SetText(link:match("%[(.-)%]") or "Unknown") end
        GameTooltip:Show()
    end
end

local function HideLinkTooltip(link)
    if GetLinkType(link) == "battlepet" then
        if BattlePetTooltip and BattlePetTooltip:IsShown()               then BattlePetTooltip:Hide() end
        if FloatingBattlePetTooltip and FloatingBattlePetTooltip:IsShown() then FloatingBattlePetTooltip:Hide() end
    end
    GameTooltip:Hide()
end

-- =============================================================================
-- UI
-- Summary columns:  Realm(0,250) Character(255,160) Expired(420,80) Active(505,80) Mailbox Gold(590,160)
-- Detail columns:   Item(0,310)  Realm(315,140)      Char(460,80)    Expiry(545,200)
-- =============================================================================

EventUtil.ContinueOnAddOnLoaded("ExpiryTracker", function()

    local frame = CreateFrame("Frame", "ExpiryTrackerFrame", UIParent, "ButtonFrameTemplate")
    frame:Hide()
    ButtonFrameTemplate_HidePortrait(frame)
    ButtonFrameTemplate_HideButtonBar(frame)
    frame:SetTitle("Auction Expiration Times")
    frame:SetSize(800, 500)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    tinsert(UISpecialFrames, frame:GetName())

    -- Dark inner panel: UI-Background-Rock-Tile is the correct tileable rock
    -- texture. SetBackdropColor multiplies the texture RGBA, so (1,1,1,1)
    -- = pure texture. The AH darkens it moderately; (0.6,0.5,0.4,1) gives
    -- a warm medium-dark result that matches the AH content panel tone.
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
    for i = 1, 5 do header.cols[i] = MakeHeaderCol() end

    local scrollBox = CreateFrame("Frame",      nil, frame, "WowScrollBoxList")
    local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
    scrollBox:SetPoint("TOPLEFT",     frame.Inset, "TOPLEFT",      5,  -5)
    scrollBox:SetPoint("BOTTOMRIGHT", frame.Inset, "BOTTOMRIGHT", -25,  5)
    scrollBar:SetPoint("TOPRIGHT",    frame.Inset, "TOPRIGHT",    -5,  -5)
    scrollBar:SetPoint("BOTTOMRIGHT", frame.Inset, "BOTTOMRIGHT", -5,   5)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(22)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    local summaryHeaders = {
        { offset = 0,   width = 250, text = "Realm"        },
        { offset = 255, width = 160, text = "Character"    },
        { offset = 420, width = 80,  text = "Expired"      },
        { offset = 505, width = 80,  text = "Active"       },
        { offset = 590, width = 160, text = "Mailbox Gold" },
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

    -------------------------------------------------------
    -- ROW SETUP
    -------------------------------------------------------

    local function EnsureStrings(f, count)
        if not f.v then f.v = {} end
        if not f.line then
            f.line = f:CreateTexture(nil, "BACKGROUND")
            f.line:SetHeight(1)
            f.line:SetColorTexture(1, 1, 1, 0.2)
            f.line:SetPoint("LEFT",  f, "LEFT",  0, 0)
            f.line:SetPoint("RIGHT", f, "RIGHT", 0, 0)
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
        EnsureStrings(f, 5)
        f.linkBtn:Hide()
        f.line:SetShown(data.isSpacer)

        local v = f.v
        v[1]:SetPoint("LEFT",   0, 0)  v[1]:SetWidth(250)
        v[2]:SetPoint("LEFT", 255, 0)  v[2]:SetWidth(160)
        v[3]:SetPoint("LEFT", 420, 0)  v[3]:SetWidth(80)
        v[4]:SetPoint("LEFT", 505, 0)  v[4]:SetWidth(80)
        v[5]:SetPoint("LEFT", 590, 0)  v[5]:SetWidth(160)

        if data.isSpacer then
            v[1]:SetText("") v[2]:SetText("") v[3]:SetText("") v[4]:SetText("") v[5]:SetText("")
        elseif data.isTotal then
            v[1]:SetText("|cff00ccffTotals|r")
            v[2]:SetText("")
            v[3]:SetText(data.expired > 0 and RED_FONT_COLOR:WrapTextInColorCode(BreakUpLargeNumbers(data.expired))  or DASH)
            v[4]:SetText(data.active  > 0 and GREEN_FONT_COLOR:WrapTextInColorCode(BreakUpLargeNumbers(data.active)) or DASH)
            v[5]:SetText(FormatGoldWithCommas(data.gold))
        else
            local charKey  = GetCharacterKey(data.character, data.realm)
            local dbEntry  = ExpiryTrackerDB[charKey]
            local goldText = (dbEntry and dbEntry.gold and dbEntry.gold > 0)
                             and FormatGoldWithCommas(dbEntry.gold)
                             or  DASH
            local nameColor = data.expired > 0 and RED_FONT_COLOR or HIGHLIGHT_FONT_COLOR
            v[1]:SetText(nameColor:WrapTextInColorCode(data.realm))
            v[2]:SetText(nameColor:WrapTextInColorCode(data.character))
            v[3]:SetText(data.expired > 0 and RED_FONT_COLOR:WrapTextInColorCode(data.expired)   or DASH)
            v[4]:SetText(data.active  > 0 and GREEN_FONT_COLOR:WrapTextInColorCode(data.active)  or DASH)
            v[5]:SetText(goldText)
        end
    end

    local function DetailInit(f, data)
        EnsureStrings(f, 4)
        f.line:Hide()

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
            -- oldestMailExpiry: expiry of the soonest-expiring mail that contains gold,
            -- calculated from daysLeft at the time of last mailbox scan
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
            f.linkBtn:SetAllPoints(v[1])
            f.linkBtn.link = data.itemLink
        end
    end

    -------------------------------------------------------
    -- REFRESH
    -------------------------------------------------------

    local function Refresh()
        currentTime = time()
        local details, summary = {}, {}
        local totalExp, totalAct, totalGold = 0, 0, 0

        for _, name in ipairs(Syndicator.API.GetAllCharacters()) do
            local c = Syndicator.API.GetCharacter(name)
            if c then
                local realm    = c.details.realm     or "Unknown"
                local charName = c.details.character or "Unknown"
                local charKey  = charName .. "-" .. realm
                local charData = { realm = realm, character = charName, expired = 0, active = 0 }
                local hasAuctions = false

                if c.auctions then
                    for _, a in ipairs(c.auctions) do
                        hasAuctions = true
                        local auction          = CopyTable(a)
                        auction.realm          = realm
                        auction.character      = charName
                        auction.expirationTime = auction.expirationTime or 0
                        tinsert(details, auction)
                        if auction.expirationTime > 0 then
                            if auction.expirationTime < currentTime then
                                charData.expired = charData.expired + 1
                                totalExp         = totalExp + 1
                            else
                                charData.active = charData.active + 1
                                totalAct        = totalAct + 1
                            end
                        end
                    end
                end

                -- Mailbox gold: stored by ExpiryTrackerDB when player visits mailbox.
                -- oldestMailExpiry is computed from GetInboxHeaderInfo daysLeft at scan time.
                local goldEntry = ExpiryTrackerDB[charKey]
                if goldEntry and goldEntry.gold and goldEntry.gold > 0 then
                    totalGold = totalGold + goldEntry.gold
                    tinsert(details, {
                        isMailbox      = true,
                        character      = charName,
                        realm          = realm,
                        gold           = goldEntry.gold,
                        expirationTime = goldEntry.oldestMailExpiry or 0,
                    })
                end

                if hasAuctions or (goldEntry and goldEntry.gold and goldEntry.gold > 0) then
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

    -------------------------------------------------------
    -- TABS
    -------------------------------------------------------

    local function TabClick(self)
        PanelTemplates_SetTab(frame, self:GetID())
        frame.selectedTab = self:GetID()
        Refresh()
    end

    frame.Tabs = {}
    for i, label in ipairs({ "Summary", "Details" }) do
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

    PanelTemplates_SetNumTabs(frame, 2)
    PanelTemplates_SetTab(frame, 1)

    frame:SetScript("OnShow", Refresh)
    SlashCmdList["ExpiryTracker"] = function() frame:Show() end
    SLASH_ExpiryTracker1 = "/etr"

end)
