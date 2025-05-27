
local Pot = require(script.Pot)
local Soup = require(script.Soup)

local ActiveBowls = {}
local Bowl = {}
Bowl.Soup = Pot
Bowl.__index = Bowl

local MultiplierToken = newproxy()
local AnySoupToken = newproxy()
local callbackId = 0


local function generateId()
	callbackId += 1
	return callbackId
end


local function deepcopy(stack)
	local copy = table.clone(stack)

	for index, value in stack do
		copy[index] = if type(value) == 'table'
			then deepcopy(value)
			else value
	end

	return copy
end


local function getSoupUpdateTick(soup)
	if soup.Type == 'Interval' then
		return (soup._lastTick or soup._initial) + soup.Interval
	else
		return soup._initial + soup.Duration
	end
end


local function sortSoupUpdate(soup1, soup2)
	return getSoupUpdateTick(soup1)
		> getSoupUpdateTick(soup2)
end


local function isSoupCompatible(bowl, soup, path, main)
	for index, value in soup do

		local fullpath = path and `{path}.{index}` or index
		local value_type = type(value)

		if type(bowl[index]) ~= value_type then
			if value_type == 'table' and value._token == Soup._token then
				if value._method == 'Multiply' then
					main._tags[MultiplierToken] = true
				end
			end
			continue
		end
		
		if value_type == 'table' then
			if not isSoupCompatible(bowl[index], value, fullpath, main) then
				return false
			end
		end
		
		warn(`[Soup: {soup.Name or '?'}] at "{fullpath}" : expected {type(bowl[index])}, got {type(value)}`)
		return false
	end
	
	return true
end


local function isPathValid(bowl, path)
	local indexs = string.split(path, '.')

	for index = 1, #indexs do
		bowl = bowl[indexs[index]]
		if bowl == nil then
			return false
		end
	end

	return true
end


local function getNestedValue(stack, path)
	local indexs = string.split(path, '.')

	for index = 1, #indexs do
		local label = indexs[index]
		stack = stack[label]
	end

	return stack
end


