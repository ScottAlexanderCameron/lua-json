# Json Parsing in Lua Using Patterns

Note: this is not a recommended method of parsing json, it is just a fun
exercise but does not provide proper error handling and may be unsafe. In some
cases illegal json will become valid lua code; this may be advantageous or
disadvantageous depending on the usage.

## Reading Json: Basic Idea

Since lua table literals have such a similar syntax to json, one might wonder if
json data can be read in lua with the help of the `loadstring` function. It
seems natural to try to convert the syntax with basic regular expression; simply
substitute

- `[` -> `{`
- `]` -> `}`
- `null` -> `nil`
- `"key" : val` -> `["key"] = val`

Array indices will now start at 1 instead of 0, and objects will be lua tables.
Once that replacement is made, we can prepend `return` and then call
`loadstring` to get a callable chunk of code. We use `assert` to ensure that
`loadstring` does not return `nil` (it will return the actual error message as
the second value if there is an error), and to ensure that the code chunk cannot
mess with the global environment or refer to any variables we use the
`setfenv` function. The result looks like

```lua
local convertedJson = -- use patterns to replace syntax
local chunk, msg = loadstring('return ' .. convertedJson)
assert(chunk, msg)
setfenv(chunk, setmetatable({}, {
    __index = function(self, name)
        error("invalid value :`" .. name .. '`')
    end
}))
local jsonTable = chunk()
```

## The Problem

Unfortunately the pattern replacement is not quite so simple. One needs to be
careful not to replace characters inside string literals. Consider the following
json

```json
{
    "a[b]\\": true,
    "@": "\/",
    "\u00B5": null,
    "x": [
        "null", "{\"name\": \"val:2\"}"
    ]
}
```

The square brackets inside the string should not be replaced with braces, nor
should `null` inside a string be replaced with `nil`. The last string is a valid
json object itself, however it is inside a string and so it should not be
converted to lua.

The difficulty is that the conversion from json to lua is context sensitive;
some regex replacements should be conditioned on whether or not another regex
matches its surroundings. Standard regular expressions don't allow much on
context sensitive matching, and don't allow recursive matches so they cannot be
used to parse arbitrary grammars. On might consider using `PEG` instead, but it
is a fun exercise to attempt parsing json with patterns alone.

## `gsub` and Friends to the Rescue!

Fortunately it can be done! Lua patterns are slightly less powerful than regular
expressions, but the replacing functions in lua allow one to pass in a callback
which will be called with the matched text. This allows one to first match the
context and then match the specific pattern within that context. It also allows
one to do recursive matches. For example

```lua
-- replace matching brackets outside inwards recursively
local function brac2brace(text)
    local pat = '%[(.*)%]' -- some pattern with a capture
    return text:gsub(pat, function(match)
        return '{' .. brac2brace(match) .. '}'
    end)
end
```

Or for context sensitive matches

```lua
text:gsub(contextPat, function(match)
    return match:gsub(sensitivePat, replacePat)
end)
```
## How it works

The replacements at the beginning of this file would be valid if they are only
applied outside of strings. This can be accomplished with a context sensitive
replacement. Unfortunately matching the context itself can be quite difficult
due to escape chars inside of strings `\"`. Since quotes are symmetric, we also
have to be careful to only match some things between strings rather than inside
them and visa versa. The conversion proceeds as follows

1. First replace all escaped `\"` with something unique that does not contain
   quote characters. This way it will be easier to identify string boundaries.
   Since there are only a few legal escape characters, a simple replacement
   could be `\quote` which is unambiguous. This step will be undone at the end.
   The above json text becomes:
   ```json
   {
       "a[b]\\": true,
       "@": "\/",
       "\u00B5": null,
       "x": [
           "null", "{\quotename\quote: \quoteval:2\quote}"
       ]
   }
   ```
1. We want a dedicated character for starting strings, and a separate one for
   ending strings to more easily match within and outside of strings.
   Arbitrarily choose `@`. Unfortunately we now have to make sure `@` isn't used
   anywhere else, so we replace `@` with `\at`, which again is not a legal
   escape so it is unambiguous. This step will also be undone at the end.
   ```json
   {
       "a[b]\\": true,
       "\at": "\/",
       "\u00B5": null,
       "x": [
           "null", "{\quotename\quote: \quoteval:2\quote}"
       ]
   }
   ```
1. Now we replace strings `"..."` with `"...@` for easier matching. This needs a
   context sensitive match, since only closing quotes are changed, and we also
   want to be able to handle an escape char which is not valid in lua (namely
   `\/` which just becomes `/`).
   ```json
   {
       "a[b]\\@: true,
       "\at@: "/@,
       "\u00B5@: null,
       "x@: [
           "null@, "{\quotename\quote: \quoteval:2\quote}@
       ]
   }
   ```
