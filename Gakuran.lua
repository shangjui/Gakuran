--[[ ============================================================================
     Gakuran Standalone
     ----------------------------------------------------------------------------
     从 Moon Loader 里剥离出来的 Gakuran 功能，独立可跑，不依赖原 Loader 的框架。

     包含：
       - 执行器兼容别名层（原 Loader 顶部那些 FindFirstChild / Connect / Spawn 等）
       - 一个轻量自绘 UI（复刻原 Loader 的 CreateTab / CreateModule / CreateToggle / CreateSlider 接口）
       - 完整的 Gakuran 功能段

     已应用的修复（相对原始源码）：
       1. fn86（Auto Parry 心跳）—— 原源码是 `local function fn86(...) end` 空壳，这里按本段
          已有的 fn68/69/70/76/77/79/81/82 重建
       2. SuppressBlocking 钩子分支反了 —— 已按同级 GuardBroken / PerfectBlocked 的结构修正
       3. 顶部 WaitForChild + 裸 require 链无超时 —— 改为带超时的 gkFind + pcall 的 gkRequire
       4. M1.Hold / Block.* / CombatConfig.* 加 nil 保护

     注意：
       - "Evasive On Attack" 和 "Inf Stamina" 在原始源码里就是空壳，本脚本保持原样（未实现）
       - 需要执行器环境（hookfunction / getgc / debug.getinfo / gethui 等）
   ============================================================================ ]]

-- ============================ 1. 执行器兼容别名 ============================

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Lighting          = game:GetService("Lighting")
local Workspace         = game:GetService("Workspace")
local CoreGui           = game:GetService("CoreGui")
local LocalPlayer       = Players.LocalPlayer

local function FindFirstChild(parent, name)
	if not parent or not name then
		return nil
	end
	return parent:FindFirstChild(name)
end

local function FindFirstChildOfClass(parent, className)
	if not parent or not className then
		return nil
	end
	return parent:FindFirstChildOfClass(className)
end

local function GetPlayerList()
	return Players:GetPlayers()
end

local function Connect(signal, callback)
	if not signal then
		return nil
	end
	return signal:Connect(callback)
end

local function Disconnect(connection)
	if connection then
		connection:Disconnect()
	end
end

local function GetAttribute(instance, name)
	if not instance then
		return nil
	end
	return instance:GetAttribute(name)
end

local function SetAttribute(instance, name, value)
	if not instance then
		return
	end
	instance:SetAttribute(name, value)
end

local Spawn = task.spawn
local Wait  = task.wait

local Clamp  = math.clamp
local Rad    = math.rad
local Sin    = math.sin
local Cos    = math.cos
local Abs    = math.abs
local Atan2  = math.atan2
local Format = string.format

local NewVector3 = Vector3.new
local NewCFrame   = CFrame.new
local NewColor3   = Color3.new
local NewUDim2    = UDim2.new
local NewInstance = Instance.new

-- 原 Loader 里 Luraph VM 展开后的兼容 shim
local function luraph_runtime1(fn)
	return fn
end

-- ============================ 2. 轻量 UI ============================

local THEME = {
	Bg     = Color3.fromRGB(18, 20, 26),
	Card   = Color3.fromRGB(26, 29, 37),
	Row    = Color3.fromRGB(33, 37, 46),
	Accent = Color3.fromRGB(88, 132, 255),
	On     = Color3.fromRGB(48, 209, 88),
	Text   = Color3.fromRGB(238, 240, 246),
	Sub    = Color3.fromRGB(146, 153, 168),
	Border = Color3.fromRGB(44, 49, 61),
}

local L10N = {
	["gakuran"]                            = "学兰",
	["gakuran-auto-parry"]                 = "自动格挡",
	["gakuran-auto-parry-auto-equip"]      = "自动装备",
	["gakuran-auto-parry-face-target"]     = "面向攻击者",
	["gakuran-auto-parry-face-angle"]      = "面向角度(度)",
	["gakuran-auto-parry-attack-distance"] = "攻击距离",
	["gakuran-auto-parry-range"]           = "范围",
	["gakuran-auto-parry-anim-progress"]   = "动画进度(%)",
	["gakuran-auto-parry-visuals"]         = "视觉",
	["gakuran-no-block-cd"]                = "攻击时闪避",
	["gakuran-no-guardbroken"]             = "无破防",
	["gakuran-no-perfectblocked"]          = "无完美格挡",
	["gakuran-no-suppressblocking"]        = "无压制格挡",
	["gakuran-no-stun"]                    = "无硬直",
	["gakuran-no-windup-recovery"]         = "无前摇后摇",
	["gakuran-inf-stamina"]                = "无限体力",
	["gakuran-instant-respawn"]            = "瞬重生",
	["gakuran-instant-respawn-hp"]         = "生命阈值",
	["gakuran-no-screen-blur"]             = "无屏幕模糊",
}

local function label(opts)
	return L10N[opts.Id] or opts.Name or "?"
end

local function new(className, props, children)
	local inst = NewInstance(className)

	for k, v in pairs(props or {}) do
		inst[k] = v
	end

	for _, c in ipairs(children or {}) do
		c.Parent = inst
	end

	return inst
end

local function corner(radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius or 8) })
end

local function padding(p)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, p),
		PaddingBottom = UDim.new(0, p),
		PaddingLeft = UDim.new(0, p),
		PaddingRight = UDim.new(0, p),
	})
end

local GUI_PARENT = (function()
	if type(gethui) == "function" then
		local ok, hui = pcall(gethui)

		if ok and hui then
			return hui
		end
	end

	return CoreGui
end)()

local screen = new("ScreenGui", {
	Name = "GakuranStandalone",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = GUI_PARENT,
})

