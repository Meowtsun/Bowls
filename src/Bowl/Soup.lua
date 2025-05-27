
local Soup = {}
Soup.__index = Soup
Soup._token = newproxy()


local function edit(stack, index, value, mult, method)
	if method == 'Increment' then
		stack[index] += value * mult
	elseif method == 'Multiply' then
		stack[index] *= value
	else -- Set
		stack[index] = value
	end
	return stack[index]
end


local function write(bowl, soup, mult, path, main, whitelist)
	for index, value in soup do
		local fullPath = path and (`{path}.{index}`) or index
		
		if type(value) ~= 'table' then
			warn(`[Soup: {soup.Name or "?"}] Skipped "{index}" – expected :Set() or :Increment()`)
			-- so someone did not use .Increment or .Set, therefore this is not a token
			continue
		end
		
		if value._token == Soup._token then
			local old_value = bowl[index]

			if table.find(whitelist, value._method) then
				edit(bowl, index, value._value, mult, value._method)
			end
			
		else -- ordinary table
			
			-- already catched on AddSoup()
			local nextBowl = bowl[index]
			if not nextBowl then
				warn(`[Soup: {soup.Name or '?'}] Path "{fullPath}" missing in bowl`)
				-- soup are trying to reach into table that doesn't exist in bowl
				continue
			end
			
			write(bowl[index], value, mult, fullPath, main, whitelist)
		end
		
	end
end


function Soup:HasTags(...)
	for _,tag in {...} do
		if not self._tags[tag] then
			return false
		end
	end
	return true
end


function Soup:GetValue(name)
	return self._metadata[name]
end


function Soup:GetAllValues()
	return self._metadata
end


function Soup:GetAllTags()
	return self._tags
end


function Soup:IsExpired(now)
	now = now or tick()
	return now > self._initial + self.Duration
end


function Soup:_tick(bowl, mult, whitelist)
	local target = self.Type == 'Interval' and '_write' 	or '_read'
	write(bowl[target], self._content, mult or 1, nil,  bowl, whitelist)
end


function Soup:Destroy()
	table.clear(self)
	setmetatable(self, nil)
end


return Soup