local function setNestedStack(stack, path, value)
	local indexs = string.split(path, '.')
	local lastIndex = indexs[#indexs]

	for index = 1, #indexs - 1 do
		local label = indexs[index]
		stack[label] = stack[label] or {}
		stack = stack[label]
	end

	stack[lastIndex] = value
end


local function checkChanges(old, new, path, bowl)
	for key, new_value in new do
		local old_value = old[key]
		local currentPath = path and `{path}.{key}` or key

		if typeof(new_value) == "table" and typeof(old_value) == "table" then
			checkChanges(old_value, new_value, currentPath, bowl)
		elseif new_value ~= old_value then
			bowl:_anyChanged(currentPath, old_value, new_value)
		end
	end

end


--[[ 
	Portions of this code are based on Stravant's yield-safe coroutine implementation
	Sources:
		https://devforum.roblox.com/t/lua-signal-class-comparison-optimal-goodsignal-class/1387063
		https://gist.github.com/stravant/b75a322e0919d60dde8a0316d1f09d2f
]]

local freeRunnerThread = nil

local function acquireRunnerThreadAndCallEventHandler(fn, ...)
	local acquiredRunnerThread = freeRunnerThread
	freeRunnerThread = nil
	fn(...)
	-- The handler finished running, this runner thread is free again.
	freeRunnerThread = acquiredRunnerThread
end

local function runEventHandlerInFreeThread()
	while true do
		acquireRunnerThreadAndCallEventHandler(coroutine.yield())
	end
end



function Bowl.new(stack: any)
	local bowl = setmetatable({

		_write = deepcopy(stack),
		_read = deepcopy(stack),
		_last = table.clone(stack),
		_modifiers = {},

		_soupremoved = {},
		_soupadded = {},
		_anylisteners = {},
		_listeners = {
			--[[
				[string]: {
					(name: string, old: any, new: any) -> (),
						# callbacks
					...
				},
				...
			]]	
		},

	}, Bowl)

	table.insert(ActiveBowls, bowl)
	return bowl
end



function Bowl:GetRawValues()
	return deepcopy(self._write)
end


function Bowl:GetValues()
	return deepcopy(self._read)
end



-- No, I disabled this for now This is more complicated than entire Module and is nest of bugs
--function Bowl:MixIn()
--	return Mixer.new(self)
--end



function Bowl:OnChanged(callback)
	local newId = generateId()
	self._anylisteners[newId] = callback
	return newId
end


function Bowl:OnValueChanged(path, callback)

	if not isPathValid(self._write, path) then
		warn(`[OnValueChanged] Invalid path : "{path}". Listener will not be registered.`)
	end

	local listeners = self._listeners[path]
	if not listeners then
		listeners = {}
		self._listeners[path] = listeners
	end

	local newId = generateId()
	listeners[newId] = callback
	return newId
end


function Bowl:_anyChanged(path, ...)
	for _,callback in self._anylisteners do

		if not freeRunnerThread then
			freeRunnerThread = coroutine.create(runEventHandlerInFreeThread)
			coroutine.resume(freeRunnerThread)
		end
		task.spawn(freeRunnerThread, callback, path, ...)
	end

	self:_onChanged(path, ...)
end


function Bowl:_onChanged(path, ...)
	local listeners = self._listeners[path]
	if listeners ~= nil then
		for _,callback in listeners do
			if not freeRunnerThread then
				freeRunnerThread = coroutine.create(runEventHandlerInFreeThread)
				coroutine.resume(freeRunnerThread)
			end
			task.spawn(freeRunnerThread, callback, ...)
		end
	end
end


function Bowl:AddSoup(soup)
	isSoupCompatible(self._write, soup._content, nil, soup)
	local now = tick()

	soup._lastTick = now - (soup.Interval or 0)
	soup._initial = now

	table.insert(self._modifiers, soup)
	table.sort(self._modifiers, sortSoupUpdate)

	if soup.Type == 'Static' then
		self:_recomputeStaticModifiers()
	else
		if soup.Interval == nil then
			soup.Interval = 1
		end
	end

	local tags = soup:GetAllTags()
	for name in tags do
		if self._soupadded[name] then
			self:_tagAdded(name, soup)
		end
	end
	
	if self._soupadded[AnySoupToken] then
		self:_tagAdded(AnySoupToken, soup)
	end
	
end


function Bowl:RemoveSoup(name)
	for index = #self._modifiers, 1, -1 do
		local soup = self._modifiers[index]
		if soup.Name == name then
			self:_removeSoup(soup, index)	
		end
	end
end


function Bowl:_removeSoup(soup, index)
	table.remove(self._modifiers, index or table.find(self._modifiers, soup))

	if soup.Type == 'Static' then
		self:_recomputeStaticModifiers(soup, true)
	end

	local tags = soup:GetAllTags()
	for name in tags do
		if self._soupremoved[name] then
			self:_tagRemoved(name, soup)
		end
	end
	
	if self._soupremoved[AnySoupToken] then
		self:_tagRemoved(AnySoupToken, soup)
	end

	soup:Destroy()
end


function Bowl:GetSoup(name)
	for index = #self._modifiers, 1, -1 do
		local soup = self._modifiers[index]
		if soup.Name == name then
			return soup
		end
	end
end


function Bowl:GetSoupTagged(name)
	local out = {}
	for index = #self._modifiers, 1, -1 do
		local soup = self._modifiers[index]
		if soup._tags[name] then
			table.insert(out, soup)
		end
	end
	return out
end


function Bowl:RemoveSoupTagged(name)
	for index = #self._modifiers, 1, -1 do
		local soup = self._modifiers[index]
		if soup._tags[name] then
			self:_removeSoup(soup, index)	
		end
	end
end


function Bowl:GetAllSoups(name)
	return self._modifiers
end


function Bowl:ClearAllSoups(name)
	for _,soup in self._modifiers do
		soup:Destroy()
	end
	table.clear(self._modifiers)
end


function Bowl:OnSoupAdded(callback)

	local listeners = self._soupadded[AnySoupToken]
	if not listeners then
		listeners = {}
		self._soupadded[AnySoupToken] = listeners
	end

	local newId = generateId()
	listeners[newId] = callback
	return newId
end



function Bowl:OnSoupRemoved(callback)

	local listeners = self._soupremoved[AnySoupToken]
	if not listeners then
		listeners = {}
		self._soupremoved[AnySoupToken] = listeners
	end

	local newId = generateId()
	listeners[newId] = callback
	return newId
end


function Bowl:OnTagAdded(name, callback)

	local listeners = self._soupadded[name]
	if not listeners then
		listeners = {}
		self._soupadded[name] = listeners
	end

	local newId = generateId()
	listeners[newId] = callback
	return newId
end



function Bowl:OnTagRemoved(name, callback)

	local listeners = self._soupremoved[name]
	if not listeners then
		listeners = {}
		self._soupremoved[name] = listeners
	end

	local newId = generateId()
	listeners[newId] = callback
	return newId
end


function Bowl:_tagAdded(name, ...)
	local listeners = self._soupadded[name]
	if listeners ~= nil then
		for _,callback in listeners do
			if not freeRunnerThread then
				freeRunnerThread = coroutine.create(runEventHandlerInFreeThread)
				coroutine.resume(freeRunnerThread)
			end
			task.spawn(freeRunnerThread, callback, ...)
		end
	end
end


function Bowl:_tagRemoved(name, ...)
	local listeners = self._soupremoved[name]
	if listeners ~= nil then
		for _,callback in listeners do
			if not freeRunnerThread then
				freeRunnerThread = coroutine.create(runEventHandlerInFreeThread)
				coroutine.resume(freeRunnerThread)
			end
			task.spawn(freeRunnerThread, callback, ...)
		end
	end
end


function Bowl:Destroy(name)
	local index = table.find(ActiveBowls, self)
	if index then
		table.remove(ActiveBowls, index)
	end

	self:ClearAllSoups()
	table.clear(self)
	setmetatable(self, nil)
end



function Bowl:Update(deltaTime)

	local soups = self:GetAllSoups()
	if #soups < 1 then
		return -- no update
	end

	local recomputeStatic = self:_recomputeIntervalModifiers()
	if recomputeStatic then
		self:_recomputeStaticModifiers() 
	end

	checkChanges(self._last, self._read, nil, self)
	self._last = deepcopy(self._read)

	table.sort(self._modifiers, sortSoupUpdate)
end



function Bowl:_recomputeIntervalModifiers()
	local now = tick()

	local total = #self._modifiers
	local applying = {}
	local updated = false

	for index = total, 1, -1 do
		local soup = self._modifiers[index]

		local nextUpdate = getSoupUpdateTick(soup)
		if now < nextUpdate then
			break -- no interval update needed
		end

		if soup:IsExpired(now) then
			if soup.Type == 'Static' then
				updated = true
			end
			self:_removeSoup(soup, index)	
			continue
		end

		if soup.Type == 'Interval' then
			local mult = math.floor((now - soup._lastTick) / soup.Interval)
			soup:_tick(self, mult, {'Set', 'Increment'})
			soup._lastTick = now
			updated = true
		end
	end

	for _,soup in self:GetSoupTagged(MultiplierToken) do
		if soup.Type == 'Interval' then
			local mult = math.floor((now - soup._lastTick) / soup.Interval)
			soup:_tick(self, mult,{'Multiply'})
			soup._lastTick = now
			updated = true
		end
	end

	return updated
end



function Bowl:_recomputeStaticModifiers(exclude, isRemoval)

	local old_read = isRemoval and self:GetValues()
	self._read = self:GetRawValues()

	local last_count = #self._modifiers
	local applying = {}

	for index = last_count, 1, -1 do
		local soup = self._modifiers[index]
		if soup.Type == 'Static' and soup ~= exclude then
			soup:_tick(self, nil, {'Set', 'Increment'})
		end
	end

	for _,soup in self:GetSoupTagged(MultiplierToken) do
		if soup.Type == 'Static' and soup ~= exclude then
			soup:_tick(self, nil, {'Multiply'})
		end
	end

	if isRemoval then
		checkChanges(old_read, self._read, nil, self)
	end
end


function Bowl:_update(deltaTime)
	for _, bowl in ActiveBowls do
		Bowl.Update(bowl, deltaTime)
	end
end



function Bowl:Get(path)
	return getNestedValue(self._read, path)
end


function Bowl:GetRaw(path)
	return getNestedValue(self._write, path)
end



function Bowl:Set(path, value)
	local old_value = getNestedValue(self._write, path)
	setNestedStack(self._write, path, value)
	if old_value ~= value then
		self:_anyChanged(path, old_value, value)
	end
end



function Bowl:Increment(path, value)
	local old_value = getNestedValue(self._write, path)
	value = old_value + value
	setNestedStack(self._write, path, value)
	if old_value ~= value then
		self:_anyChanged(path, old_value, value)
	end
end



function Bowl:Multiply(path, value)
	local old_value = getNestedValue(self._write, path)
	value = old_value * value
	setNestedStack(self._write, path, value)
	if old_value ~= value then
		self:_anyChanged(path, old_value, value)
	end
end


function Bowl:Map(path, map)
	local old_value = getNestedValue(self._write, path)
	local value = map(old_value)
	setNestedStack(self._write, path, value)
	if old_value ~= value then
		self:_anyChanged(path, old_value, value)
	end
end



task.spawn(function()
	while true do
		local deltaTime = task.wait()
		Bowl:_update(deltaTime)
	end
end)


export type SoupType = 'Interval' | 'Static'
export type table = {[string]: any}


export type BowlMaker = {
	new: (content: table) -> Bowl,
	Soup: { 
		new: (name: string, content: table) -> SoupMaker,
		Increment: (value: number) -> (),
		Multiply: (value: number) -> (),
		Set: (value: number) -> (),
	},
}

export type Soup = {

	Class: SoupType,
	Name: string,
	Duration: number,
	Interval: number,

	HasTag: (self: Soup, ...string) -> boolean,
	GetAllTags: (self: Soup) -> {string},

	GetValue: (self: Soup, name: string) -> any,
	GetAllValues: (self: Soup) -> table,
	IsExpired: (timestamp: number?) -> boolean,
}

export type SoupMaker = {
	Done: (self: SoupMaker) -> Soup,

	SetValue: (self: SoupMaker, label: string, value: any) -> SoupMaker,
	SetTags: (self: SoupMaker, ...string) -> SoupMaker,

	SetType: (self: SoupMaker, type: SoupType, interval: number?) -> SoupMaker,
	SetDuration: (self: SoupMaker, seconds: number) -> SoupMaker,

}


export type Bowl = { -- API --

	-- soup management
	AddSoup: (self: Bowl, soup: Soup) -> (),

	GetSoupTagged: (self: Bowl, name: string) -> {Soup},
	GetAllSoups: (self: Bowl) -> {Soup},
	GetSoup: (self: Bowl, name: string) -> (Soup),

	RemoveSoupTagged: (self: Bowl, name: string) -> (),
	RemoveSoup: (self: Bowl, name: string) -> (),

	-- getting values
	GetRawValues: (self: Bowl) -> (table),
	GetValues: (self: Bowl) -> (table),

	-- value editing methods
	Increment: (self: Bowl, path: string, value: number) -> (),
	Multiply: (self: Bowl, path: string, value: number) -> (),
	Map: (self: Bowl, path: string, fn: (value: any) -> (any)) -> (),
	Set: (self: Bowl, path: string, value: boolean) -> (),
	Get: (self: Bowl, path: string) -> any,

	-- other
	Update: (self: Bowl, deltaTime: number) -> (),
	Destroy: (self: Bowl) -> (),

	-- listeners
	OnValueChanged: (self: Bowl, path: string, callback: (old_value: any, new_value: any) -> ()) -> (number),
	OnChanged: (self: Bowl, callback: (path:string, old_value: any, new_value: any) -> ()) -> (number),
	OnTagAdded: (self: Bowl, callback: (soup: Soup) -> ()) -> (number),
	OnTagRemoved: (self: Bowl, callback: (soup: Soup) -> ()) -> (number),
	OnSoupAdded: (self: Bowl, callback: (soup: Soup) -> ()) -> (),
	OnSoupRemoved: (self: Bowl, callback: (soup: Soup) -> ()) -> (),

	-- disconnector
	Disconnect: (self: Bowl, listenerId: number) -> (),
}


return Bowl :: BowlMaker