if type(syn) == "table" and type(syn.protect_gui) == "function" then
	pcall(syn.protect_gui, screen)
end

-- ---------- Window ----------

local Window = {}
Window.__index = Window

function Window:Notify(opts)
	local title = opts.Title or "Gakuran"
	local text = opts.Content or ""
	local duration = opts.Duration or 4

	local card = new("Frame", {
		Size = NewUDim2(0, 300, 0, 62),
		Position = NewUDim2(1, -320, 0, 20),
		BackgroundColor3 = THEME.Card,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		ZIndex = 50,
		Parent = screen,
	}, {
		corner(10),
		padding(10),
	})

	new("TextLabel", {
		Size = NewUDim2(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = THEME.Accent,
		Text = title,
		ZIndex = 51,
		Parent = card,
	})

	new("TextLabel", {
		Position = NewUDim2(0, 0, 0, 20),
		Size = NewUDim2(1, 0, 1, -20),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = THEME.Text,
		Text = text,
		ZIndex = 51,
		Parent = card,
	})

	task.delay(duration, function()
		if card and card.Parent then
			card:Destroy()
		end
	end)

	return card
end

function Window:CreateTab(opts)
	local tab = setmetatable({
		Window = self,
		Name = opts.Name,
		Id = opts.Id,
		Modules = {},
	}, { __index = self })

	-- 左侧标签按钮
	local button = new("TextButton", {
		Size = NewUDim2(1, 0, 0, 34),
		BackgroundColor3 = THEME.Accent,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = #self.TabOrder + 1,
		Parent = self.Nav,
	}, {
		corner(8),
	})

	local text = new("TextLabel", {
		Size = NewUDim2(1, -20, 1, 0),
		Position = NewUDim2(0, 10, 0, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = THEME.Sub,
		Text = label(opts),
		Parent = button,
	})

	self.TabOrder[#self.TabOrder + 1] = tab
	self.Tabs[opts.Id or opts.Name] = tab

	tab.Button = button
	tab.ButtonText = text

	button.MouseButton1Click:Connect(function()
		self:SelectTab(tab)
	end)

	if not self.ActiveTab then
		self:SelectTab(tab)
	end

	return tab
end

function Window:SelectTab(tab)
	self.ActiveTab = tab

	for _, t in ipairs(self.TabOrder) do
		local active = t == tab
		t.Button.BackgroundTransparency = active and 0.75 or 1
		t.ButtonText.TextColor3 = active and THEME.Text or THEME.Sub
		t.Content.Visible = active
	end
end

-- ---------- Tab ----------

local Tab = {}
Tab.__index = Tab

function Tab:CreateModule(opts)
	local enabled = opts.Default == true or opts.Enabled == true

	local card = new("Frame", {
		Size = NewUDim2(1, -12, 0, 40),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = THEME.Card,
		BorderSizePixel = 0,
		LayoutOrder = #self.Modules + 1,
		Parent = self.Body,
	}, {
		corner(10),
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
		padding(6),
	})

	local header = new("TextButton", {
		Size = NewUDim2(1, 0, 0, 32),
		BackgroundColor3 = THEME.Row,
		BackgroundTransparency = 0.2,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = 1,
		Parent = card,
	}, { corner(8) })

	local nameLabel = new("TextLabel", {
		Position = NewUDim2(0, 10, 0, 0),
		Size = NewUDim2(1, -70, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = THEME.Text,
		Text = label(opts),
		Parent = header,
	})

	-- 开关
	local switch = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = NewUDim2(1, -8, 0.5, 0),
		Size = NewUDim2(0, 38, 0, 20),
		BackgroundColor3 = enabled and THEME.On or Color3.fromRGB(60, 65, 78),
		BorderSizePixel = 0,
		Parent = header,
	}, { corner(10) })

	local knob = new("Frame", {
		Size = NewUDim2(0, 16, 0, 16),
		Position = enabled and NewUDim2(1, -18, 0.5, -8) or NewUDim2(0, 2, 0.5, -8),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 0,
		Parent = switch,
	}, { corner(8) })

	local module = setmetatable({
		Tab = self,
		Enabled = enabled,
		Callback = opts.Callback,
		Card = card,
		Controls = {},
	}, { __index = self })

	local function apply(state, silent)
		module.Enabled = state
		switch.BackgroundColor3 = state and THEME.On or Color3.fromRGB(60, 65, 78)
		knob.Position = state and NewUDim2(1, -18, 0.5, -8) or NewUDim2(0, 2, 0.5, -8)

		if not silent and module.Callback then
			local ok, err = pcall(module.Callback, state)

			if not ok then
				warn("[Gakuran] module callback error: " .. tostring(err))
			end
		end
	end

	module.Set = apply

	header.MouseButton1Click:Connect(function()
		apply(not module.Enabled)
	end)

	self.Modules[#self.Modules + 1] = module

	if enabled and module.Callback then
		task.spawn(module.Callback, true)
	end

	return module
end

-- ---------- Module 控件 ----------

local Module = {}
Module.__index = Module

function Module:CreateToggle(opts)
	local value = opts.Default == true

	local row = new("Frame", {
		Size = NewUDim2(1, 0, 0, 28),
		BackgroundColor3 = THEME.Row,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		LayoutOrder = #self.Controls + 2,
		Parent = self.Card,
	}, { corner(6) })

	new("TextLabel", {
		Position = NewUDim2(0, 10, 0, 0),
		Size = NewUDim2(1, -70, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = THEME.Sub,
		Text = label(opts),
		Parent = row,
	})

	local box = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = NewUDim2(1, -10, 0.5, 0),
		Size = NewUDim2(0, 18, 0, 18),
		BackgroundColor3 = value and THEME.On or Color3.fromRGB(60, 65, 78),
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Parent = row,
	}, { corner(5) })

	local control = { Value = value }
	control.Set = function(state)
		control.Value = state
		box.BackgroundColor3 = state and THEME.On or Color3.fromRGB(60, 65, 78)
	end

	box.MouseButton1Click:Connect(function()
		control.Set(not control.Value)

		if opts.Callback then
			local ok, err = pcall(opts.Callback, control.Value)

			if not ok then
				warn("[Gakuran] toggle callback error: " .. tostring(err))
			end
		end
	end)

	self.Controls[#self.Controls + 1] = control
	return control
end

function Module:CreateSlider(opts)
	local min = opts.Min or 0
	local max = opts.Max or 100
	local step = opts.Step or 1
	local value = opts.Default or min

	local row = new("Frame", {
		Size = NewUDim2(1, 0, 0, 40),
		BackgroundColor3 = THEME.Row,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		LayoutOrder = #self.Controls + 2,
		Parent = self.Card,
	}, { corner(6) })

	new("TextLabel", {
		Position = NewUDim2(0, 10, 0, 4),
		Size = NewUDim2(1, -70, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = THEME.Sub,
		Text = label(opts),
		Parent = row,
	})

	local valueLabel = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = NewUDim2(1, -10, 0, 4),
		Size = NewUDim2(0, 60, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = THEME.Text,
		Text = tostring(value),
		Parent = row,
	})

	local track = new("Frame", {
		Position = NewUDim2(0, 10, 0, 26),
		Size = NewUDim2(1, -20, 0, 6),
		BackgroundColor3 = Color3.fromRGB(52, 57, 70),
		BorderSizePixel = 0,
		Parent = row,
	}, { corner(3) })

	local fill = new("Frame", {
		Size = NewUDim2((value - min) / math.max(max - min, 1e-6), 0, 1, 0),
		BackgroundColor3 = THEME.Accent,
		BorderSizePixel = 0,
		Parent = track,
	}, { corner(3) })

	local hit = new("TextButton", {
		Size = NewUDim2(1, 0, 0, 18),
		Position = NewUDim2(0, 0, 0.5, -9),
		BackgroundTransparency = 1,
		Text = "",
		Parent = track,
	})

	local control = { Value = value }

	local function setValue(v, silent)
		v = math.clamp(v, min, max)

		if step and step > 0 then
			v = min + math.floor((v - min) / step + 0.5) * step
			v = math.clamp(v, min, max)
		end

		control.Value = v
		valueLabel.Text = (step < 1) and Format("%.2f", v) or tostring(math.floor(v + 0.5))
		fill.Size = NewUDim2((v - min) / math.max(max - min, 1e-6), 0, 1, 0)

		if not silent and opts.Callback then
			local ok, err = pcall(opts.Callback, v)

			if not ok then
				warn("[Gakuran] slider callback error: " .. tostring(err))
			end
		end
	end

	control.Set = setValue
	setValue(value, true)

	local dragging = false

	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
		end
	end)

	hit.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	RunService.RenderStepped:Connect(function()
		if not dragging then
			return
		end

		local mouse = game:GetService("UserInputService"):GetMouseLocation()
		local abs = track.AbsolutePosition
		local size = track.AbsoluteSize.X

		if size <= 0 then
			return
		end

		setValue(min + (mouse.X - abs.X) / size * (max - min))
	end)

	self.Controls[#self.Controls + 1] = control
	return control
end

-- ---------- 构建窗口 ----------

local function buildWindow(title)
	local root = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = NewUDim2(0.5, 0, 0.5, 0),
		Size = NewUDim2(0, 520, 0, 380),
		BackgroundColor3 = THEME.Bg,
		BorderSizePixel = 0,
		Active = true,
		Parent = screen,
	}, {
		corner(12),
		new("UIStroke", { Color = THEME.Border, Thickness = 1 }),
	})

	local header = new("Frame", {
		Size = NewUDim2(1, 0, 0, 40),
		BackgroundColor3 = THEME.Card,
		BorderSizePixel = 0,
		Parent = root,
	}, { corner(12) })

	new("TextLabel", {
		Position = NewUDim2(0, 14, 0, 0),
		Size = NewUDim2(1, -60, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = THEME.Text,
		Text = title,
		Parent = header,
	})

	local close = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = NewUDim2(1, -12, 0.5, 0),
		Size = NewUDim2(0, 24, 0, 24),
		BackgroundColor3 = Color3.fromRGB(232, 74, 74),
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Text = "×",
		Parent = header,
	}, { corner(12) })

	close.MouseButton1Click:Connect(function()
		screen.Enabled = false
	end)

	local body = new("Frame", {
		Position = NewUDim2(0, 0, 0, 40),
		Size = NewUDim2(1, 0, 1, -40),
		BackgroundTransparency = 1,
		Parent = root,
	})

	local nav = new("Frame", {
		Size = NewUDim2(0, 150, 1, 0),
		BackgroundColor3 = THEME.Card,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Parent = body,
	}, {
		corner(10),
		padding(8),
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	})

	local content = new("Frame", {
		Position = NewUDim2(0, 158, 0, 0),
		Size = NewUDim2(1, -166, 1, 0),
		BackgroundTransparency = 1,
		Parent = body,
	})

	local window = setmetatable({
		Root = root,
		Nav = nav,
		Content = content,
		Tabs = {},
		TabOrder = {},
		ActiveTab = nil,
	}, Window)

	-- 拖动
	local dragging, dragStart, startPos = false, nil, nil

	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = root.Position
		end
	end)

	header.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	game:GetService("UserInputService").InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local delta = input.Position - dragStart
			root.Position = NewUDim2(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end)

	return window
