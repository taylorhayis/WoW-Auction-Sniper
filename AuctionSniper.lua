local ADDON_NAME = ...

local REFRESH_SLOWEST = 2.5
local REFRESH_OPTIONS = {
	{ label = "Slow (default)", seconds = 2.5 },
	{ label = "Medium", seconds = 1.5 },
	{ label = "Fast", seconds = 1.0 },
	{ label = "Fastest", seconds = 0.6 },
}

local function PriceSorts()
	local price = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
	return {
		{ sortOrder = price, reverseSort = false },
	}
end

local watch = {
	active = false,
	itemKey = nil,
	itemID = nil,
	isCommodity = false,
	itemName = "",
	icon = nil,
	maxCopper = 0,
	targetQty = 0,
	boughtQty = 0,
	qty = 0,
	unitPrice = nil,
	auctionID = nil,
	totalCopper = 0,
	canBuy = false,
	status = "Idle",
	showLog = false,
	autoPrice = true,
}

local session = {
	rows = {},
}

local pendingCommodity = nil
local lastSelectedKey = nil
local refreshTicker = nil
local attached = false
local hookedSelect = false
local armedAnnounced = false

local ui = {}
local StopWatch
local ShowSettings
local UpdateWatchPanel
local TryLoadSelectedItem
local panelOpen = false
local fillingPrice = false

local function SetPanelOpen(open, stopReason)
	local closing = panelOpen and not open
	panelOpen = open and true or false
	if ui.watch then
		ui.watch:SetShown(panelOpen)
	end
	if closing and watch.active then
		StopWatch(stopReason or "Stopped watching.")
	end
end

local function TogglePanel()
	if not ui.watch then
		return
	end
	if ui.watch:IsShown() then
		SetPanelOpen(false, "Panel closed. Stopped watching.")
	else
		SetPanelOpen(true)
		UpdateWatchPanel()
		if TryLoadSelectedItem then
			TryLoadSelectedItem(true)
		end
	end
end

