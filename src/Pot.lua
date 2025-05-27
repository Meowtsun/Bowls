
local Soup = require(script.Parent.Soup)
local Token = Soup._token

local Pot = {}
Pot.__index = Pot


function Pot.new(name, content)
	return setmetatable({
		_content = content,
		
		Type = 'Static',
		Duration = math.huge,
		Interval = nil,
		Name = name,

		_tags = {},
		_metadata = {},
		
	}, Pot)
end


function Pot:Done()
	-- basically have nothing to do, kept for consistancy, nvm It does something now
	self.Duration = self.Duration or math.huge
	setmetatable(self, nil)
	return setmetatable(self, Soup)
end


function Pot:SetTags(...)
	for _,tag in {...} do
		if not self._tags[tag] then
			self._tags[tag] = true
		end
	end
	return self
end


function Pot:SetValue(label, value)
	self._metadata[label] = value
	return self
end


function Pot:SetType(typ, interval)
	self.Type = typ
	self.Interval = interval
	return self
end


function Pot:SetDuration(value)
	self.Duration = value
	return self
end


function Pot.Increment(value)
	return {
		_method = 'Increment',
		_value = value,
		_token = Token,
	}
end


function Pot.Multiply(value)
	return {
		_method = 'Multiply',
		_value = value,
		_token = Token,
	}
end


function Pot.Set(value)
	return {
		_method = 'Set',
		_value = value,
		_token = Token,
	}
end


return Pot