end

local v14 = buildWindow("Gakuran  |  Standalone")

-- ============================ 3. Gakuran 功能段 ============================
local function Gakuran()
	-- 安全解析：原来整条链用的是无超时 WaitForChild + 裸 require，
	-- 任意一层缺失都会让整个 handler 卡死或抛错（被 runHandler 的 pcall
	-- 捕获后直接 Load failed），表现为"Gakuran 功能全都没用"。
	-- 这里改成带超时的查找 + pcall require，缺谁都不会拖死整个 handler。
	local function gkFind(parent, name, timeout)
		if not parent then
			return nil
		end

		local child = FindFirstChild(parent, name)

		if child or not timeout then
			return child
		end

		local ok, result = pcall(WaitForChild, parent, name, timeout)
		return ok and result or nil
	end

	local function gkRequire(module)
		if not module then
			return nil
		end

		local ok, result = pcall(require, module)
		return ok and result or nil
	end

	local shared = gkFind(ReplicatedStorage, "Shared", 10)
	local server = gkFind(gkFind(ReplicatedStorage, "Remotes", 10), "Server", 5)
	local CombatConfig = gkRequire(gkFind(gkFind(shared, "Config", 5), "CombatConfig", 5))
	local base = gkFind(gkFind(gkFind(ReplicatedStorage, "CombatSystemClient", 10), "Combat", 5), "Base", 5)
	local Block = gkRequire(gkFind(base, "Block", 5))
	local Evasive = gkRequire(gkFind(base, "Evasive", 5))
	local M1 = gkRequire(gkFind(base, "M1", 5))
	gkRequire(gkFind(base, "M2", 5))
	gkRequire(gkFind(base, "Equip", 5))
	local v27 = v14:CreateTab({ Id = "gakuran", Name = "Gakuran" })
	local v28 = nil
	local v29 = nil
	local v30 = nil

	for _, v31 in getgc(true) do
		if typeof(v31) == "function" then
			local v32 = debug.getinfo(v31)

			if v32.name == "GuardBroken" then
				local v33 = nil
				local v34 = hookfunction

				local v35 = luraph_runtime1(function(...)
					local v35 = table.pack(...)
					if not v28 then
						return v33(...)
					end
					local tbl10 = { ... }
					local character = LocalPlayer.Character
					if character and tbl10[2] == character then
						print("No GuardBroken")
						return
					end
					return v33(table.unpack(v35, 1, v35.n))
				end)

				v33 = v34
				v33 = v33(v31, v35)
			elseif v32.name == "PerfectBlocked" then
				local v33 = nil
				local v34 = hookfunction

				local v35 = luraph_runtime1(function(...)
					local v35 = table.pack(...)
					if not v29 then
						return v33(...)
					end
					local tbl10 = { ... }
					local character = LocalPlayer.Character
					if character and tbl10[1] == character then
						print("No PerfectBlocked")
						return
					end
					return v33(table.unpack(v35, 1, v35.n))
				end)

				v33 = v34
				v33 = v33(v31, v35)
			elseif v32.name == "SuppressBlocking" then
				local v33 = nil
				local v34 = hookfunction

				local v35 = luraph_runtime1(function(...)
					if not v30 then
						return v33(...)
					end
					print("No SuppressBlocking")
					return
				end)

				v33 = v34
				v33 = v33(v31, v35)
			end
		end
	end

	local tbl10 = {
		Enabled = false,
		Range = 30,
		AttackDistance = 10,
		FaceAngle = 80,
		AutoEquip = true,
		FaceTarget = true,
		Visuals = true,
		AnimThreshold = 0,
	}

	local flag = false
	local tbl11 = {}
	local tbl12 = {}
	local v31 = nil
	local n4 = 0.25
	local n5 = 0
	local n6 = 0

	local function fn68(arg, arg2)
		local tbl13 = {}
		local position = arg.Position
		local n7 = arg2 * arg2
		local v32 = GetPlayerList()

		for i = 1, #v32 do
			local v33 = v32[i]

			if v33 ~= LocalPlayer then
				local character = v33.Character

				if character and character.Parent then
					local v34 = FindFirstChildOfClass(character, "Humanoid")
					local v35 = v34 and FindFirstChild(character, "HumanoidRootPart")

					if v34 and v34.Health > 0 and v35 then
						local n8 = v35.Position - position

						if n8.X * n8.X + n8.Y * n8.Y + n8.Z * n8.Z <= n7 then
							tbl13[#tbl13 + 1] = character
						end
					end
				end
			end
		end

		return tbl13
	end

	local function fn69(arg)
		return GetAttribute(arg, "CombatAttacking") == true
	end

	local function fn70(arg, arg2, arg3)
		local v32 = FindFirstChild(arg, "HumanoidRootPart")
		if not v32 or arg2[v32] then
			return
		end
		local tbl13 = {}

		tbl13[#tbl13 + 1] = Connect(v32.ChildAdded, function(arg4)
			if arg4.Name ~= "PunchSwing" then
				return
			end
			local character = LocalPlayer.Character
			local v33 = character and FindFirstChild(character, "HumanoidRootPart")
			if not (arg.Parent and v32.Parent and character and character.Parent and v33) then
				return
			end
			arg3(v32, v33)
		end)

		tbl13[#tbl13 + 1] = Connect(arg.AttributeChanged, function(arg4)
			if arg4 ~= "CombatAttacking" or GetAttribute(arg, arg4) ~= true then
				return
			end
			local character = LocalPlayer.Character
			local v33 = character and FindFirstChild(character, "HumanoidRootPart")
			if not (arg.Parent and v32.Parent and character and character.Parent and v33) then
				return
			end
			arg3(v32, v33)
		end)

		arg2[v32] = tbl13
	end

	local function fn71(arg)
		for k, v32 in pairs(arg) do
			if not k.Parent then
				for i = 1, #v32 do
					Disconnect(v32[i])
				end

				arg[k] = nil
			end
		end
	end

	local function fn72(arg)
		for _, v32 in pairs(arg) do
			for i = 1, #v32 do
				Disconnect(v32[i])
			end
		end

		table.clear(arg)
	end

	local function fn73()
		local character = LocalPlayer.Character
		if not (character and character.Parent) then
			return
		end
		server:FireServer({ Type = "Combat", Action = "Block", Func = "Activated" }, Workspace:GetServerTimeNow())
		flag = true
	end

	local function fn74()
		if not flag then
			return
		end
		local character = LocalPlayer.Character

		if character and character.Parent then
			server:FireServer({ Type = "Combat", Action = "Block", Func = "Deactivated" })
		end

		flag = false
	end

	local tbl13 = {}

	local function fn75(arg)
		local v32 = FindFirstChildOfClass(arg, "Humanoid")
		return v32 and FindFirstChildOfClass(v32, "Animator")
	end

	local function fn76(arg)
		if tbl13[arg] then
			return
		end
		local v32 = fn75(arg)
		if not v32 then
			return
		end
		local tbl14 = { track = nil }

		tbl14.conn = Connect(v32.AnimationPlayed, function(track)
			tbl14.track = track
		end)

		tbl13[arg] = tbl14
	end

	local function fn77(arg)
		local v32 = tbl13[arg]
		local track = v32 and v32.track

		if track and track.IsPlaying then
			local length = track.Length
			if length > 0 then
				return Clamp(track.TimePosition / length, 0, 1) * 100
			end
		end

		if not (v32 and GetAttribute(arg, "CombatAttacking") == true) then
			return nil
		end
		local v33 = fn75(arg)
		if not v33 then
			return nil
		end
		local playingAnimationTracks = v33:GetPlayingAnimationTracks()

		for i = 1, #playingAnimationTracks do
			local v34 = playingAnimationTracks[i]

			if v34.IsPlaying and not v34.Looped then
				v32.track = v34
				local length = v34.Length
				if length > 0 then
					return Clamp(v34.TimePosition / length, 0, 1) * 100
				end
				return nil
			end
		end

		return nil
	end

	local function fn78()
		for _, v32 in pairs(tbl13) do
			if v32.conn then
				Disconnect(v32.conn)
			end
		end

		table.clear(tbl13)
	end

	local function fn79()
		if flag then
			return
		end
		fn73()
	end

	local n7 = 8
	local n8 = 0.08
	local transparency = 0.7
	local v32 = nil

	local function fn80()
		if v32 and v32.Parent then
			return v32
		end
		local Folder = NewInstance("Folder")
		Folder.Name = "GakuranParryVisuals"
		Folder.Parent = Workspace
		v32 = Folder
		return Folder
	end

	local function fn81()
		local v33 = fn80()
		local tbl14 = { edges = {}, arc = {}, groundY = nil, groundAt = 0 }

		for i = 1, 2 do
			local Part = NewInstance("Part")
			Part.Name = "GakuranParryEdge"
			Part.Anchored = true
			Part.CanCollide = false
			Part.CanQuery = false
			Part.CanTouch = false
			Part.CastShadow = false
			Part.Material = Enum.Material.Neon
			Part.Color = NewColor3(1, 1, 1)
			Part.Transparency = transparency
			Part.Size = NewVector3(0.08, 0.08, 1)
			Part.Parent = v33
			tbl14.edges[i] = Part
		end

		for i = 1, 8 do
			local Part = NewInstance("Part")
			Part.Name = "GakuranParryArc"
			Part.Anchored = true
			Part.CanCollide = false
			Part.CanQuery = false
			Part.CanTouch = false
			Part.CastShadow = false
			Part.Material = Enum.Material.Neon
			Part.Color = NewColor3(1, 1, 1)
			Part.Transparency = transparency
			Part.Size = NewVector3(0.08, 0.08, 1)
			Part.Parent = v33
			tbl14.arc[i] = Part
		end

		local BillboardGui = NewInstance("BillboardGui")
		BillboardGui.Name = "GakuranParryLabel"
		BillboardGui.Size = NewUDim2(0, 80, 0, 24)
		BillboardGui.AlwaysOnTop = true
		BillboardGui.StudsOffset = NewVector3(0, -2, 0)
		local TextLabel = NewInstance("TextLabel")
		TextLabel.Size = NewUDim2(1, 0, 1, 0)
		TextLabel.BackgroundTransparency = 1
		TextLabel.TextColor3 = NewColor3(1, 1, 1)
		TextLabel.TextStrokeTransparency = 0.2
		TextLabel.TextSize = 14
		TextLabel.Font = Enum.Font.GothamBold
		TextLabel.Parent = BillboardGui
		BillboardGui.Parent = v33
		tbl14.billboard = BillboardGui
		tbl14.label = TextLabel
		return tbl14
	end

	local function fn82(H,m,h)local B=FindFirstChild(H,"HumanoidRootPart");if not B then return;end;local t= tbl10 .AttackDistance;local x=m.groundY;if not x or h-(m.groundAt or 0)>= n4 then x=B.Position.Y-3;m.groundY=x;m.groundAt=h;elseif Abs(B.Position.Y-3-x)>4 then x=B.Position.Y-3;m.groundY=x;m.groundAt=h;end;H,h=NewVector3(B.Position.X,x,B.Position.Z),B.CFrame.LookVector;local R=Atan2(h.X,h.Z);local O=Rad( tbl10 .FaceAngle)*0.5;for k=1,2,1 do h=R-O+2*O*(k-1);local j,i=NewVector3(Sin(h),0,Cos(h)),m.edges[k];i.Size=NewVector3( n8 , n8 ,t);i.CFrame=NewCFrame(H+j*(t*0.5),H+j*t);end;local k=nil;for j=0, n7 ,1 do h=j/ n7 ;x=R-O+2*O*h;local h=H+NewVector3(Sin(x),0,Cos(x))*t;if k then local H,x=m.arc[j],(k+h)*0.5;H.Size=NewVector3( n8 , n8 ,(h-k).Magnitude);H.CFrame=NewCFrame(x,h);end;k=h;end;m.label.Text=Format("%.1f",t);m.billboard.Adornee=B;end

	local function fn83(arg)
		for i = 1, #arg.edges do
			arg.edges[i]:Destroy()
		end

		for i = 1, #arg.arc do
			arg.arc[i]:Destroy()
		end

		arg.billboard:Destroy()
	end

	local function fn84()
		for _, v33 in pairs(tbl12) do
			fn83(v33)
		end

		table.clear(tbl12)

		if v32 then
			v32:Destroy()
			v32 = nil
		end
	end

	local function fn85()
		if v31 then
			Disconnect(v31)
			v31 = nil
		end
	end

	-- Auto Parry 心跳。
	-- 原代码这里是从 Ohio 段复制过来的农场循环，引用了 Gakuran 作用域里
	-- 根本不存在的 fn97 / fn103 / tbl22~24，导致 Auto Parry 完全失效，
	-- 而且每次 Heartbeat 都会新起一个必炸的协程。
	-- 下面按本段已有的 fn68/69/70/76/77/79/81/82 重建：
	--   找范围内的攻击者 -> 挂钩其出拳 -> 到动画阈值就触发格挡 + 面向 + 画视觉
	local fn86 = function()
		if not tbl10.Enabled then
			return
		end

		local character = LocalPlayer.Character
		local localRoot = character and FindFirstChild(character, "HumanoidRootPart")

		if not (character and character.Parent and localRoot) then
			fn84()
			return
		end

		local now = Clock()
		local targets = fn68(localRoot, tbl10.Range)

		for i = 1, #targets do
			local target = targets[i]
			local targetRoot = FindFirstChild(target, "HumanoidRootPart")

			if targetRoot then
				if not tbl11[targetRoot] then
					fn76(target)

					fn70(target, tbl11, function(hitRoot, selfRoot)
						if not tbl10.Enabled then
							return
						end

						if tbl10.FaceTarget and selfRoot and hitRoot then
							local offset = hitRoot.Position - selfRoot.Position

							if offset.Magnitude > 0.01 then
								selfRoot.CFrame = NewCFrame(selfRoot.Position, selfRoot.Position + NewVector3(offset.X, 0, offset.Z))
							end
						end

						local progress = fn77(target)
						local hitTime = Clock()

						if (not progress or progress >= tbl10.AnimThreshold) and hitTime - n5 > 0.15 then
							n5 = hitTime
							fn79()
						end
					end)
				end

				if tbl10.Visuals then
					local visual = tbl12[targetRoot]

					if not visual then
						visual = fn81()
						tbl12[targetRoot] = visual
					end

					fn82(target, visual, now)
				end
			end
		end

		fn71(tbl11)

		if not tbl10.Visuals then
			fn84()
		end
	end
	local v33 = v27:CreateModule({
		Id = "gakuran-auto-parry",
		Name = "Auto Parry",
		Callback = function(enabled)
			tbl10.Enabled = enabled

			if enabled then
				fn85()
				n5 = 0
				n6 = 0
				v31 = Connect(RunService.Heartbeat, fn86)
			else
				fn85()
				fn72(tbl11)
				fn78()
				fn74()
				fn84()
			end
		end,
	})

	v33:CreateToggle({
		Id = "gakuran-auto-parry-auto-equip",
		Name = "Auto Equip",
		Default = tbl10.AutoEquip,
		Callback = function(autoEquip)
			tbl10.AutoEquip = autoEquip
		end,
	})

	v33:CreateToggle({
		Id = "gakuran-auto-parry-face-target",
		Name = "Face Attacker",
		Default = tbl10.FaceTarget,
		Callback = function(faceTarget)
			tbl10.FaceTarget = faceTarget
		end,
	})

	v33:CreateSlider({
		Id = "gakuran-auto-parry-face-angle",
		Name = "Face Angle (deg)",
		Min = 10,
		Max = 180,
		Default = tbl10.FaceAngle,
		Step = 5,
		Callback = function(faceAngle)
			tbl10.FaceAngle = faceAngle
		end,
	})

	v33:CreateSlider({
		Id = "gakuran-auto-parry-attack-distance",
		Name = "Attack Distance",
		Min = 1,
		Max = 20,
		Default = tbl10.AttackDistance,
		Step = 0.5,
		Callback = function(attackDistance)
			tbl10.AttackDistance = attackDistance
		end,
	})

	v33:CreateSlider({
		Id = "gakuran-auto-parry-range",
		Name = "Range (studs)",
		Min = 1,
		Max = 30,
		Default = tbl10.Range,
		Step = 1,
		Callback = function(range)
			tbl10.Range = range
		end,
	})

	v33:CreateSlider({
		Id = "gakuran-auto-parry-anim-progress",
		Name = "Anim Progress (%)",
		Min = 0,
		Max = 100,
		Default = tbl10.AnimThreshold,
		Step = 5,
		Callback = function(animThreshold)
			tbl10.AnimThreshold = animThreshold
		end,
	})

	v33:CreateToggle({
		Id = "gakuran-auto-parry-visuals",
		Name = "Visuals",
		Default = tbl10.Visuals,
		Callback = function(visuals)
			tbl10.Visuals = visuals

			if not visuals then
				fn84()
			end
		end,
	})

	local v34 = nil
	local flag2 = false
	local v35 = nil
	local v36 = hookfunction
	local hold = M1 and M1.Hold

	local v37 = luraph_runtime1(function(arg)
		flag2 = arg == "Start" and true or false
		return v35(arg)
	end)

	v35 = v36

	if hold then
		v35 = v35(hold, v37)
	end

	v27:CreateModule({
		Id = "gakuran-no-block-cd",
		Name = "Evasive On Attack",
		Callback = function(arg)
			v34 = arg
			Spawn(function(...) end)
		end,
	})

	v27:CreateModule({
		Id = "gakuran-no-guardbroken",
		Name = "No GuardBroken",
		Callback = function(arg)
			v28 = arg
		end,
	})

	v27:CreateModule({
		Id = "gakuran-no-perfectblocked",
		Name = "No Perfect Blocked",
		Callback = function(arg)
			v29 = arg
		end,
	})

	v27:CreateModule({
		Id = "gakuran-no-suppressblocking",
		Name = "No Suppress Blocking",
		Callback = function(arg)
			v30 = arg
		end,
	})

	local tbl14 = { Enabled = false, SavedParriedStun = nil, SavedGuardbreak = nil }

	v27:CreateModule({
		Id = "gakuran-no-stun",
		Name = "No Stun",
		Callback = function(enabled)
			tbl14.Enabled = enabled

			if enabled then
				if Block and not tbl14.SavedParriedStun then
					tbl14.SavedParriedStun = Block.ApplyLocalParriedStun
					tbl14.SavedGuardbreak = Block.ApplyLocalGuardbreakLockout

					Block.ApplyLocalParriedStun = function()
					end

					Block.ApplyLocalGuardbreakLockout = function()
					end
				end

				Spawn(function()
					while tbl14.Enabled and Wait() do
						local character = LocalPlayer.Character

						if character and character.Parent then
							local tbl15 = { "Stunned", "Parried", "CantAnything", "GuardBroken" }

							for i = 1, #tbl15 do
								local v38 = tbl15[i]

								if GetAttribute(character, v38) == true then
									SetAttribute(character, v38, nil)
								end
							end
						end
					end
				end)
			elseif Block and tbl14.SavedParriedStun then
				Block.ApplyLocalParriedStun = tbl14.SavedParriedStun
				Block.ApplyLocalGuardbreakLockout = tbl14.SavedGuardbreak
				tbl14.SavedParriedStun = nil
				tbl14.SavedGuardbreak = nil
			end
		end,
	})

	local tbl15 = { Enabled = false, Saved = {} }

	v27:CreateModule({
		Id = "gakuran-no-windup-recovery",
		Name = "No Windup No Recovery",
		Callback = function(enabled)
			tbl15.Enabled = enabled

			if enabled then
				if not CombatConfig then
					return
				end

				if next(tbl15.Saved) == nil then
					tbl15.Saved.M1Recovery = CombatConfig.M1.RecoveryLockout
					tbl15.Saved.M1Finisher = CombatConfig.M1.FinisherRecoveryLockout
					tbl15.Saved.M2Recovery = CombatConfig.M2.RecoveryLockout
					tbl15.Saved.AttackDuration = CombatConfig.ClientPredict.M1.AttackDuration
					tbl15.Saved.ComboResetTime = CombatConfig.ClientPredict.M1.ComboResetTime
					tbl15.Saved.FinisherCooldown = CombatConfig.ClientPredict.M1.FinisherCooldown
				end

				CombatConfig.M1.RecoveryLockout = 0
				CombatConfig.M1.FinisherRecoveryLockout = 0
				CombatConfig.M2.RecoveryLockout = 0
				CombatConfig.ClientPredict.M1.AttackDuration = 0
				CombatConfig.ClientPredict.M1.ComboResetTime = 0
				CombatConfig.ClientPredict.M1.FinisherCooldown = 0

				Spawn(function()
					while tbl15.Enabled and Wait() do
						local character = LocalPlayer.Character

						if character and character.Parent then
							local tbl16 = { "CombatAttacking", "M1Cooldown", "M2Cooldown" }

							for i = 1, #tbl16 do
								local v38 = tbl16[i]

								if GetAttribute(character, v38) == true then
									SetAttribute(character, v38, nil)
								end
							end
						end
					end
				end)
			elseif CombatConfig and next(tbl15.Saved) ~= nil then
				CombatConfig.M1.RecoveryLockout = tbl15.Saved.M1Recovery
				CombatConfig.M1.FinisherRecoveryLockout = tbl15.Saved.M1Finisher
				CombatConfig.M2.RecoveryLockout = tbl15.Saved.M2Recovery
				CombatConfig.ClientPredict.M1.AttackDuration = tbl15.Saved.AttackDuration
				CombatConfig.ClientPredict.M1.ComboResetTime = tbl15.Saved.ComboResetTime
				CombatConfig.ClientPredict.M1.FinisherCooldown = tbl15.Saved.FinisherCooldown
			end
		end,
	})

	local tbl16 = { Enabled = false, Max = 100 }

	v27:CreateModule({
		Id = "gakuran-inf-stamina",
		Name = "Inf Stamina",
		Callback = function(enabled)
			tbl16.Enabled = enabled

			if enabled then
				Spawn(function(...) end)
			end
		end,
	})

	local tbl17 = { Enabled = false, HpThreshold = 30, TeleportHeight = 100000 }
	local tbl18 = { pos = nil, phase = "normal" }
	local v38 = nil

	local function fn87(arg)
		if not arg then
			return
		end
		arg.PlatformStand = false
		arg.Sit = false

		pcall(function()
			local state_ = arg:GetState()

			if state_ == Enum.HumanoidStateType.Physics or state_ == Enum.HumanoidStateType.FallingDown or state_ == Enum.HumanoidStateType.Ragdoll then
				arg:ChangeState(Enum.HumanoidStateType.GettingUp)
			end
		end)
	end

	local function fn88()
		local pos = tbl18.pos

		Spawn(function()
			local character = LocalPlayer.Character
			local v39 = character and FindFirstChild(character, "HumanoidRootPart")
			local n9 = 0

			while not (character and character.Parent and v39) and n9 < 5 do
				Wait()
				character = LocalPlayer.Character
				v39 = character and FindFirstChild(character, "HumanoidRootPart")
				n9 += 1
			end

			if not (character and character.Parent and v39) then
				tbl18.phase = "normal"
				tbl18.pos = nil
				return
			end

			Wait(0.5)

			while tbl17.Enabled and tbl18.pos do
				Wait()
				local v40 = FindFirstChildOfClass(character, "Humanoid")
				local v41 = FindFirstChild(character, "HumanoidRootPart")
				if not (character.Parent and v41 and v40) then
					return
				end
				fn87(v40)

				pcall(function()
					v40:ChangeState(Enum.HumanoidStateType.Running)
				end)

				v41.CFrame = NewCFrame(pos)

				if (v41.Position - pos).Magnitude < 5 then
					tbl18.phase = "normal"
					tbl18.pos = nil
					return
				end
			end

			tbl18.phase = "normal"
			tbl18.pos = nil
		end)
	end

	v27:CreateModule({
		Id = "gakuran-instant-respawn",
		Name = "Instant Respawn",
		Callback = function(enabled)
			tbl17.Enabled = enabled

			if enabled then
				tbl18.phase = "normal"
				tbl18.pos = nil

				v38 = Connect(LocalPlayer.CharacterAdded, function()
					if not tbl17.Enabled or not tbl18.pos then
						return
					end
					tbl18.phase = "return"
					fn88()
				end)

				Spawn(function()
					while tbl17.Enabled and Wait() do
						pcall(function()
							local character = LocalPlayer.Character
							local v39 = character and FindFirstChildOfClass(character, "Humanoid")
							local v40 = character and FindFirstChild(character, "HumanoidRootPart")
							if not (character and character.Parent and v39 and v40) then
								return
							end
							fn87(v39)

							if tbl18.phase == "normal" then
								if tbl17.HpThreshold <= v39.Health then
									tbl18.pos = v40.Position
								elseif v39.Health > 0 then
									tbl18.pos = v40.Position
									tbl18.phase = "teleport"
								end
							elseif tbl18.phase == "teleport" and tbl18.pos then
								v40.CFrame = NewCFrame(tbl18.pos.X, tbl17.TeleportHeight, tbl18.pos.Z)
							end
						end)
					end
				end)
			else
				if v38 then
					Disconnect(v38)
					v38 = nil
				end

				tbl18.phase = "normal"
				tbl18.pos = nil
			end
		end,
	}):CreateSlider({
		Id = "gakuran-instant-respawn-hp",
		Name = "HP Threshold",
		Min = 1,
		Max = 100,
		Default = tbl17.HpThreshold,
		Step = 1,
		Callback = function(hpThreshold)
			tbl17.HpThreshold = hpThreshold
		end,
	})

	local tbl19 = { Enabled = false, HookedBlur = nil, Conn = nil }

	local function fn89()
		local v39 = FindFirstChild(Lighting, "ScreenEffectsBlur")
		if v39 == tbl19.HookedBlur then
			return
		end

		if tbl19.Conn then
			Disconnect(tbl19.Conn)
			tbl19.Conn = nil
		end

		tbl19.HookedBlur = v39

		if v39 then
			tbl19.Conn = Connect(GetPropertyChangedSignal(v39, "Enabled"), function()
				if v39.Enabled then
					v39.Enabled = false
				end
			end)
		end
	end

	v27:CreateModule({
		Id = "gakuran-no-screen-blur",
		Name = "No Screen Blur",
		Callback = function(enabled)
			tbl19.Enabled = enabled

			if enabled then
				fn89()

				Spawn(function()
					while tbl19.Enabled and Wait() do
						pcall(function()
							fn89()
							local v39 = FindFirstChild(Lighting, "ScreenEffectsBlur")

							if v39 and v39.Enabled then
								v39.Enabled = false
							end
						end)
					end
				end)
			else
				if tbl19.Conn then
					Disconnect(tbl19.Conn)
					tbl19.Conn = nil
				end

				tbl19.HookedBlur = nil
			end
		end,
	})
end

-- ============================ 4. 启动 ============================

local GAKURAN_PLACE_IDS = { 128736949265057 }

local function isGakuranPlace()
	for _, id in ipairs(GAKURAN_PLACE_IDS) do
		if game.PlaceId == id then
			return true
		end
	end

	return false
end

local ok, err = pcall(Gakuran)

if ok then
	v14:Notify({
		Title = "Gakuran",
		Content = isGakuranPlace() and "已加载 —— 当前就是 Gakuran" or "已加载 —— 但当前不是 Gakuran，功能可能无效",
		Duration = 6,
	})
else
	v14:Notify({
		Title = "Gakuran 加载失败",
		Content = tostring(err),
		Duration = 12,
	})
	warn("[Gakuran] " .. tostring(err))
end