local function EnsureDB()
	AuctionSniperDB = AuctionSniperDB or {}
	if type(AuctionSniperDB.refreshSeconds) ~= "number" then
		AuctionSniperDB.refreshSeconds = REFRESH_SLOWEST
	end
	local fastest = REFRESH_OPTIONS[#REFRESH_OPTIONS].seconds
	if AuctionSniperDB.refreshSeconds > REFRESH_SLOWEST then
		AuctionSniperDB.refreshSeconds = REFRESH_SLOWEST
	elseif AuctionSniperDB.refreshSeconds < fastest then
		AuctionSniperDB.refreshSeconds = fastest
	end
end

local function GetRefreshSeconds()
	EnsureDB()
	return AuctionSniperDB.refreshSeconds or REFRESH_SLOWEST
end

local function SetRefreshSeconds(seconds)
	EnsureDB()
	AuctionSniperDB.refreshSeconds = seconds
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffAuctionSniper|r: " .. msg)
end

-- Uses the built-in level-up ding. No custom sound file is required.
local function PlayDing()
	local sound = (SOUNDKIT and (SOUNDKIT.LEVELUPSOUND or SOUNDKIT.LEVELUP)) or 888
	PlaySound(sound, "Master")
end

local function CopyItemKey(itemKey)
	if not itemKey or not itemKey.itemID then
		return nil
	end
	return {
		itemID = itemKey.itemID,
		itemLevel = itemKey.itemLevel or 0,
		itemSuffix = itemKey.itemSuffix or 0,
		battlePetSpeciesID = itemKey.battlePetSpeciesID or 0,
	}
end

local function ItemKeysEqual(a, b)
	return a and b
		and a.itemID == b.itemID
		and (a.itemLevel or 0) == (b.itemLevel or 0)
		and (a.itemSuffix or 0) == (b.itemSuffix or 0)
		and (a.battlePetSpeciesID or 0) == (b.battlePetSpeciesID or 0)
end

local function MoneyString(copper)
	copper = math.max(0, math.floor(copper or 0))
	if GetCoinTextureString then
		return GetCoinTextureString(copper)
	end
	local gold = math.floor(copper / 10000)
	local silver = math.floor((copper % 10000) / 100)
	local c = copper % 100
	return string.format("%dg %ds %dc", gold, silver, c)
end

local function CompactMoney(copper)
	copper = math.max(0, math.floor(copper or 0))
	local gold = math.floor(copper / 10000)
	local silver = math.floor((copper % 10000) / 100)
	local c = copper % 100
	if gold > 0 then
		return string.format("%dg %ds %dc", gold, silver, c)
	end
	if silver > 0 then
		return string.format("%ds %dc", silver, c)
	end
	return string.format("%dc", c)
end

local function ParseMoney(goldBox, silverBox, copperBox)
	local gold = tonumber(goldBox:GetText()) or 0
	local silver = tonumber(silverBox:GetText()) or 0
	local copper = tonumber(copperBox:GetText()) or 0
	if silver > 99 or copper > 99 or gold < 0 or silver < 0 or copper < 0 then
		return nil, "Silver and copper must be 0-99."
	end
	local total = (gold * 10000) + (silver * 100) + copper
	if total < 0 then
		return nil, "Price cannot be negative."
	end
	return total
end

local function CopperParts(copper)
	copper = math.max(0, math.floor(copper or 0))
	return math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100
end

local function SetPriceBoxes(copper)
	if not ui.goldBox then
		return
	end
	fillingPrice = true
	local gold, silver, cop = CopperParts(copper or 0)
	ui.goldBox:SetText(tostring(gold))
	ui.silverBox:SetText(tostring(silver))
	ui.copperBox:SetText(tostring(cop))
	fillingPrice = false
end

local function GetCheapestUnitPrice()
	if not watch.itemKey then
		return nil
	end
	if watch.isCommodity then
		local count = C_AuctionHouse.GetNumCommoditySearchResults(watch.itemID)
		for i = 1, count do
			local result = C_AuctionHouse.GetCommoditySearchResultInfo(watch.itemID, i)
			if result and not result.containsOwnerItem and result.unitPrice then
				return result.unitPrice
			end
		end
	else
		local count = C_AuctionHouse.GetNumItemSearchResults(watch.itemKey)
		for i = 1, count do
			local result = C_AuctionHouse.GetItemSearchResultInfo(watch.itemKey, i)
			if result and not result.containsOwnerItem and result.buyoutAmount then
				return result.buyoutAmount / math.max(1, result.quantity or 1)
			end
		end
	end
	return nil
end

local function ApplyPriceFromBoxes()
	if not ui.goldBox then
		return
	end
	local copper = ParseMoney(ui.goldBox, ui.silverBox, ui.copperBox)
	if not copper then
		return
	end
	watch.maxCopper = copper
end

local function ApplyQtyFromBox()
	if not ui.qtyBox then
		return
	end
	local qty = math.floor(tonumber(ui.qtyBox:GetText()) or 0)
	if qty < 1 then
		qty = 1
	end
	watch.targetQty = qty
end

local function MaybeApplyDefaultPrice()
	if not watch.autoPrice then
		return
	end
	local cheapest = GetCheapestUnitPrice()
	if not cheapest or cheapest <= 0 then
		return
	end
	local cap = math.max(1, math.floor(cheapest / 2))
	watch.maxCopper = cap
	SetPriceBoxes(cap)
	watch.autoPrice = false
	Print("Default price set to half of cheapest (" .. CompactMoney(cap) .. "). You can change it on the panel.")
end

local function RemainingQty()
	return math.max(0, (watch.targetQty or 0) - (watch.boughtQty or 0))
end

local function ClearSessionLog()
	wipe(session.rows)
end

local function SessionTotals()
	local qty, spent = 0, 0
	for _, row in ipairs(session.rows) do
		qty = qty + (row.qty or 0)
		spent = spent + (row.totalCopper or 0)
	end
	local avg = 0
	if qty > 0 then
		avg = math.floor((spent / qty) + 0.5)
	end
	return qty, spent, avg
end

local function UpdatePurchaseLog()
	if not ui.logChild then
		return
	end

	local lineHeight = 13
	local width = ui.logScroll and ui.logScroll:GetWidth() or 200
	if width < 50 then
		width = 200
	end

	for i, data in ipairs(session.rows) do
		local row = ui.logLines[i]
		if not row then
			row = CreateFrame("Frame", nil, ui.logChild)
			row:SetHeight(lineHeight)
			row.qty = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.qty:SetPoint("LEFT", 2, 0)
			row.qty:SetWidth(36)
			row.qty:SetJustifyH("RIGHT")
			row.unit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.unit:SetPoint("LEFT", row.qty, "RIGHT", 8, 0)
			row.unit:SetWidth(70)
			row.unit:SetJustifyH("RIGHT")
			row.total = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.total:SetPoint("RIGHT", -2, 0)
			row.total:SetJustifyH("RIGHT")
			ui.logLines[i] = row
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -((i - 1) * lineHeight))
		row:SetSize(width, lineHeight)
		row.qty:SetText(tostring(data.qty))
		row.unit:SetText(CompactMoney(data.unitPrice))
		row.total:SetText(CompactMoney(data.totalCopper))
		row:Show()
	end
	for i = #session.rows + 1, #ui.logLines do
		ui.logLines[i]:Hide()
	end
	ui.logChild:SetWidth(width)
	ui.logChild:SetHeight(math.max(16, (#session.rows * lineHeight) + 2))

	local qty, spent, avg = SessionTotals()
	if qty > 0 then
		ui.logAverage:SetText("Avg  " .. CompactMoney(avg))
		ui.logSpent:SetText("Spent  " .. CompactMoney(spent))
	else
		ui.logAverage:SetText("Avg  --")
		ui.logSpent:SetText("Spent  --")
	end
end

local function SetButtonEnabled(button, enabled)
	if button.SetEnabled then
		button:SetEnabled(enabled)
	elseif enabled then
		button:Enable()
	else
		button:Disable()
	end
end

local function ThrottleReady()
	if C_AuctionHouse.IsThrottledMessageSystemReady then
		return C_AuctionHouse.IsThrottledMessageSystemReady()
	end
	return true
end

local function GetDisplayItemKey(display)
	if not display then
		return nil
	end
	if display.GetItemKey then
		local key = display:GetItemKey()
		if key and key.itemID then
			return CopyItemKey(key)
		end
	end
	if display.itemKey and display.itemKey.itemID then
		return CopyItemKey(display.itemKey)
	end
	if display.GetItemID then
		local itemID = display:GetItemID()
		if itemID and itemID > 0 then
			return C_AuctionHouse.MakeItemKey(itemID)
		end
	end
	return nil
end

local function GetSelectedItemKey()
	local ah = AuctionHouseFrame
	if not ah then
		return nil
	end

	if ah.CommoditiesBuyFrame and ah.CommoditiesBuyFrame:IsShown() then
		local itemID = ah.CommoditiesBuyFrame.GetItemID and ah.CommoditiesBuyFrame:GetItemID()
		if (not itemID or itemID == 0) and ah.CommoditiesBuyFrame.BuyDisplay then
			itemID = ah.CommoditiesBuyFrame.BuyDisplay:GetItemID()
		end
		if itemID and itemID > 0 then
			return C_AuctionHouse.MakeItemKey(itemID)
		end
	end

	if ah.ItemBuyFrame and ah.ItemBuyFrame:IsShown() then
		if ah.ItemBuyFrame.itemKey then
			return CopyItemKey(ah.ItemBuyFrame.itemKey)
		end
		local fromDisplay = GetDisplayItemKey(ah.ItemBuyFrame.ItemDisplay)
		if fromDisplay then
			return fromDisplay
		end
	end

	return CopyItemKey(lastSelectedKey)
end

local function ResolveItemInfo(itemKey, callback)
	local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
	if info then
		callback(info)
		return
	end

	local waiter = CreateFrame("Frame")
	local elapsed = 0
	waiter:RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")
	waiter:SetScript("OnEvent", function(self, _, receivedItemID)
		if receivedItemID == itemKey.itemID then
			local ready = C_AuctionHouse.GetItemKeyInfo(itemKey)
			if ready then
				self:UnregisterAllEvents()
				self:SetScript("OnUpdate", nil)
				callback(ready)
			end
		end
	end)
	waiter:SetScript("OnUpdate", function(self, dt)
		elapsed = elapsed + dt
		local ready = C_AuctionHouse.GetItemKeyInfo(itemKey)
		if ready then
			self:UnregisterAllEvents()
			self:SetScript("OnUpdate", nil)
			callback(ready)
		elseif elapsed > 3 then
			self:UnregisterAllEvents()
			self:SetScript("OnUpdate", nil)
			Print("Could not load item info. Try selecting the item again.")
		end
	end)
end

local function StopRefresh()
	if refreshTicker then
		refreshTicker:Cancel()
		refreshTicker = nil
	end
end

function UpdateWatchPanel()
	if not ui.watch then
		return
	end

	if not panelOpen then
		ui.watch:Hide()
		return
	end

	ui.watch:Show()

	if ui.priceButton then
		ui.priceButton:SetText("Load item")
	end

	if watch.itemName ~= "" or watch.active then
		if ui.watchIcon then
			ui.watchIcon:SetTexture(watch.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		end
		ui.watchName:SetText(watch.itemName ~= "" and watch.itemName or "Unknown item")
		ui.watchProgress:SetText(string.format("Progress: %d / %d", watch.boughtQty or 0, watch.targetQty or 0))
		if watch.unitPrice then
			ui.watchCheapest:SetText("Cheapest now: " .. MoneyString(watch.unitPrice))
		elseif watch.active then
			ui.watchCheapest:SetText("Cheapest now: scanning...")
		else
			ui.watchCheapest:SetText("Cheapest now: --")
		end
		ui.watchStatus:SetText(watch.status ~= "Idle" and watch.status or "Item loaded. Adjust price if you want, then wait for Buy.")
	else
		if ui.watchIcon then
			ui.watchIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
		end
		ui.watchName:SetText("No item selected")
		ui.watchProgress:SetText("Progress: --")
		ui.watchCheapest:SetText("Cheapest now: --")
		ui.watchStatus:SetText("Click an item in the auction house, then Load item.")
	end

	if watch.canBuy then
		ui.buyButton:SetText(string.format("Buy %d", watch.qty))
		SetButtonEnabled(ui.buyButton, true)
	else
		ui.buyButton:SetText("Buy")
		SetButtonEnabled(ui.buyButton, false)
	end

	UpdatePurchaseLog()
end

local function EvaluateListings()
	if not watch.active or not watch.itemKey then
		return
	end

	local remaining = RemainingQty()
	if watch.maxCopper > 0 and remaining <= 0 then
		StopWatch(string.format("Bought %d / %d. Target reached.", watch.boughtQty, watch.targetQty), true)
		return
	end

	watch.canBuy = false
	watch.qty = 0
	watch.unitPrice = nil
	watch.auctionID = nil
	watch.totalCopper = 0

	watch.unitPrice = GetCheapestUnitPrice()
	MaybeApplyDefaultPrice()

	if not watch.maxCopper or watch.maxCopper <= 0 then
		if watch.autoPrice then
			watch.status = "Item loaded. Waiting for listings to set a default price."
		else
			watch.status = "Enter a buy-under price on the panel."
		end
		UpdateWatchPanel()
		return
	end

	if watch.isCommodity then
		local count = C_AuctionHouse.GetNumCommoditySearchResults(watch.itemID)
		for i = 1, count do
			if watch.qty >= remaining then
				break
			end
			local result = C_AuctionHouse.GetCommoditySearchResultInfo(watch.itemID, i)
			if result and not result.containsOwnerItem and result.unitPrice and result.unitPrice <= watch.maxCopper then
				if not watch.unitPrice then
					watch.unitPrice = result.unitPrice
				end
				local take = math.min(result.quantity or 0, remaining - watch.qty)
				watch.qty = watch.qty + take
				watch.totalCopper = watch.totalCopper + ((result.unitPrice or 0) * take)
			elseif result and result.unitPrice then
				if not watch.unitPrice then
					watch.unitPrice = result.unitPrice
				end
				break
			end
		end
	else
		local count = C_AuctionHouse.GetNumItemSearchResults(watch.itemKey)
		for i = 1, count do
			local result = C_AuctionHouse.GetItemSearchResultInfo(watch.itemKey, i)
			if result and not result.containsOwnerItem and result.buyoutAmount then
				local stack = result.quantity or 1
				local unit = result.buyoutAmount / math.max(1, stack)
				if not watch.unitPrice then
					watch.unitPrice = unit
				end
				if unit <= watch.maxCopper and stack <= remaining then
					watch.qty = stack
					watch.auctionID = result.auctionID
					watch.totalCopper = result.buyoutAmount
					watch.unitPrice = unit
				end
				break
			end
		end
	end

	if watch.qty > 0 and watch.totalCopper > GetMoney() then
		watch.status = "Under cap, but you cannot afford it."
		watch.canBuy = false
	elseif watch.qty > 0 then
		watch.status = string.format("Listing under cap. Click Buy for %d more (%d / %d).", watch.qty, watch.boughtQty, watch.targetQty)
		watch.canBuy = true
		if not armedAnnounced then
			armedAnnounced = true
			PlayDing()
			FlashClientIcon()
			Print(string.format("Snipe ready: %s x%d at %s (%d / %d filled).", watch.itemName or "item", watch.qty, MoneyString(watch.unitPrice or 0), watch.boughtQty, watch.targetQty))
		end
	else
		armedAnnounced = false
		if watch.unitPrice then
			watch.status = string.format("Watching for %d more. Nothing under your cap yet.", remaining)
		else
			watch.status = string.format("Watching for %d more. Waiting for listings...", remaining)
		end
	end

	UpdateWatchPanel()
end

local function RequestRefresh()
	if not watch.active or not watch.itemKey then
		return
	end
	if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
		return
	end
	if not ThrottleReady() then
		watch.status = "AH busy, waiting to refresh..."
		UpdateWatchPanel()
		return
	end

	if C_AuctionHouse.HasSearchResults and C_AuctionHouse.HasSearchResults(watch.itemKey) then
		if watch.isCommodity then
			C_AuctionHouse.RefreshCommoditySearchResults(watch.itemID)
		else
			C_AuctionHouse.RefreshItemSearchResults(watch.itemKey)
		end
	else
		C_AuctionHouse.SendSearchQuery(watch.itemKey, PriceSorts(), false)
	end
end

local function StartRefresh()
	StopRefresh()
	RequestRefresh()
	refreshTicker = C_Timer.NewTicker(GetRefreshSeconds(), RequestRefresh)
end

function StopWatch(reason, keepPanel)
	watch.active = false
	watch.canBuy = false
	watch.showLog = keepPanel and true or false
	pendingCommodity = nil
	armedAnnounced = false
	StopRefresh()
	UpdateWatchPanel()
	if reason then
		Print(reason)
	end
end

local function OnBought(qty, unitPrice, totalCopper)
	qty = qty or 0
	unitPrice = unitPrice or watch.unitPrice or 0
	totalCopper = totalCopper or (unitPrice * qty)
	if qty > 0 then
		table.insert(session.rows, 1, {
			qty = qty,
			unitPrice = unitPrice,
			totalCopper = totalCopper,
		})
	end
	watch.boughtQty = (watch.boughtQty or 0) + qty
	armedAnnounced = false
	if watch.boughtQty >= (watch.targetQty or 0) then
		watch.status = string.format("Bought %d / %d. Target reached.", watch.boughtQty, watch.targetQty)
		StopWatch(watch.status, true)
		return
	end
	watch.status = string.format("Bought %d / %d. Still watching for %d more.", watch.boughtQty, watch.targetQty, RemainingQty())
	watch.canBuy = false
	UpdateWatchPanel()
	Print(string.format("Purchased %d at %s. %d / %d filled.", qty, MoneyString(unitPrice), watch.boughtQty, watch.targetQty))
	if watch.active then
		C_Timer.After(0.5, RequestRefresh)
	end
end

local function BindItem(itemKey, itemInfo)
	local sameItem = ItemKeysEqual(watch.itemKey, itemKey)
	watch.active = true
	watch.showLog = true
	watch.itemKey = CopyItemKey(itemKey)
	watch.itemID = itemKey.itemID
	watch.isCommodity = itemInfo.isCommodity and true or false
	watch.itemName = itemInfo.itemName or ("Item " .. itemKey.itemID)
	watch.icon = itemInfo.iconFileID
	if not sameItem then
		watch.boughtQty = 0
		ClearSessionLog()
		watch.autoPrice = true
		watch.maxCopper = 0
		watch.targetQty = 1
		SetPriceBoxes(0)
		if ui.qtyBox then
			fillingPrice = true
			ui.qtyBox:SetText("1")
			fillingPrice = false
		end
	end
	ApplyQtyFromBox()
	watch.qty = 0
	watch.unitPrice = nil
	watch.auctionID = nil
	watch.totalCopper = 0
	watch.canBuy = false
	watch.status = "Item loaded. Looking up the cheapest listing..."
	pendingCommodity = nil
	armedAnnounced = false
	SetPanelOpen(true)
	UpdateWatchPanel()
	StartRefresh()
	Print("Loaded " .. watch.itemName .. ". Price will default to half of the cheapest listing.")
end

local function TryBuy()
	if not watch.active or not watch.canBuy then
		return
	end
	if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
		Print("Open the auction house first.")
		return
	end

	if watch.isCommodity then
		pendingCommodity = {
			itemID = watch.itemID,
			quantity = watch.qty,
			maxCopper = watch.maxCopper,
			unitPrice = watch.unitPrice,
			totalCopper = watch.totalCopper,
		}
		C_AuctionHouse.StartCommoditiesPurchase(watch.itemID, watch.qty)
		watch.status = "Purchase started. Confirming..."
		watch.canBuy = false
		UpdateWatchPanel()
		return
	end

	if not watch.auctionID or not watch.totalCopper then
		Print("No auction selected to buy.")
		return
	end

	local bought = watch.qty
	C_AuctionHouse.PlaceBid(watch.auctionID, watch.totalCopper)
	Print("Buyout sent for " .. watch.itemName .. " at " .. MoneyString(watch.totalCopper))
	OnBought(bought, watch.unitPrice, watch.totalCopper)
end

local function ConfirmPendingCommodity(unitPrice)
	if not pendingCommodity or pendingCommodity.awaitingSuccess then
		return
	end
	if unitPrice and unitPrice > pendingCommodity.maxCopper then
		C_AuctionHouse.CancelCommoditiesPurchase()
		Print("Price jumped above your cap. Cancelled.")
		pendingCommodity = nil
		armedAnnounced = false
		watch.status = "Price jumped. Still watching."
		UpdateWatchPanel()
		return
	end
	local qty = pendingCommodity.quantity
	local paidUnit = unitPrice or pendingCommodity.unitPrice or watch.unitPrice or 0
	C_AuctionHouse.ConfirmCommoditiesPurchase(pendingCommodity.itemID, qty)
	Print("Buying " .. qty .. "x " .. (watch.itemName or "item") .. ".")
	pendingCommodity = {
		awaitingSuccess = true,
		quantity = qty,
		unitPrice = paidUnit,
		totalCopper = paidUnit * qty,
	}
end

function TryLoadSelectedItem(quiet)
	if not C_AuctionHouse then
		if not quiet then
			Print("This client does not have C_AuctionHouse.")
		end
		return
	end
	if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
		if not quiet then
			Print("Open the auction house first.")
		end
		return
	end

	local itemKey = GetSelectedItemKey()
	if not itemKey then
		if not quiet then
			Print("Click an item in the auction house, then press Load item.")
		end
		return
	end

	ResolveItemInfo(itemKey, function(itemInfo)
		BindItem(itemKey, itemInfo)
	end)
end

local function ApplyBackdrop(frame)
	if not frame.SetBackdrop then
		return
	end
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 8, right = 8, top = 8, bottom = 8 },
	})
	frame:SetBackdropColor(0, 0, 0, 0.9)
end

local function CreateMoneyBox(parent, width)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(width, 20)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetMaxLetters(7)
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	return box
end

local function RefreshSettingsChecks()
	if not ui.refreshChecks then
		return
	end
	local current = GetRefreshSeconds()
	for _, check in ipairs(ui.refreshChecks) do
		check:SetChecked(math.abs(check.seconds - current) < 0.01)
	end
end

function ShowSettings()
	if not ui.settings then
		return
	end
	RefreshSettingsChecks()
	ui.settings:Show()
end

local function CreateSettingsDialog()
	local frame = CreateFrame("Frame", "AuctionSniperSettingsDialog", UIParent, "BackdropTemplate")
	frame:SetSize(320, 230)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:Hide()
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	ApplyBackdrop(frame)
	tinsert(UISpecialFrames, frame:GetName())

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("AuctionSniper settings")

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hint:SetPoint("TOPLEFT", 24, -46)
	hint:SetPoint("RIGHT", -20, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText("Refresh speed. Slow is the default. Faster scans more often and may hit the AH throttle.")

	ui.refreshChecks = {}
	for i, opt in ipairs(REFRESH_OPTIONS) do
		local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
		check:SetPoint("TOPLEFT", 20, -68 - ((i - 1) * 24))
		check.seconds = opt.seconds
		local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		label:SetPoint("LEFT", check, "RIGHT", 2, 0)
		label:SetText(string.format("%s  (%.1fs)", opt.label, opt.seconds))
		check:SetScript("OnClick", function(self)
			SetRefreshSeconds(self.seconds)
			RefreshSettingsChecks()
			if watch.active then
				StartRefresh()
				Print("Refresh speed set to " .. opt.label .. ".")
			end
		end)
		ui.refreshChecks[i] = check
	end

	local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	close:SetSize(90, 22)
	close:SetPoint("BOTTOM", 0, 16)
	close:SetText("Close")
	close:SetScript("OnClick", function()
		frame:Hide()
	end)

	ui.settings = frame
end

local function CreateWatchPanel(parent)
	local frame = CreateFrame("Frame", "AuctionSniperWatchPanel", parent, "BackdropTemplate")
	frame:SetSize(280, 500)
	frame:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, 0)
	frame:Hide()
	ApplyBackdrop(frame)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", 0, -12)
	title:SetText("AuctionSniper")

	local priceBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	priceBtn:SetSize(120, 22)
	priceBtn:SetPoint("TOPLEFT", 16, -36)
	priceBtn:SetText("Load item")
	priceBtn:SetScript("OnClick", function()
		TryLoadSelectedItem(false)
	end)
	ui.priceButton = priceBtn

	local settingsBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	settingsBtn:SetSize(100, 22)
	settingsBtn:SetPoint("TOPRIGHT", -16, -36)
	settingsBtn:SetText("Settings")
	settingsBtn:SetScript("OnClick", ShowSettings)

	local icon = frame:CreateTexture(nil, "ARTWORK")
	icon:SetSize(28, 28)
	icon:SetPoint("TOPLEFT", 16, -66)
	ui.watchIcon = icon

	local name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
	name:SetPoint("RIGHT", -12, 0)
	name:SetJustifyH("LEFT")
	ui.watchName = name

	local priceLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	priceLabel:SetPoint("TOPLEFT", 16, -100)
	priceLabel:SetText("Buy at or under:")

	local goldBox = CreateMoneyBox(frame, 42)
	goldBox:SetPoint("TOPLEFT", 16, -118)
	local goldIcon = frame:CreateTexture(nil, "ARTWORK")
	goldIcon:SetSize(12, 12)
	goldIcon:SetPoint("LEFT", goldBox, "RIGHT", 1, 0)
	goldIcon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")

	local silverBox = CreateMoneyBox(frame, 32)
	silverBox:SetPoint("LEFT", goldIcon, "RIGHT", 8, 0)
	local silverIcon = frame:CreateTexture(nil, "ARTWORK")
	silverIcon:SetSize(12, 12)
	silverIcon:SetPoint("LEFT", silverBox, "RIGHT", 1, 0)
	silverIcon:SetTexture("Interface\\MoneyFrame\\UI-SilverIcon")

	local copperBox = CreateMoneyBox(frame, 32)
	copperBox:SetPoint("LEFT", silverIcon, "RIGHT", 8, 0)
	local copperIcon = frame:CreateTexture(nil, "ARTWORK")
	copperIcon:SetSize(12, 12)
	copperIcon:SetPoint("LEFT", copperBox, "RIGHT", 1, 0)
	copperIcon:SetTexture("Interface\\MoneyFrame\\UI-CopperIcon")

	local function OnPriceEdited()
		if fillingPrice then
			return
		end
		watch.autoPrice = false
		ApplyPriceFromBoxes()
		UpdateWatchPanel()
	end
	goldBox:SetScript("OnTextChanged", OnPriceEdited)
	silverBox:SetScript("OnTextChanged", OnPriceEdited)
	copperBox:SetScript("OnTextChanged", OnPriceEdited)
	goldBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	silverBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	copperBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

	ui.goldBox = goldBox
	ui.silverBox = silverBox
	ui.copperBox = copperBox

	local qtyLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	qtyLabel:SetPoint("TOPLEFT", 16, -144)
	qtyLabel:SetText("Quantity:")

	local qtyBox = CreateMoneyBox(frame, 50)
	qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 8, 0)
	qtyBox:SetMaxLetters(6)
	qtyBox:SetText("1")
	qtyBox:SetScript("OnTextChanged", function()
		if fillingPrice then
			return
		end
		ApplyQtyFromBox()
		UpdateWatchPanel()
	end)
	qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	ui.qtyBox = qtyBox

	local progress = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	progress:SetPoint("TOPLEFT", 16, -168)
	progress:SetPoint("RIGHT", -12, 0)
	progress:SetJustifyH("LEFT")
	ui.watchProgress = progress

	local cheapest = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	cheapest:SetPoint("TOPLEFT", 16, -184)
	cheapest:SetPoint("RIGHT", -12, 0)
	cheapest:SetJustifyH("LEFT")
	ui.watchCheapest = cheapest

	local status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	status:SetPoint("TOPLEFT", 16, -200)
	status:SetPoint("RIGHT", -12, 0)
	status:SetJustifyH("LEFT")
	ui.watchStatus = status

	local buy = CreateFrame("Button", "AuctionSniperBuyButton", frame, "UIPanelButtonTemplate")
	buy:SetSize(240, 24)
	buy:SetPoint("TOP", 0, -236)
	buy:SetText("Buy")
	SetButtonEnabled(buy, false)
	buy:SetScript("OnClick", TryBuy)
	ui.buyButton = buy

	local stop = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	stop:SetSize(240, 22)
	stop:SetPoint("TOP", 0, -264)
	stop:SetText("Stop watching")
	stop:SetScript("OnClick", function()
		StopWatch("Stopped watching.")
		UpdateWatchPanel()
	end)

	local logTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	logTitle:SetPoint("TOPLEFT", 16, -296)
	logTitle:SetText("Session purchases")

	local avg = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	avg:SetPoint("TOPLEFT", 16, -312)
	avg:SetText("Avg  --")
	ui.logAverage = avg

	local spent = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	spent:SetPoint("TOPRIGHT", -16, -312)
	spent:SetText("Spent  --")
	ui.logSpent = spent

	local headQty = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	headQty:SetPoint("TOPLEFT", 18, -328)
	headQty:SetWidth(36)
	headQty:SetJustifyH("RIGHT")
	headQty:SetText("Qty")

	local headUnit = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	headUnit:SetPoint("LEFT", headQty, "RIGHT", 8, 0)
	headUnit:SetWidth(70)
	headUnit:SetJustifyH("RIGHT")
	headUnit:SetText("Unit")

	local headTotal = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	headTotal:SetPoint("TOPRIGHT", -34, -328)
	headTotal:SetJustifyH("RIGHT")
	headTotal:SetText("Total")

	local scroll = CreateFrame("ScrollFrame", "AuctionSniperLogScroll", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -344)
	scroll:SetPoint("BOTTOMRIGHT", -32, 12)

	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(200, 20)
	scroll:SetScrollChild(child)
	ui.logChild = child
	ui.logLines = {}
	ui.logScroll = scroll

	ui.watch = frame
	UpdatePurchaseLog()
