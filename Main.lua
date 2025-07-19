-- Future
local VERY_SOON, SOON = SECONDS_PER_HOUR * 1, SECONDS_PER_HOUR * 3
-- Past; rumors say that auctions will be deleted from the mailbox after 30 days
local RECENT, MAIL_EXPIRY = SECONDS_PER_DAY * 1, SECONDS_PER_DAY * 30

-- https://www.townlong-yak.com/framexml/live/Blizzard_SharedXML/TimeUtil.lua
local activeFormatter = CreateFromMixins(SecondsFormatterMixin)
activeFormatter:Init(
  SECONDS_PER_MIN, -- ApproximationSeconds
  SecondsFormatter.Abbreviation.Truncate, -- None, Truncate, OneLetter
  -- Prepend `Dont` to negate
  SecondsFormatterConstants.RoundUpLastUnit, -- Guarantee that the auction is expired at the shown time
  SecondsFormatterConstants.ConvertToLower, -- 'OneLetter' abbrev seems to be lowercase only
  SecondsFormatterConstants.RoundUpIntervals -- e.g. 1 day instead of 24 hr
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

EventUtil.ContinueOnAddOnLoaded("ExpiryTracker", function()
  local frame = CreateFrame("Frame", "ExpiryTrackerFrame", UIParent, "ButtonFrameTemplate")
  frame:Hide()
  ButtonFrameTemplate_HidePortrait(frame)
  ButtonFrameTemplate_HideButtonBar(frame)
  frame.Inset:Hide()
  frame:RegisterForDrag("LeftButton")
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:SetUserPlaced(false)
  frame:SetToplevel(true)
  tinsert(UISpecialFrames, frame:GetName()) -- Allow closing with Escape

  frame:SetScript("OnDragStart", function(self)
    self:StartMoving()
    self:SetUserPlaced(false)
  end)

  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false)
  end)

  frame:SetSize(800, 500)

  local currentTime

  local headerFrame = CreateFrame("Frame", nil, frame)
  headerFrame:SetPoint("TOPLEFT", 10, -30)
  headerFrame:SetPoint("TOPRIGHT", -10, -30)
  headerFrame:SetHeight(22)

  headerFrame.itemLink = headerFrame:CreateFontString(nil, nil, "GameFontNormal")
  headerFrame.itemLink:SetPoint("TOPLEFT")
  headerFrame.itemLink:SetWidth(350)
  headerFrame.itemLink:SetHeight(20)
  headerFrame.itemLink:SetJustifyH("LEFT")
  headerFrame.itemLink:SetText("Item Link")

  headerFrame.realm = headerFrame:CreateFontString(nil, nil, "GameFontNormal")
  headerFrame.realm:SetPoint("LEFT", headerFrame.itemLink, "RIGHT")
  headerFrame.realm:SetWidth(150)
  headerFrame.realm:SetHeight(20)
  headerFrame.realm:SetJustifyH("LEFT")
  headerFrame.realm:SetText("Realm")

  headerFrame.character = headerFrame:CreateFontString(nil, nil, "GameFontNormal")
  headerFrame.character:SetPoint("LEFT", headerFrame.realm, "RIGHT")
  headerFrame.character:SetWidth(80)
  headerFrame.character:SetHeight(20)
  headerFrame.character:SetJustifyH("LEFT")
  headerFrame.character:SetText("Character")

  headerFrame.expiry = headerFrame:CreateFontString(nil, nil, "GameFontNormal")
  headerFrame.expiry:SetPoint("LEFT", headerFrame.character, "RIGHT")
  headerFrame.expiry:SetPoint("RIGHT")
  headerFrame.expiry:SetHeight(20)
  headerFrame.expiry:SetJustifyH("RIGHT")
  headerFrame.expiry:SetText("Expiry Time")

  local divider = headerFrame:CreateTexture(nil, "ARTWORK")
  divider:SetTexture("Interface\\Common\\UI-TooltipDivider-Transparent")
  divider:SetPoint("BOTTOMLEFT")
  divider:SetPoint("BOTTOMRIGHT")
  divider:SetHeight(1)
  divider:SetColorTexture(0.93, 0.93, 0.93, 0.45)

  local scrollBox = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
  local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(14)
  view:SetElementInitializer("Frame", function(f, data)
    if not f.link then
      f.link = f:CreateFontString(nil, nil, "GameFontNormal")
      f.link:SetHeight(14)
      f.link:SetPoint("LEFT")
      f.link:SetWidth(350)
      f.link:SetJustifyH("LEFT")
      f.realm = f:CreateFontString(nil, nil, "GameFontHighlight")
      f.realm:SetHeight(14)
      f.realm:SetPoint("LEFT", f.link, "RIGHT")
      f.realm:SetWidth(150)
      f.realm:SetJustifyH("LEFT")
      f.character = f:CreateFontString(nil, nil, "GameFontNormal")
      f.character:SetHeight(14)
      f.character:SetPoint("LEFT", f.realm, "RIGHT")
      f.character:SetWidth(80)
      f.character:SetJustifyH("LEFT")
      f.expiry = f:CreateFontString(nil, nil, "GameFontHighlight")
      f.expiry:SetHeight(14)
      f.expiry:SetPoint("LEFT", f.character, "RIGHT")
      f.expiry:SetPoint("RIGHT")
      f.expiry:SetJustifyH("RIGHT")
    end
    f.link:SetText(data.itemLink .. " " .. LIGHTBLUE_FONT_COLOR:WrapTextInColorCode("x" .. data.itemCount))
    f.realm:SetText(data.realm)
    f.character:SetText(data.character)
    local text = GRAY_FONT_COLOR:WrapTextInColorCode("Unknown")
    if data.expirationTime ~= 0 then
      local remainingTime = data.expirationTime - currentTime
      local diff, color = abs(remainingTime), nil
      if remainingTime < 0 then -- Expired
        if diff < RECENT then
          text = format("%s ago", expiredFormatter:Format(diff))
        elseif diff < MAIL_EXPIRY then
          text = format("%s ago", longExpiredFormatter:Format(diff))
        else
          text = format("> %s days ago! - %s", MAIL_EXPIRY / SECONDS_PER_DAY, date("%b %Y", data.expirationTime))
        end
        color = diff > MAIL_EXPIRY - SECONDS_PER_DAY * 7 and RED_FONT_COLOR or WARNING_FONT_COLOR
      else -- Still active
        text = format("%s - %s", activeFormatter:Format(diff), date("%a %H:%M", data.expirationTime))
        color = diff < VERY_SOON and ORANGE_FONT_COLOR or diff < SOON and YELLOW_FONT_COLOR
      end
    if color then text = color:WrapTextInColorCode(text) end
    end
    f.expiry:SetText(text)
  end)
  
  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
  
  scrollBox:SetPoint("TOPLEFT", 10, -56)
  scrollBox:SetPoint("BOTTOMRIGHT", -40, 20)
  scrollBar:SetPoint("TOPRIGHT", -10, -56)
  scrollBar:SetPoint("BOTTOMRIGHT", -10, 20)

  frame:SetTitle("Auction Expiration Times")
  frame:EnableMouse(true)
  frame:SetPoint("CENTER")
  frame:SetScript("OnShow", function()
    local all = {}

    for _, name in ipairs(Syndicator.API.GetAllCharacters()) do
      local c = Syndicator.API.GetCharacter(name)
      if c.auctions then
        local auctions = CopyTable(c.auctions)
        for _, a in ipairs(auctions) do
          a.character = c.details.character
          a.realm = c.details.realm
          a.expirationTime = a.expirationTime or 0
        end
        tAppendAll(all, auctions)
      end
    end

    table.sort(all, function(a, b)
      if a.realm == b.realm then
        return a.expirationTime < b.expirationTime
      end
      return a.realm < b.realm
    end)

    currentTime = time()
    scrollBox:SetDataProvider(CreateDataProvider(all))
  end)

  SlashCmdList["ExpiryTracker"] = function()
    frame:Show()
  end
  SLASH_ExpiryTracker1 = "/etr"
  SLASH_ExpiryTracker2 = "/etr"
end)
