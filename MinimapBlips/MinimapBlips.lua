---@diagnostic disable: undefined-global, create-global
if not C_Minimap then
	DEFAULT_CHAT_FRAME:AddMessage("|cffff4444MinimapBlips:|r VanillaMinimapTracking not found. Addon disabled.")
	return
end

local ROW_HEIGHT = 18
local ROW_WIDTH  = 140
local PADDING    = 6
local BUTTON_EDGE_OFFSET = 3       -- how far past the minimap edge the button's centre sits
local DEFAULT_ANGLE = math.pi
local MENU_CLOSE_DELAY = 0.25       -- seconds the cursor may be off both button and menu

-- Cursor-over test used by the menu's auto-close. MouseIsOver is stock in 1.12, but fall back to
-- a manual rect check in case a client build or addon has removed it.
local function CursorOver(frame)
	if MouseIsOver then return MouseIsOver(frame) end
	local l, b, w, h = frame:GetLeft(), frame:GetBottom(), frame:GetWidth(), frame:GetHeight()
	if not l or not b then return false end
	local scale = frame:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	cx, cy = cx / scale, cy / scale
	return cx >= l and cx <= l + w and cy >= b and cy <= b + h
end

local NONE_ICON = "Interface\\AddOns\\MinimapBlips\\icons\\None"

local RAID_MARK_TYPE = "raid mark"
-- Skull = raid icon 8: col 3, row 1 of the 4x4 atlas (0.25 per cell).
local SKULL_TEXCOORD = { 0.75, 1.0, 0.25, 0.5 }

local function ApplyBlipIcon(texture, iconPath, blipType)
	texture:SetTexture(iconPath)
	if blipType == RAID_MARK_TYPE then
		texture:SetTexCoord(SKULL_TEXCOORD[1], SKULL_TEXCOORD[2], SKULL_TEXCOORD[3], SKULL_TEXCOORD[4])
	else
		texture:SetTexCoord(0, 1, 0, 1)
	end
end

-- Default icon set lives in the DLL now (see kBlipTypes in Blips.cpp); we
-- just read it back. The DLL pre-registers everything at module init, so
-- GetIconList is ready by the time this addon runs.
local ICONS = C_Minimap.GetIconList()
local NUM_BLIPS = table.getn(ICONS)

local button = CreateFrame("Button", "MinimapIconBlips", Minimap)