end

local function AttachToAuctionHouse()
	if attached or not AuctionHouseFrame then
		return
	end

	local button = CreateFrame("Button", "AuctionSniperAttachButton", AuctionHouseFrame, "UIPanelButtonTemplate")
	button:SetSize(120, 22)
	local close = AuctionHouseFrame.CloseButton or _G.AuctionHouseFrameCloseButton
	if close then
		button:SetPoint("RIGHT", close, "LEFT", -8, 0)
	else
		button:SetPoint("TOPRIGHT", AuctionHouseFrame, "TOPRIGHT", -40, -8)
	end
	button:SetText("AuctionSniper")
	button:SetFrameStrata("HIGH")
	button:SetScript("OnClick", TogglePanel)
	ui.snipeButton = button

	CreateWatchPanel(AuctionHouseFrame)
	attached = true

	if not hookedSelect then
		hooksecurefunc(AuctionHouseFrame, "SelectBrowseResult", function(_, browseResult)
			if browseResult and browseResult.itemKey then
				lastSelectedKey = CopyItemKey(browseResult.itemKey)
				if panelOpen then
					TryLoadSelectedItem(true)
				end
			end
		end)
		hookedSelect = true
	end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
eventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("COMMODITY_PRICE_UPDATED")
eventFrame:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE")
eventFrame:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
eventFrame:RegisterEvent("COMMODITY_PURCHASE_FAILED")
eventFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")

