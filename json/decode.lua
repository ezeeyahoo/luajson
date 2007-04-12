local lpeg = require("lpeg")
local util = require("json.util")

local setmetatable, getmetatable = setmetatable, getmetatable
local assert = assert
local print = print
local tonumber = tonumber
local ipairs = ipairs
local string = string
module("json.decode")
local digit = lpeg.R("09")
local digits = digit^1
local alpha = lpeg.R("AZ","az")
local hex = lpeg.R("09","AF","af")
local hexpair = hex * hex

local identifier = lpeg.R("AZ","az","__") * lpeg.R("AZ","az", "__", "09") ^0

local space = lpeg.S(" \n\r\t\f")
local comment = (lpeg.P("//") * (1 - lpeg.P("\n"))^0 * lpeg.P("\n"))
	+ (lpeg.P("/*") * (1 - lpeg.P("*/"))^0 * lpeg.P("*/"))

local ignored = (space + comment)^0

local knownReplacements = {
	n = "\n",
	r = "\r",
	f = "\f",
	t = "\t",
	b = "\b",
	z = "\z",
	['\\'] = "\\",
	['/'] = "/",
	['"'] = '"'
}
local function unicodeParse(code1, code2)
	code1, code2 = assert(tonumber(code1, 16)), assert(tonumber(code2, 16))
	return string.char(code1, code2)
end

-- Potential deviation, allow for newlines inside strings
local function buildStringCapture(stopParse, escapeMatch)
	return lpeg.P('"') * lpeg.Cs(((1 - lpeg.S(stopParse)) + (lpeg.P("\\") / "" * escapeMatch))^0) * lpeg.P('"')
end

local doSimpleSub = lpeg.C(lpeg.S("rnfbt/\\z\"")) / knownReplacements
local doUniSub = (lpeg.P('u') * lpeg.C(hexpair) * lpeg.C(hexpair) + lpeg.P(false)) / unicodeParse
local doSub = doSimpleSub + doUniSub
-- Non-strict capture just spits back input value w/o slash
local captureString = buildStringCapture('"\\', doSub + lpeg.C(1))
local strictCaptureString = buildStringCapture('"\\\r\n\f\b\t', #lpeg.S("rnfbt/\\\"u") * doSub)

-- Deviation.. permit leading zeroes, permit inf number of negatives w/ space between
local int = lpeg.P('-')^0 * space^0 * digits
local number, strictNumber
local strictInt = (lpeg.P('-') + 0) * (lpeg.R("19") * digits + digit)
do
	local frac = lpeg.P('.') * digits
	local exp = lpeg.S("Ee") * (lpeg.S("-+") + 0) * digits -- Optional +- after the E
	local function getNumber(intBase)
		return  intBase * (frac + 0) * (exp + 0)
	end
	number = getNumber(int)
	strictNumber = getNumber(strictInt)
end

local VAL, TABLE, ARRAY = 2,3,4

-- For null and undefined, use the util.null value to preserve null-ness
local valueCapture = ignored * (
	captureString
	+ lpeg.C(number) / tonumber
	+ lpeg.P("true") * lpeg.Cc(true)
	+ lpeg.P("false") * lpeg.Cc(false)
	+ (lpeg.P("null") + lpeg.P("undefined")) * lpeg.Cc(util.null)
	+ lpeg.V(TABLE) 
	+ lpeg.V(ARRAY)
) * ignored
local strictValueCapture = ignored * (
	strictCaptureString
	+ lpeg.C(strictNumber) / tonumber
	+ lpeg.P("true") * lpeg.Cc(true)
	+ lpeg.P("false") * lpeg.Cc(false)
	+ (lpeg.P("null") + lpeg.P("undefined")) * lpeg.Cc(util.null)
	+ lpeg.V(TABLE) 
	+ lpeg.V(ARRAY)
) * ignored

local currentDepth
local function initDepth(s, i)
	currentDepth = 0
	return i
end
local function incDepth(s, i)
	currentDepth = currentDepth + 1
	if currentDepth >= 20 then
		return false
	else
		return i
	end
end
local function decDepth(s, i)
	currentDepth = currentDepth - 1
	return i
end

local tableKey = 
	lpeg.C(identifier) 
	+ captureString
	+ int / tonumber
local strictTableKey = captureString

local tableVal = lpeg.V(VAL)

-- tableItem == pair
local tableItem = tableKey * ignored * lpeg.P(':') * ignored * tableVal
local strictTableItem = strictTableKey * ignored * lpeg.P(':') * ignored * tableVal

local function applyTableKey(tab, key, val)
	if not tab then tab = {} end -- Initialize table for this set...
	tab[key] = val
	return tab
end
tableItem = tableItem / applyTableKey
strictTableItem = strictTableItem / applyTableKey

local tableElements = lpeg.Ca(lpeg.Cc(false) * tableItem * (ignored * lpeg.P(',') * ignored * tableItem)^0)
local strictTableElements = lpeg.Ca(lpeg.Cc(false) * strictTableItem * (ignored * lpeg.P(',') * ignored * strictTableItem)^0)

local tableCapture = 
	lpeg.P("{") * ignored 
	* (tableElements + 0) * ignored 
	* (lpeg.P(',') + 0) * ignored 
	* lpeg.P("}")
local strictTableCapture =
	lpeg.P("{") * lpeg.P(incDepth) * ignored 
	* (strictTableElements + 0) * ignored 
	* lpeg.P("}") * lpeg.P(decDepth)


-- Utility function to help manage slighly sparse arrays
local function processArray(array)
	array.n = #array
	for i,v in ipairs(array) do
		if v == util.null then
			array[i] = nil
		end
	end
	if #array == array.n then
		array.n = nil
	end
	return array
end
-- arrayItem == element
local arrayItem = lpeg.V(VAL)
local arrayElements = lpeg.Ct(arrayItem * (ignored * lpeg.P(',') * ignored * arrayItem)^0) / processArray
local strictArrayCapture = lpeg.P("[") * lpeg.P(incDepth) * ignored 
	* (arrayElements + 0) * ignored 
	* lpeg.P("]") * lpeg.P(decDepth)
local arrayCapture = lpeg.P("[") * ignored 
	* (arrayElements + 0) * ignored 
	* (lpeg.P(",") + 0) * ignored 
	* lpeg.P("]")

-- Deviation: allow for trailing comma, allow for "undefined" to be a value...
local grammar = lpeg.P({
	[1] = lpeg.V(2),
	[2] = valueCapture,
	[3] = tableCapture,
	[4] = arrayCapture
}) * ignored * -1

local strictGrammar = lpeg.P({
	[1] = lpeg.P(initDepth) * (lpeg.V(TABLE) + lpeg.V(ARRAY)), -- Initial value MUST be an object or array
	[2] = strictValueCapture,
	[3] = strictTableCapture,
	[4] = strictArrayCapture
}) * ignored * -1

--NOTE: Certificate was trimmed down to make it easier to read....

function decode(data, strict)
	return (assert(lpeg.match(not strict and grammar or strictGrammar, data), "Invalid JSON data"))
end

local mt = getmetatable(_M) or {}
mt.__call = function(self, ...)
	return decode(...)
end
setmetatable(_M, mt)
