-- Instead of old loop over dict rows
-- Call the loader early (e.g. at top or in ADDON_LOADED)

-- Your TranslateMessage stays almost the same:
-- It uses lookups[sourceIndex][wClean] for detection
-- translations[sourceIndex][targetIndex][wLower] for translation

TurtleTranslatorDB.channels = TurtleTranslatorDB.channels or {}

for key, value in pairs(defaultChannels) do
    if TurtleTranslatorDB.channels[key] == nil then
        TurtleTranslatorDB.channels[key] = value
    end
end

-- Fill any missing sourceLangs entries (e.g. zhcn added after first login)
TurtleTranslatorDB.sourceLangs = TurtleTranslatorDB.sourceLangs or {}
for idx, val in pairs(defaultSourceLangs) do
    if TurtleTranslatorDB.sourceLangs[idx] == nil then
        TurtleTranslatorDB.sourceLangs[idx] = val
    end
end

if TurtleTranslatorDB.debugEnabled == nil then
    TurtleTranslatorDB.debugEnabled = false
end

local playerName = UnitName("player")

-- Helper: count UTF-8 characters in a string (each CJK char = 3 bytes)
local function utf8len(s)
    local len = 0
    local i = 1
    local slen = string.len(s)
    while i <= slen do
        local b = string.byte(s, i)
        if b < 128 then
            i = i + 1
        elseif b < 224 then
            i = i + 2
        elseif b < 240 then
            i = i + 3
        else
            i = i + 4
        end
        len = len + 1
    end
    return len
end

-- Helper: get UTF-8 character boundaries as a list of {startbyte, endbyte}
local function utf8chars(s)
    local chars = {}
    local i = 1
    local slen = string.len(s)
    while i <= slen do
        local b = string.byte(s, i)
        local charlen
        if b < 128 then
            charlen = 1
        elseif b < 224 then
            charlen = 2
        elseif b < 240 then
            charlen = 3
        else
            charlen = 4
        end
        local stop = i + charlen - 1
        if stop > slen then stop = slen end
        table.insert(chars, string.sub(s, i, stop))
        i = i + charlen
    end
    return chars
end

-- Helper: check if a string contains any non-ASCII (multibyte) bytes
local function hasCJK(s)
    local slen = string.len(s)
    for i = 1, slen do
        if string.byte(s, i) > 127 then return true end
    end
    return false
end

-- Helper: given a list of UTF-8 chars, produce all ngrams of length 1..maxN
local function makeNgrams(chars, maxN)
    local ngrams = {}
    local n = 0
    for _ in ipairs(chars) do n = n + 1 end
    for i = 1, n do
        for len = 1, maxN do
            if i + len - 1 <= n then
                local gram = ""
                for j = i, i + len - 1 do
                    gram = gram .. chars[j]
                end
                ngrams[gram] = true
            end
        end
    end
    return ngrams
end