eventFrame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		local name = ...
		if name == ADDON_NAME then
			EnsureDB()
			CreateSettingsDialog()
			if AuctionHouseFrame then
				AttachToAuctionHouse()
			end
		elseif name == "Blizzard_AuctionHouseUI" then
			AttachToAuctionHouse()
		end
	elseif event == "AUCTION_HOUSE_SHOW" then
		if AuctionHouseFrame then
			AttachToAuctionHouse()
			if watch.active then
				StartRefresh()
			end
		else
			Print("AuctionHouseFrame was not found. This addon needs the Forever retail-style auction house, not the old Classic AH window.")
		end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		if ui.settings then
			ui.settings:Hide()
		end
		watch.showLog = false
		SetPanelOpen(false, "Auction house closed. Stopped watching.")
		UpdateWatchPanel()
	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		local itemID = ...
		if watch.active and watch.isCommodity and itemID == watch.itemID then
			EvaluateListings()
		end
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		local itemKey = ...
		if watch.active and not watch.isCommodity and ItemKeysEqual(itemKey, watch.itemKey) then
			EvaluateListings()
		end
	elseif event == "COMMODITY_PRICE_UPDATED" then
		local unitPrice = ...
		ConfirmPendingCommodity(unitPrice)
	elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
		if pendingCommodity then
			ConfirmPendingCommodity(nil)
		end
	elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
		if pendingCommodity then
			C_AuctionHouse.CancelCommoditiesPurchase()
			pendingCommodity = nil
			armedAnnounced = false
			watch.status = "That listing vanished. Still watching."
			UpdateWatchPanel()
			Print("Listing disappeared before confirm.")
		end
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		local pending = pendingCommodity
		pendingCommodity = nil
		local qty = pending and pending.awaitingSuccess and pending.quantity or 0
		if qty > 0 then
			OnBought(qty, pending.unitPrice, pending.totalCopper)
		else
			armedAnnounced = false
			watch.status = "Bought. Still watching."
			UpdateWatchPanel()
			if watch.active then
				C_Timer.After(0.5, RequestRefresh)
			end
		end
	elseif event == "COMMODITY_PURCHASE_FAILED" then
		pendingCommodity = nil
		armedAnnounced = false
		watch.status = "Buy failed. Still watching."
		UpdateWatchPanel()
		Print("Purchase failed.")
	end
end)

SLASH_AUCTIONSNIPER1 = "/as"
SLASH_AUCTIONSNIPER2 = "/auctionsniper"
SlashCmdList.AUCTIONSNIPER = function(msg)
	msg = strtrim(string.lower(msg or ""))
	if msg == "stop" then
		StopWatch("Stopped watching.")
	elseif msg == "settings" or msg == "config" then
		ShowSettings()
	elseif msg == "price" or msg == "load" then
		TryLoadSelectedItem(false)
	else
		TogglePanel()
	end
end

if not C_AuctionHouse then
	Print("C_AuctionHouse is missing. This addon needs the Forever / retail auction house API.")
end