function button:ADDON_LOADED()
	MinimapBlipsUI = MinimapBlipsUI or {}

	self:SetWidth(32)
	self:SetHeight(32)
	self:SetFrameStrata("MEDIUM")
	self:RegisterForDrag("LeftButton")

	-- The button is always anchored to the Minimap itself, on its rim, and only its angle around
	-- the minimap is saved. Dragging swings it around the edge; it can't be pulled off the map.
	-- Older versions saved a free x/y offset (buttonPos) - convert that to an angle once.
	if MinimapBlipsUI.buttonPos and not MinimapBlipsUI.buttonAngle then
		local old = MinimapBlipsUI.buttonPos
		if old.x and old.y and (old.x ~= 0 or old.y ~= 0) then
			MinimapBlipsUI.buttonAngle = math.atan2(old.y, old.x)
		end
	end
	MinimapBlipsUI.buttonPos = nil

	local function PlaceButton(angle)
		local c, s = math.cos(angle), math.sin(angle)
		local half = Minimap:GetWidth() / 2
		local x, y
		if GetMinimapShape and GetMinimapShape() == "SQUARE" then
			-- Square minimaps (pfUI etc.): slide along the square's edge instead of a circle.
			local m = math.max(math.abs(c), math.abs(s))
			x, y = c / m * half, s / m * half
		else
			x, y = c * half, s * half
		end
		-- Push out so the button straddles the edge the way stock minimap buttons do.
		x = x + c * BUTTON_EDGE_OFFSET
		y = y + s * BUTTON_EDGE_OFFSET
		self:ClearAllPoints()
		self:SetPoint("CENTER", Minimap, "CENTER", x, y)
	end

	PlaceButton(MinimapBlipsUI.buttonAngle or DEFAULT_ANGLE)

	local border = self:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetWidth(53)
	border:SetHeight(53)
	border:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)

	local icon = self:CreateTexture(nil, "BACKGROUND")
	icon:SetWidth(20)
	icon:SetHeight(20)
	icon:SetPoint("CENTER", self, "CENTER", 0, 0)
	ApplyBlipIcon(icon, NONE_ICON)

	self:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local menu = CreateFrame("Frame", nil, UIParent)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	menu:SetWidth(ROW_WIDTH + PADDING * 2)
	-- Rows: "Clear All", each blip type, and the optional Questie shortcut.
	menu:SetHeight((NUM_BLIPS + 2) * ROW_HEIGHT + PADDING * 2)
	menu:SetBackdrop({
		bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile     = true,
		tileSize = 16,
		edgeSize = 16,
		insets   = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	menu:SetBackdropColor(0.09, 0.09, 0.09, 0.9)
	menu:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
	menu:Hide()

	-- Close the menu once the cursor has been away from both it and the button for a moment.
	-- The short delay lets the cursor cross the seam between the button and the menu without
	-- the menu flickering shut. OnUpdate only runs while the menu is shown.
	local awayTime = 0
	menu:SetScript("OnShow", function()
		awayTime = 0
	end)
	menu:SetScript("OnUpdate", function()
		if CursorOver(menu) or CursorOver(self) then
			awayTime = 0
			return
		end
		awayTime = awayTime + arg1
		if awayTime >= MENU_CLOSE_DELAY then
			menu:Hide()
		end
	end)
	self:RegisterEvent("MINIMAP_UPDATE_TRACKING")
	self:RegisterEvent("PLAYER_FOCUS_CHANGED")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:SetScript("OnEvent", function()
		if event == "MINIMAP_UPDATE_TRACKING" then
			ApplyBlipIcon(icon, NONE_ICON)
		elseif event == "PLAYER_FOCUS_CHANGED" then
			self:FOCUS_CHANGED()
		elseif event == "PLAYER_ENTERING_WORLD" then
			-- Fires on login, /reload and after every loading screen (zone / continent change,
			-- flight path hand-offs, etc.). The DLL only applies the saved per-character tracking
			-- config lazily, on the first C_Minimap call that needs it, so without this nothing
			-- is tracked until the menu happens to be opened. Calling it here applies the config
			-- and re-arms the DLL's hooks/icons if a UI teardown left them down. Idempotent.
			C_Minimap.GetTracked()
		end
	end)

	local function GenerateRows()
		if menu.rows then return end
		menu.rows = true
		local clearRow = CreateFrame("Button", nil, menu)
		clearRow:SetWidth(ROW_WIDTH)
		clearRow:SetHeight(ROW_HEIGHT)
		clearRow:SetPoint("TOPLEFT", menu, "TOPLEFT", PADDING, -PADDING)
		clearRow:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		local clearLabel = clearRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		clearLabel:SetPoint("CENTER", clearRow, "CENTER", 0, 0)
		clearLabel:SetText("Clear All")
		clearRow:SetScript("OnClick", function() C_Minimap.ClearAllTracking() end)

		local tracked = C_Minimap.GetTracked()
		for i, entry in ipairs(ICONS) do
			local row = CreateFrame("Button", nil, menu)
			row.blipType = entry.type
			row:SetWidth(ROW_WIDTH)
			row:SetHeight(ROW_HEIGHT)
			row:SetPoint("TOPLEFT", menu, "TOPLEFT", PADDING, -(PADDING + i * ROW_HEIGHT))
			row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

			row.check = row:CreateTexture(nil, "ARTWORK")
			row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
			row.check:SetWidth(14)
			row.check:SetHeight(14)
			row.check:SetPoint("LEFT", row, "LEFT", 0, 0)
			if not tracked[entry.type] then
				row.check:Hide()
			end

			local rowIcon = row:CreateTexture(nil, "ARTWORK")
			ApplyBlipIcon(rowIcon, entry.icon, entry.type)
			rowIcon:SetWidth(14)
			rowIcon:SetHeight(14)
			rowIcon:SetPoint("LEFT", row, "LEFT", 18, 0)

			local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			label:SetPoint("LEFT", row, "LEFT", 36, 0)
			label:SetText(entry.label)

			row:SetScript("OnClick", function()
				C_Minimap.Toggle(this.blipType)
			end)

			row:SetScript("OnEvent", function()
				if event == "MINIMAP_UPDATE_TRACKING" then
					if arg1 == "" or arg1 == this.blipType then
						if C_Minimap.IsTracked(this.blipType) then
							this.check:Show()
						else
							this.check:Hide()
						end
					end
				end
			end)
			row:RegisterEvent("MINIMAP_UPDATE_TRACKING")
		end

		local questieRow = CreateFrame("Button", nil, menu)
		questieRow:SetWidth(ROW_WIDTH)
		questieRow:SetHeight(ROW_HEIGHT)
		questieRow:SetPoint("TOPLEFT", menu, "TOPLEFT", PADDING, -(PADDING + (NUM_BLIPS + 1) * ROW_HEIGHT))
		questieRow:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

		local questieIcon = questieRow:CreateTexture(nil, "ARTWORK")
		questieIcon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
		questieIcon:SetWidth(14)
		questieIcon:SetHeight(14)
		questieIcon:SetPoint("LEFT", questieRow, "LEFT", 18, 0)

		local questieLabel = questieRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		questieLabel:SetPoint("LEFT", questieRow, "LEFT", 36, 0)
		questieLabel:SetText("Questie Options")

		questieRow:SetScript("OnClick", function()
			menu:Hide()
			if IsAddOnLoaded("!Questie") and Questie and Questie.OptionsForm_Display then
				Questie:OptionsForm_Display()
			else
				DEFAULT_CHAT_FRAME:AddMessage("|cffff4444MinimapBlips:|r Questie is not loaded.")
			end
		end)
	end

	self:SetScript("OnClick", function()
		if IsShiftKeyDown() then return end
		if menu:IsShown() then
			menu:Hide()
			return
		end
		GenerateRows()
		menu:ClearAllPoints()
		menu:SetPoint("TOPRIGHT", self, "TOPLEFT", 0, -5)
		menu:Show()
	end)

	local function FollowCursor()
		local mx, my = Minimap:GetCenter()
		if not mx then return end
		local scale = Minimap:GetEffectiveScale()
		local cx, cy = GetCursorPosition()
		local angle = math.atan2(cy / scale - my, cx / scale - mx)
		MinimapBlipsUI.buttonAngle = angle
		PlaceButton(angle)
	end

	self:SetScript("OnDragStart", function()
		if not IsShiftKeyDown() then return end
		GameTooltip:Hide()
		this:SetScript("OnUpdate", FollowCursor)
	end)

	self:SetScript("OnDragStop", function()
		this:SetScript("OnUpdate", nil)
	end)

	self:SetScript("OnEnter", function()
		GameTooltip:SetOwner(this, "ANCHOR_LEFT")
		GameTooltip:SetText("Minimap Blips")
		GameTooltip:AddLine("Shift-drag to move around the minimap.", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)

	self:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	self:UnregisterEvent("ADDON_LOADED")
end

function button:FOCUS_CHANGED()
	local unitGUID = UnitGUID('focus')
	if unitGUID then
		C_Minimap.SetFocusByGUID(unitGUID)
	else
		C_Minimap.ClearFocus()
	end
end

button:RegisterEvent("ADDON_LOADED")
button:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" and arg1 == "MinimapBlips" then
		this:ADDON_LOADED()
	end
end)

-- /mmb status: quick check for "my blips vanished" reports. If the tracked list is non-empty but
-- the visible count is 0 away from any matching NPC, the DLL's draw/enum path is the problem; if
-- the tracked list is empty, the per-character tracking state was lost.
SLASH_MINIMAPBLIPS1 = "/mmb"
SlashCmdList["MINIMAPBLIPS"] = function()
	local names = ""
	for k in pairs(C_Minimap.GetTracked()) do
		names = names .. (names == "" and "" or ", ") .. k
	end
	if names == "" then names = "(none)" end
	local visible = table.getn(C_Minimap.ListVisibleGUIDs())
	DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffMinimapBlips:|r tracking " .. names .. "; blips on minimap: " .. visible)
end