-- Safe ASCII punct strip (never touches bytes > 127)
local PUNCT_STRIP = [[!?.,;:%(%) "%[%]%-%+%%%^&*=<>{}|_ ]]

local function StripLinks(msg)
    -- Remove WoW color codes: |cAARRGGBB and |r
    msg = string.gsub(msg, "|c%x%x%x%x%x%x%x%x", "")
    msg = string.gsub(msg, "|r", "")
    -- Remove WoW hyperlink wrappers |Htype:data:...|h ... |h  (keep visible text)
    msg = string.gsub(msg, "|H[^|]*|h", "")
    msg = string.gsub(msg, "|h", "")
    -- Strip square brackets from item/quest names e.g. [Sword of X] -> Sword of X
    msg = string.gsub(msg, "%[([^%]]*)%]", "%1")
    -- Remove any stray pipe characters
    msg = string.gsub(msg, "|.", "")
    return msg
end

local function TranslateMessage(msg, author)
    if not TurtleTranslatorDB.enabled then return end
    if not msg or msg == "" then return end
    if author == playerName then return end

    -- Strip WoW item/quest/spell links and color codes before any processing
    msg = StripLinks(msg)
    if not msg or msg == "" then return end

    -- Step 1: Tokenize – space-split for Latin, char-level for CJK
    local words = {}
    if hasCJK(msg) then
        -- Chinese/CJK: split on spaces first, then expand CJK tokens into chars
        for token in string.gfind(msg, "%S+") do
            if hasCJK(token) then
                -- Also keep the whole token for multi-word dict lookup
                table.insert(words, token)
                -- Add individual UTF-8 chars
                local chars = utf8chars(token)
                -- Emit every ngram up to length 4 as a lookup candidate
                -- but for the translated output we still use the whole token
                -- (ngrams used only in detect+translate steps below)
            else
                table.insert(words, token)
            end
        end
    else
        for word in string.gfind(msg, "%S+") do
            table.insert(words, word)
        end
    end
    if next(words) == nil then return end
    
    -- For CJK messages, build a flat list of all ngrams for detection
    local cjkNgrams = nil
    if hasCJK(msg) then
        -- Collect all CJK chars from entire message
        local allChars = {}
        for token in string.gfind(msg, "%S+") do
            if hasCJK(token) then
                local tc = utf8chars(token)
                for _, c in ipairs(tc) do
                    table.insert(allChars, c)
                end
            end
        end
        cjkNgrams = makeNgrams(allChars, 4)
    end

    local targetIndex = TurtleTranslatorDB.targetLangIndex
	local sourceLangs = TurtleTranslatorDB.sourceLangs

    -- Step 2: Detection – clean words for matching only
    local matchCounts = {}
    for i = 1, numLangs do
        local langIdx = langs[i].index
        matchCounts[langIdx] = 0   -- count ALL languages (as per latest change)
    end

	if cjkNgrams then
		-- CJK detection: check all ngrams against every language lookup
		for gram, _ in pairs(cjkNgrams) do
			for i = 1, numLangs do
				local langIdx = langs[i].index
				if lookups[langIdx][gram] then
					local byteLen = string.len(gram)
					local points = math.max(1, byteLen - 2)
					matchCounts[langIdx] = matchCounts[langIdx] + points
				end
			end
		end
	else
		-- Latin/space-separated detection
		for _, word in ipairs(words) do
			local wClean = string.lower(word)
			wClean = string.gsub(wClean, PUNCT_STRIP, "")
			if wClean ~= "" then
				for i = 1, numLangs do
					local langIdx = langs[i].index
					if lookups[langIdx][wClean] then
						local wordLen = string.len(wClean)
						local points = math.max(1, wordLen - 3)
						matchCounts[langIdx] = matchCounts[langIdx] + points
					end
				end
			end
		end
	end

    -- Find winner
    local maxCount = 0
    local sourceIndex = nil
    for langIdx, count in pairs(matchCounts) do
        if count > maxCount then
            maxCount = count
            sourceIndex = langIdx
        end
    end

    if TurtleTranslatorDB.debugEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff88DEBUG|r Detection - words: " .. (function() local c=0 for _ in ipairs(words) do c=c+1 end return c end)() .. " | max matches: " .. maxCount .. " | source: " .. (sourceIndex or "nil"))
    end

    if not sourceIndex or maxCount == 0 then return end
	
	-- Check if user wants to translate FROM this detected language
    if sourceLangs[sourceIndex] ~= true then
        if TurtleTranslatorDB.debugEnabled then
            DEFAULT_CHAT_FRAME:AddMessage("|cff8888ffDEBUG|r Skipped: source language not selected for translation (" .. langs[sourceIndex + 1].name .. ")")
        end
        return
    end

    -- Skip if already in target language
    if sourceIndex == targetIndex then
        if TurtleTranslatorDB.debugEnabled then
            local matchedWords = {}
            for _, word in ipairs(words) do
                local wClean = string.lower(word)
                -- ASCII-only punct strip (safe for Chinese/UTF-8 bytes in Lua 5.0)
                wClean = string.gsub(wClean, [[!?.,;:%(%) "%[%]%-%+%%%^&*=<>{}|_ ]], "")
                if wClean ~= "" and lookups[sourceIndex][wClean] then
                    table.insert(matchedWords, wClean)
                end
            end
            
            local matchList = table.concat(matchedWords, ", ")
            if matchList == "" then
                matchList = "(no matching words found)"
            end
            
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff8888ffDEBUG|r Skipped: source == target (" .. 
                langs[sourceIndex + 1].name .. "). " ..
                "Matched words in source language: " .. matchList
            )
        end
        return
    end

    -- Step 3: Translate with English pivot (any → any)
	local translatedWords = {}

	for _, word in ipairs(words) do
		local wLower
		if hasCJK(word) then
			wLower = word  -- keep CJK as-is, no lower/strip needed
		else
			wLower = string.lower(word)
			wLower = string.gsub(wLower, PUNCT_STRIP, "")
		end

		local translated = word  -- fallback
		
		-- For CJK words, try greedy longest-match ngram translation
		if hasCJK(word) then
			local chars = utf8chars(word)
			local nchars = 0
			for _ in ipairs(chars) do nchars = nchars + 1 end
			local resultParts = {}
			local i = 1
			while i <= nchars do
				local matched = false
				-- Try longest match first (4 chars down to 1)
				for tryLen = math.min(4, nchars - i + 1), 1, -1 do
					local gram = ""
					for j = i, i + tryLen - 1 do gram = gram .. chars[j] end
					local fromIdx = sourceIndex
					local toIdx = targetIndex
					local eng = translations[fromIdx][0] and translations[fromIdx][0][gram]
					if eng ~= nil then  -- nil = not in dict; "" = particle, skip
						if eng ~= "" then
							local final = translations[0][toIdx] and translations[0][toIdx][eng]
							if final and final ~= "" then
								table.insert(resultParts, final)
							else
								table.insert(resultParts, eng)
							end
						end
						-- eng == "" means grammar particle: consume chars, insert nothing
						i = i + tryLen
						matched = true
						break
					end
				end
				if not matched then
					-- Unknown char: skip raw CJK, keep ASCII
					local c = chars[i]
					if string.byte(c, 1) < 128 then
						table.insert(resultParts, c)
					end
					i = i + 1
				end
			end
			translated = table.concat(resultParts, " ")
			-- Clean up any double spaces
			translated = string.gsub(translated, "  +", " ")
		end

		-- Latin/ASCII pivot (skip for CJK words – already handled by greedy ngram above)
		if wLower ~= "" and not hasCJK(word) then
			local fromIdx = sourceIndex
			local toIdx   = targetIndex

			-- Try direct translation first (if we ever add direct dicts)
			local direct = translations[fromIdx][toIdx] and translations[fromIdx][toIdx][wLower]
			
			if direct then
				translated = direct
			else
				-- Pivot: Source → English → Target
				local english = translations[fromIdx][0] and translations[fromIdx][0][wLower]
				if english then
					local final = translations[0][toIdx] and translations[0][toIdx][english]
					if final then
						translated = final
					end
				end
			end

			-- Preserve letter capitalization
			if translated ~= word then
				local wlen = string.len(word)
				if wlen == 0 then 
					-- edge case, shouldn't happen
				else
					local first = string.sub(word, 1, 1)
					local is_all_upper = (string.upper(word) == word) and (wlen > 0)
					
					if is_all_upper then
						-- ALL CAPS original → make translated ALL CAPS
						translated = string.upper(translated)
						
					elseif first >= "A" and first <= "Z" then
						-- First letter was uppercase → capitalize only first letter of translation
						local rest = string.sub(translated, 2)
						if rest then
							translated = string.upper(string.sub(translated, 1, 1)) .. string.lower(rest)
						else
							translated = string.upper(translated)  -- single letter
						end
						
					else
						-- Original started with lowercase → keep translated lowercase
						translated = string.lower(translated)
					end
				end
			end
		end

		table.insert(translatedWords, translated)
	end

	local translated = table.concat(translatedWords, " ")

    DEFAULT_CHAT_FRAME:AddMessage("|cff19e6ca" .. "[TT]" .. "[" .. (author or "?") .. "]" .. ": " .. translated .. "|r (from " .. langs[sourceIndex + 1].name .. ")")
end

-- Event frame (unchanged)
local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_WHISPER")
f:RegisterEvent("CHAT_MSG_SAY")
f:RegisterEvent("CHAT_MSG_YELL")
f:RegisterEvent("CHAT_MSG_PARTY")
f:RegisterEvent("CHAT_MSG_GUILD")
f:RegisterEvent("CHAT_MSG_EMOTE")
f:RegisterEvent("CHAT_MSG_OFFICER")
f:RegisterEvent("CHAT_MSG_RAID")
f:RegisterEvent("CHAT_MSG_RAID_LEADER")
f:RegisterEvent("CHAT_MSG_RAID_WARNING")
f:RegisterEvent("CHAT_MSG_BATTLEGROUND")
f:RegisterEvent("CHAT_MSG_CHANNEL")

f:SetScript("OnEvent", function()
    local shouldTranslate = false

    if event == "CHAT_MSG_WHISPER" 		   and TurtleTranslatorDB.channels.whisper 		  then shouldTranslate = true end
    if event == "CHAT_MSG_SAY"    		   and TurtleTranslatorDB.channels.say     		  then shouldTranslate = true end
    if event == "CHAT_MSG_YELL"    		   and TurtleTranslatorDB.channels.yell    		  then shouldTranslate = true end
    if event == "CHAT_MSG_PARTY"   		   and TurtleTranslatorDB.channels.party   		  then shouldTranslate = true end
	if event == "CHAT_MSG_GUILD"   		   and TurtleTranslatorDB.channels.guild   		  then shouldTranslate = true end
	if event == "CHAT_MSG_EMOTE"   		   and TurtleTranslatorDB.channels.emote   		  then shouldTranslate = true end
	if event == "CHAT_MSG_OFFICER" 		   and TurtleTranslatorDB.channels.officer 		  then shouldTranslate = true end
	
    -- Raid chat (regular + leader messages)
    if (event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER")
       and TurtleTranslatorDB.channels.raid
    then
        shouldTranslate = true
    end
	
	if event == "CHAT_MSG_RAID_WARNING"    and TurtleTranslatorDB.channels.raidwarning    then shouldTranslate = true end
	if event == "CHAT_MSG_BATTLEGROUND"    and TurtleTranslatorDB.channels.battleground   then shouldTranslate = true end
	if event == "CHAT_MSG_CHANNEL"    	   and TurtleTranslatorDB.channels.otherchannels  then shouldTranslate = true end

    if shouldTranslate then
        TranslateMessage(arg1, arg2)
    end
end)

-- Load message (unchanged)
DEFAULT_CHAT_FRAME:AddMessage("|cffffffff[TT]" .. "|cff19e6ca Turtle Translator [" .. ADDON_VERSION .. "]|cffffffff loaded! Use /tt menu for settings.|r")