
local function json(str)
	local utf8 = require 'utf8'

	local function escape(pat, text) -- use to replace escapes
		return '((\\-)' .. pat .. ')', function(all, prev, ...)
			if prev:len() % 2 == 0 then
				return prev .. (type(text) == 'function' and text(...) or text)
			else
				return all
			end
		end
	end

	local function out(text) -- use outside strings
		return text:gsub('%[','{')
		:gsub('%]','}')
		:gsub('null','nil')
		:gsub('//','--')
	end

	return setfenv(assert(loadstring('return '..
		str:gsub(escape('\\"', '\\quote'))
		:gsub('@', '\\at')
		:gsub('"([^"]-)"', function(text) -- inside of strings
				return string.format('"%s@', text:gsub(escape('\\/', '/')))
			end)
		:gsub('@([^"]-)$', out) -- outside of strings
		:gsub('^([^"]-)"', out) -- outside of strings
		:gsub('@([^"]-)"', out) -- outside of strings
		:gsub('^([^"]-)$', out) -- outside of strings
		:gsub('("[^@]-@)%s*:%s*', '[%1] = ') -- "key" : val => ["key"] = val
		:gsub(escape('\\u(....)', function(hex) -- unicode code points
			return '\\' .. table.concat({
				string.byte(utf8.char(tonumber(hex, 16)), 1, 2, 3, 4)
			}, '\\')
		end))
		:gsub('"([^@]-)@', '"%1"')
		:gsub(escape('\\at', '@'))
		:gsub(escape('\\quote', '\\"'))
		)), setmetatable({}, {
			__index = function(self, name)
				error("invalid value :`" .. name .. '`')
			end
		}))()
end