1. We are finally ready to do the replacements at the beginning of this file.
   These are again context sensitive so we have to pass a function to `gsub`.
   Since we have to match outside of strings, we have to do this replacement 4
   times: once before the first string, once after the last string, once
   in between strings, and once again in case there are no strings. The patterns
   for the replacements are respectively `'^([^"]*)"'`, `'@([^"]*)$'`,
   `'@([^"]*)"'`, `'^([^"]*)$'`. The captured text (all the text outside of
   string boundaries) will be passed to our replace function which will perform
   the basic syntax conversions. This function is called `out` in the code.
   ```json
   {
       "a[b]\\@: true,
       "\at@: "/@,
       "\u00B5@: nil,
       "x@: {
           "null@, "{\quotename\quote: \quoteval:2\quote}@
       }
   }
   ```
1. Next we replace `"key@ : val` with the lua equivalent `["key@] = val`. The
   `@` is still used to close the string so that when closing quotes are
   reintroduced later, they don't cause inconsistencies.
   ```lua
   {
       ["a[b]\\@] = true,
       ["\at@] = "/@,
       ["\u00B5@] = nil,
       ["x@] = {
           "null@, "{\quotename\quote: \quoteval:2\quote}@
       }
   }
   ```
1. The last conversion is for unicode code points. Json allows one to write
   `\uXXXX` within strings to represent the code point `XXXX` in hexadecimal.
   Lua only uses ascii, but allows one to include arbitrary bytes within a
   string by prepending a three digit number by `\ `. The `uft8` library helps
   with this conversion. Most json doesn't even use these characters, so they
   could potentially be ignored.
   ```lua
   {
       ["a[b]\\@] = true,
       ["\at@] = "/@,
       ["\194\181@] = nil,
       ["x@] = {
           "null@, "{\quotename\quote: \quoteval:2\quote}@
       }
   }
   ```
1. The conversion is done! Now we just need to undo the temporary changes we
   made at the beginning. We replace `"...@` with `"..."`, then `\at` with `@`
   and finally `\quote` with `\"`.
   ```lua
   {
       ["a[b]\\"] = true,
       ["\at"] = "/",
       ["\194\181"] = nil,
       ["x"] = {
           "null", "{\quotename\quote: \quoteval:2\quote}"
       }
   }
   ```
   ```lua
   {
       ["a[b]\\"] = true,
       ["@"] = "/",
       ["\194\181"] = nil,
       ["x"] = {
           "null", "{\quotename\quote: \quoteval:2\quote}"
       }
   }
   ```
   ```lua
   {
       ["a[b]\\"] = true,
       ["@"] = "/",
       ["\194\181"] = nil,
       ["x"] = {
           "null", "{\"name\": \"val:2\"}"
       }
   }
   ```

There is one further detail to take care of regarding escape sequences within
strings. `\"` counts as an escaped quote but `\\"` is an escaped backslash
followed by end of string. Since there can be arbitrarily many backslashes,
there is a helper function to deal with escapes, which counts the number of
backslashes before the actual escape sequence. This function is called `escape`.

## Complete Code

```lua
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

    local function out(text) -- outside of strings
        return text:gsub('%[','{')
        :gsub('%]','}')
        :gsub('null','nil')
        :gsub('//','--')
    end

    return setfenv(assert(loadstring('return '..
        str:gsub(escape('\\"', '\\quote'))              -- step 1
        :gsub('@', '\\at')                              -- step 2
        :gsub('"([^"]-)"', function(text)               -- step 3
            return ('"%s@'):format(text:gsub(escape('\\/', '/')))
        end)
        :gsub('^([^"]-)"', out)                         -- step 4
        :gsub('@([^"]-)$', out)                         -- step 4
        :gsub('@([^"]-)"', out)                         -- step 4
        :gsub('^([^"]-)$', out)                         -- step 4
        :gsub('("[^@]-@)%s*:%s*', '[%1] = ')            -- step 5
        :gsub(escape('\\u(....)', function(hex)         -- step 6
            local bytes = {   -- unicode code points
                string.byte(utf8.char(tonumber(hex, 16)), 1, 2, 3, 4)
            }
            for i, byte in ipairs(bytes) do
                -- ensure three digits
                bytes[i] = ('\\%03d'):format(byte)
            end
            return table.concat(bytes)
        end))
        :gsub('"([^@]-)@', '"%1"')                      -- step 7
        :gsub(escape('\\at', '@'))                      -- step 7
        :gsub(escape('\\quote', '\\"'))                 -- step 7
        )), setmetatable({}, {
            __index = function(self, name)
                error("invalid value :`" .. name .. '`')
            end
        }))()
end
```
