EventUtil.ContinueOnAddOnLoaded("ExpiryTracker", function()
  local frame = CreateFrame("Frame", nil, UIParent, "ButtonFrameTemplate")
  frame:Hide()
  ButtonFrameTemplate_HidePortrait(frame)
  ButtonFrameTemplate_HideButtonBar(frame)
  frame.Inset:Hide()
  frame:RegisterForDrag("LeftButton")
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:SetUserPlaced(false)
  frame:SetToplevel(true)

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
  headerFrame.expiry:SetJustifyH("LEFT")
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
  view:SetElementExtent(20)
  view:SetElementInitializer("Frame", function(f, data)
    if not f.link then
      f.link = f:CreateFontString(nil, nil, "GameFontNormal")
      f.link:SetHeight(20)
      f.link:SetPoint("LEFT")
      f.link:SetWidth(350)
      f.link:SetJustifyH("LEFT")
      f.realm = f:CreateFontString(nil, nil, "GameFontHighlight")
      f.realm:SetHeight(20)
      f.realm:SetPoint("LEFT", f.link, "RIGHT")
      f.realm:SetWidth(150)
      f.realm:SetJustifyH("LEFT")
      f.character = f:CreateFontString(nil, nil, "GameFontNormal")
      f.character:SetHeight(20)
      f.character:SetPoint("LEFT", f.realm, "RIGHT")
      f.character:SetWidth(80)
      f.character:SetJustifyH("LEFT")
      f.expiry = f:CreateFontString(nil, nil, "GameFontHighlight")
      f.expiry:SetHeight(20)
      f.expiry:SetPoint("LEFT", f.character, "RIGHT")
      f.expiry:SetPoint("RIGHT")
      f.expiry:SetJustifyH("RIGHT")
    end
    f.link:SetText(data.itemLink .. " " .. LIGHTBLUE_FONT_COLOR:WrapTextInColorCode("x" .. data.itemCount))
    f.realm:SetText(data.realm)
    f.character:SetText(data.character)
    local text = GRAY_FONT_COLOR:WrapTextInColorCode("Unknown")
    if data.expirationTime ~= 0 then
      text = date("%c", data.expirationTime)
      if data.expirationTime <= currentTime then
        text = RED_FONT_COLOR:WrapTextInColorCode(text)
      elseif data.expirationTime - currentTime < 60 * 60 then
        text = ORANGE_FONT_COLOR:WrapTextInColorCode(text)
      end
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
      local auctions = CopyTable(c.auctions)
      for _, a in ipairs(auctions) do
        a.character = c.details.character
        a.realm = c.details.realm
        a.expirationTime = a.expirationTime or 0
      end
      tAppendAll(all, auctions)
    end

    table.sort(all, function(a, b)
      return a.expirationTime < b.expirationTime
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
