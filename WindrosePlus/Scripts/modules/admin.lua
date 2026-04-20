-- WindrosePlus Admin Module
-- Server administration commands
-- Called via RCON file IPC only (console commands crash this server)
-- See docs/removed-commands.md for commands that were removed and why

local json = require("modules.json")
local Log = require("modules.log")

local Admin = {}
Admin._commands = {}
Admin._config = nil
Admin._gameDir = nil  -- populated by init() for file-IO commands (wp.givestats queue)
Admin._playerJoinTimes = {}  -- track session join times for wp.playtime
Admin._DEFAULT_PROCESS_NAME = "WindroseServer-Win64-Shipping.exe"
Admin._bootTime = os.time()  -- track server start for uptime (no wmic needed)

function Admin.init(config, gameDir)
    Admin._config = config
    Admin._gameDir = gameDir
    Admin._loadGodmodeCache()
    Admin._registerDamageHooks()
    Admin._registerCommands()
    -- NOTE: RegisterConsoleCommandHandler requires HookProcessConsoleExec=1
    -- which crashes Windrose dedicated servers. Commands are RCON-only.
    Log.info("Admin", Admin._countCommands() .. " commands registered (RCON only)")
end

-- Execute a command. Returns status ("ok"/"error") and message.
function Admin.execute(command, args)
    local cmd = Admin._commands[command] or Admin._commands["wp." .. command]
    if not cmd then
        return "error", "Unknown command: " .. command .. ". Use wp.help for list."
    end
    local ok, result = pcall(cmd.handler, args)
    if ok then
        return "ok", result or "OK"
    else
        return "error", tostring(result)
    end
end

-- Get the configured process name, falling back to the default
function Admin._getProcessName()
    if Admin._config then
        local cfgName = nil
        pcall(function()
            if WindrosePlus and WindrosePlus._modules and WindrosePlus._modules.Config then
                cfgName = WindrosePlus._modules.Config.get("server", "process_name")
            end
        end)
        if cfgName and cfgName ~= "" then return cfgName end
    end
    return Admin._DEFAULT_PROCESS_NAME
end

function Admin._countCommands()
    local n = 0
    for _ in pairs(Admin._commands) do n = n + 1 end
    return n
end

function Admin._registerCommands()

    -- =========================================
    -- General
    -- =========================================

    Admin._commands["wp.help"] = {
        description = "List all commands or get help for a specific command",
        usage = "wp.help [command|all]",
        category = "server",
        handler = function(args)
            -- Per-command help: wp.help status
            if args[1] and args[1]:lower() ~= "all" then
                local cmdName = args[1]:lower()
                if not cmdName:match("^wp%.") then cmdName = "wp." .. cmdName end
                local cmd = Admin._commands[cmdName]
                if cmd then
                    local lines = {cmdName .. " - " .. cmd.description}
                    table.insert(lines, "Usage: " .. cmd.usage)
                    if cmd.examples then
                        table.insert(lines, "Examples:")
                        for _, ex in ipairs(cmd.examples) do
                            table.insert(lines, "  " .. ex)
                        end
                    end
                    return table.concat(lines, "\n")
                end
                return "Unknown command: " .. cmdName
            end

            local showAll = args[1] and args[1]:lower() == "all"
            local categories = {
                {"server", "Server"},
                {"players", "Players"},
                {"world", "World"},
                {"diagnostics", "Diagnostics"},
                {"admin", "Admin"},
                {"debug", "Debug"},
            }
            local lines = {"WindrosePlus Commands:"}
            for _, cat in ipairs(categories) do
                local catId, catLabel = cat[1], cat[2]
                local cmds = {}
                local sorted = {}
                for name in pairs(Admin._commands) do table.insert(sorted, name) end
                table.sort(sorted)
                for _, name in ipairs(sorted) do
                    local cmd = Admin._commands[name]
                    if (cmd.category or "server") == catId and (not cmd.hidden or showAll) then
                        table.insert(cmds, cmd)
                        cmds[#cmds].name = name
                    end
                end
                if #cmds > 0 then
                    table.insert(lines, "\n[" .. catLabel .. "]")
                    for _, cmd in ipairs(cmds) do
                        table.insert(lines, "  " .. cmd.usage .. " - " .. cmd.description)
                    end
                end
            end
            if not showAll then
                table.insert(lines, "\nwp.help <command> for details. wp.help all for debug commands.")
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.status"] = {
        description = "Show server status and multipliers",
        usage = "wp.status",
        category = "server",
        handler = function(args)
            local playerCount = 0
            local pcs = FindAllOf("PlayerController")
            if pcs then
                for _, pc in ipairs(pcs) do
                    if pc:IsValid() and Admin._isConnected(pc) then playerCount = playerCount + 1 end
                end
            end
            local lines = {
                "Players: " .. playerCount,
                "Loot: " .. Admin._config.getLootMultiplier() .. "x",
                "XP: " .. Admin._config.getXpMultiplier() .. "x",
                "Stack Size: " .. Admin._config.getStackSizeMultiplier() .. "x",
                "Craft Cost: " .. Admin._config.getCraftCostMultiplier() .. "x",
                "Crop Speed: " .. Admin._config.getCropSpeedMultiplier() .. "x",
                "Weight: " .. Admin._config.getWeightMultiplier() .. "x",
                "WindrosePlus v" .. (WindrosePlus and WindrosePlus.VERSION or "?")
            }
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.players"] = {
        description = "List online players with positions",
        usage = "wp.players",
        category = "players",
        handler = function(args)
            local players = Admin._getPlayers()
            if #players == 0 then return "No players online" end
            local lines = {"Online (" .. #players .. "):"}
            for i, p in ipairs(players) do
                local posStr = ""
                if p.x then
                    posStr = string.format(" @ %.0f, %.0f, %.0f", p.x, p.y, p.z)
                end
                table.insert(lines, "  " .. i .. ". " .. p.name .. posStr)
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.reload"] = {
        description = "Reload config from disk",
        usage = "wp.reload",
        category = "server",
        handler = function(args)
            Admin._config.reload()
            return "Config reloaded"
        end
    }

    Admin._commands["wp.version"] = {
        description = "Show version",
        usage = "wp.version",
        category = "server",
        handler = function(args) return "WindrosePlus v" .. (WindrosePlus and WindrosePlus.VERSION or "?") end
    }

    Admin._commands["wp.perf"] = {
        description = "Show server performance metrics",
        usage = "wp.perf",
        category = "diagnostics",
        handler = function(args)
            local lines = {"Server Performance:"}

            -- Player count (filtered for active connections)
            pcall(function()
                local pcs = FindAllOf("PlayerController")
                if pcs then
                    local n = 0
                    for _, pc in ipairs(pcs) do
                        if pc:IsValid() and Admin._isConnected(pc) then n = n + 1 end
                    end
                    table.insert(lines, "  Players: " .. n)
                end
            end)

            -- Memory: not available without wmic (would flash CMD window)
            table.insert(lines, "  Memory: use wp.memory for cached data")

            -- Uptime from Lua boot timestamp (no wmic needed)
            pcall(function()
                local diff = os.time() - Admin._bootTime
                local hours = math.floor(diff / 3600)
                local mins = math.floor((diff % 3600) / 60)
                table.insert(lines, "  Uptime: " .. hours .. "h " .. mins .. "m")
            end)

            if #lines == 1 then table.insert(lines, "  No metrics available") end
            return table.concat(lines, "\n")
        end
    }

    -- =========================================
    -- Admin Actions
    -- =========================================

    Admin._commands["wp.speed"] = {
        description = "Set player movement speed multiplier",
        usage = "wp.speed [player] <multiplier>",
        category = "admin",
        examples = {"wp.speed 2.0", "wp.speed HumanGenome 1.5", "wp.speed John Smith 1.5"},
        playerArg = true,
        handler = function(args)
            if #args < 1 then return "Usage: wp.speed <multiplier> or wp.speed <player> <multiplier>\n  1.0 = normal, 2.0 = double speed" end

            -- RCON splits on whitespace and player names can contain spaces.
            -- Treat the last arg as the multiplier; everything before joins as the name.
            -- Issue: HumanGenome/WindrosePlus#5
            local n = #args
            local mult = tonumber(args[n])
            if not mult then
                return "Multiplier must be a number between 0 and 20"
            end
            if mult < 0 or mult > 20 then
                return "Multiplier must be between 0 and 20"
            end
            local targetName = nil
            if n >= 2 then
                targetName = table.concat(args, " ", 1, n - 1):lower()
            end

            local pcs = FindAllOf("PlayerController")
            if not pcs then return "No players found" end

            -- Cache baseline MaxWalkSpeed per-player on first touch so setting the
            -- multiplier back to 1.0 cleanly restores the client-replicated speed
            -- (CheatMovementSpeedModifer alone is server-side and doesn't replicate).
            -- Issue: HumanGenome/WindrosePlus#5
            Admin._origMaxWalkSpeed = Admin._origMaxWalkSpeed or {}

            local count = 0
            for _, pc in ipairs(pcs) do
                if pc:IsValid() then
                    local pName = nil
                    pcall(function()
                        local ps = pc.PlayerState
                        if ps and ps:IsValid() then
                            local val = ps.PlayerNamePrivate
                            if val then
                                local ok, str = pcall(function() return val:ToString() end)
                                if ok and str then pName = str end
                            end
                        end
                    end)

                    local nameMatch = not targetName or (pName and pName:lower() == targetName)
                    if nameMatch then
                        pcall(function()
                            local pawn = pc.Pawn
                            if pawn and pawn:IsValid() then
                                local mc = pawn.CharacterMovement or pawn.MovementComponent
                                if mc and mc:IsValid() then
                                    local key = pName or tostring(pc)
                                    if not Admin._origMaxWalkSpeed[key] then
                                        local ok, orig = pcall(function() return mc.MaxWalkSpeed end)
                                        if ok and orig and orig > 0 then
                                            Admin._origMaxWalkSpeed[key] = orig
                                        end
                                    end
                                    local base = Admin._origMaxWalkSpeed[key]
                                    mc.CheatMovementSpeedModifer = mult
                                    if base then
                                        mc.MaxWalkSpeed = base * mult
                                    end
                                    count = count + 1
                                end
                            end
                        end)
                    end
                end
            end

            if targetName then
                return count > 0 and ("Speed set to " .. mult .. "x for " .. targetName) or ("Player '" .. targetName .. "' not found")
            end
            return "Speed set to " .. mult .. "x for " .. count .. " player(s)"
        end
    }

    -- Helper: find a player's character by name. Accepts either the account
    -- name shown in the dashboard header (resolved via PlayerController ->
    -- PlayerState.PlayerNamePrivate) OR the UE actor name shown by wp.players
    -- (e.g. "BP_R5Character_C_2147419160"). Tries account name first, then
    -- falls back to actor name.
    local function findCharByName(targetName)
        local target = targetName:lower()
        local pcs = FindAllOf("PlayerController")
        if pcs then
            for _, pc in ipairs(pcs) do
                if pc:IsValid() then
                    local pName = nil
                    pcall(function()
                        local ps = pc.PlayerState
                        if ps and ps:IsValid() then
                            local val = ps.PlayerNamePrivate
                            if val then
                                local ok, s = pcall(function() return val:ToString() end)
                                if ok and s then pName = s end
                            end
                        end
                    end)
                    if pName and pName:lower() == target then
                        local pawn = nil
                        pcall(function()
                            if pc.Pawn and pc.Pawn:IsValid() then pawn = pc.Pawn end
                        end)
                        if pawn then return pawn end
                    end
                end
            end
        end
        local chars = FindAllOf("R5Character")
        if chars then
            for _, char in ipairs(chars) do
                if char:IsValid() then
                    local charName = nil
                    pcall(function() charName = char:GetFullName():match("([^%.]+)$") end)
                    if charName and charName:lower() == target then
                        return char
                    end
                end
            end
        end
        return nil
    end

    -- Candidate component names and direct properties that might expose health.
    -- Windrose/R5 uses UE5; "HealthComponent" isn't necessarily what they call
    -- it. Each entry is a { container, propCurrent, propMax } tuple where
    -- container = nil means read directly on the character.
    local HEALTH_PATHS = {
        { "HealthComponent",    "CurrentHealth", "MaxHealth" },
        { "Health",             "CurrentHealth", "MaxHealth" },
        { "HealthSystem",       "CurrentHealth", "MaxHealth" },
        { "R5HealthComponent",  "CurrentHealth", "MaxHealth" },
        { "BLHealthComponent",  "CurrentHealth", "MaxHealth" },
        { "VitalsComponent",    "Health",        "MaxHealth" },
        { "DamageComponent",    "Health",        "MaxHealth" },
        { "StatsComponent",     "Health",        "MaxHealth" },
        { nil,                  "CurrentHealth", "MaxHealth" },
        { nil,                  "Health",        "MaxHealth" },
    }

    -- Resolve the first health path that exists on the given character.
    -- Returns (container, curProp, maxProp, curValue, maxValue) or nil.
    local function resolveHealthPath(char)
        for _, p in ipairs(HEALTH_PATHS) do
            local compName, curProp, maxProp = p[1], p[2], p[3]
            local container = char
            if compName then
                local c = nil
                pcall(function() if char[compName] and char[compName]:IsValid() then c = char[compName] end end)
                container = c
            end
            if container then
                local cur, mx
                pcall(function() cur = container[curProp] end)
                pcall(function() mx = container[maxProp] end)
                -- Require actual numbers, not UObject wrappers (UE5 GAS wraps
                -- attributes in objects — those need a different write path).
                if type(cur) == "number" and type(mx) == "number" and mx > 0 then
                    return container, curProp, maxProp, cur, mx
                end
            end
        end
        return nil
    end

    Admin._commands["wp.godmode"] = {
        description = "Enable/disable invulnerability for a target player",
        usage = "wp.godmode <player> [on|off]",
        category = "admin",
        examples = {"wp.godmode HumanGenome on", "wp.godmode John Smith off", "wp.godmode HumanGenome"},
        playerArg = true,
        handler = function(args)
            if #args < 1 then
                return "Usage: wp.godmode <player> [on|off]\n  Targets a single player. Defaults to 'on' if toggle omitted."
            end

            -- Arg parsing mirrors wp.speed: RCON splits on whitespace and player names
            -- can contain spaces, so treat the last arg as the toggle only if it looks
            -- like one; otherwise the whole arg list is the player name and we default on.
            local n = #args
            local last = args[n] and args[n]:lower() or ""
            local enable
            local targetName
            if last == "on" or last == "true" or last == "1" or last == "enable" then
                enable = true
                targetName = n >= 2 and table.concat(args, " ", 1, n - 1):lower() or nil
            elseif last == "off" or last == "false" or last == "0" or last == "disable" then
                enable = false
                targetName = n >= 2 and table.concat(args, " ", 1, n - 1):lower() or nil
            else
                enable = true
                targetName = table.concat(args, " "):lower()
            end

            if not targetName or targetName == "" then
                return "Player name required (god mode must target a specific player)"
            end

            local char = findCharByName(targetName)
            if not char then return "Player '" .. targetName .. "' not found" end

            -- Cache original health per-player so disabling cleanly restores them.
            Admin._origHealth = Admin._origHealth or {}

            local GOD_HP = 9999999

            -- Belt: flip any invuln flags the engine actually exposes.
            pcall(function() char.bCanBeDamaged = not enable end)
            pcall(function() char.bIsInvulnerable = enable end)
            pcall(function() char.bInvincible = enable end)

            -- Suspenders: clamp health via whichever path actually exists on
            -- this build. If none of the candidate paths has both current+max
            -- props, we can only rely on the flags.
            local healthApplied = false
            local noSnapshot = false
            local cacheDirty = false
            local usedPath = nil

            local container, curProp, maxProp, curVal, maxVal = resolveHealthPath(char)
            if container then
                usedPath = (container == char) and ("char." .. curProp) or ("<component>." .. curProp)
                if enable then
                    if not Admin._origHealth[targetName] then
                        if curVal and maxVal and maxVal > 0 then
                            Admin._origHealth[targetName] = { current = curVal, max = maxVal }
                            cacheDirty = true
                        end
                    end
                    pcall(function() container[maxProp] = GOD_HP end)
                    pcall(function() container[curProp] = GOD_HP end)
                    healthApplied = true
                else
                    local snap = Admin._origHealth[targetName]
                    if snap then
                        pcall(function() container[maxProp] = snap.max end)
                        pcall(function() container[curProp] = math.min(snap.current, snap.max) end)
                        Admin._origHealth[targetName] = nil
                        cacheDirty = true
                        healthApplied = true
                    else
                        noSnapshot = true
                    end
                end
            end

            if cacheDirty then Admin._saveGodmodeCache() end

            local status = enable and "enabled" or "disabled"
            local detail
            if healthApplied then
                detail = enable and (" (HP " .. GOD_HP .. " via " .. usedPath .. ", original cached)") or " (HP restored)"
            elseif enable then
                detail = " (warning: no health path matched; flags set but server-side damage may still kill — run wp.probe_char " .. targetName .. ")"
            elseif noSnapshot then
                detail = " (no cached baseline, health left as-is)"
            else
                detail = ""
            end
            return "God mode " .. status .. " for " .. targetName .. detail
        end
    }

    Admin._commands["wp.probe_char"] = {
        hidden = true, category = "debug",
        description = "List which candidate component names exist on a player's character (read-only, no traversal)",
        usage = "wp.probe_char <player>",
        playerArg = true,
        handler = function(args)
            if #args < 1 then return "Usage: wp.probe_char <player>" end
            local targetName = table.concat(args, " "):lower()
            local char = findCharByName(targetName)
            if not char then return "Player '" .. targetName .. "' not found" end

            -- Minimal probe. Only reads char[name] and reports whether it's
            -- non-nil and the Lua type. No :IsValid(), no :GetClass(), no
            -- recursion into UObject props — those can trigger C++ exceptions
            -- that bypass pcall and crash UE4SS. Use wp.probe_prop once you
            -- know which component to drill into.
            local names = {
                "HealthComponent", "Health", "HealthSystem", "R5HealthComponent",
                "BLHealthComponent", "VitalsComponent", "DamageComponent",
                "StatsComponent", "AttributeComponent", "AttributeSet",
                "AbilitySystemComponent", "StaminaComponent", "HungerComponent",
                "ThirstComponent",
                -- direct-scalar candidates (bools/numbers)
                "bCanBeDamaged", "bIsInvulnerable", "bInvincible", "bGodMode",
            }
            local lines = { "char property presence (non-nil only):" }
            for _, name in ipairs(names) do
                local v
                pcall(function() v = char[name] end)
                if v ~= nil then
                    table.insert(lines, "  " .. name .. " :: " .. type(v))
                end
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.probe_prop"] = {
        hidden = true, category = "debug",
        description = "Read a dotted property path on a player's character. Read-only, one level at a time.",
        usage = "wp.probe_prop <player> <dotted.path>",
        examples = {
            "wp.probe_prop CatCafe HealthComponent",
            "wp.probe_prop CatCafe HealthComponent.CurrentHealth",
            "wp.probe_prop CatCafe HealthComponent.CurrentHealth.BaseValue",
        },
        playerArg = true,
        handler = function(args)
            if #args < 2 then return "Usage: wp.probe_prop <player> <dotted.path>" end
            -- Last arg is the path; everything before is the player name.
            local path = args[#args]
            local targetName = table.concat(args, " ", 1, #args - 1):lower()
            local char = findCharByName(targetName)
            if not char then return "Player '" .. targetName .. "' not found" end

            local cur = char
            local trail = "char"
            for segment in path:gmatch("[^%.]+") do
                local next_v
                pcall(function() next_v = cur[segment] end)
                if next_v == nil then
                    return trail .. "." .. segment .. " = nil"
                end
                cur = next_v
                trail = trail .. "." .. segment
            end
            -- Report type + tostring. Do NOT call any methods on the value.
            return trail .. " :: " .. type(cur) .. " = " .. tostring(cur)
        end
    }

    Admin._commands["wp.probe_at"] = {
        hidden = true, category = "debug",
        description = "At a dotted path, list which of a fixed set of candidate property names exist. Safe: only indexes, never calls methods.",
        usage = "wp.probe_at <player> <dotted.path>",
        examples = {
            "wp.probe_at CatCafe HealthComponent.CurrentHealth",
            "wp.probe_at CatCafe HealthComponent.CurrentHealth.BaseValue",
        },
        playerArg = true,
        handler = function(args)
            if #args < 2 then return "Usage: wp.probe_at <player> <dotted.path>" end
            local path = args[#args]
            local targetName = table.concat(args, " ", 1, #args - 1):lower()
            local char = findCharByName(targetName)
            if not char then return "Player '" .. targetName .. "' not found" end

            -- Walk the path with pure indexing.
            local parent = char
            local trail = "char"
            for segment in path:gmatch("[^%.]+") do
                local next_v
                pcall(function() next_v = parent[segment] end)
                if next_v == nil then
                    return trail .. "." .. segment .. " = nil (path incomplete)"
                end
                parent = next_v
                trail = trail .. "." .. segment
            end

            -- Hardcoded candidate list — covers UE5 GAS + common R5/Windrose
            -- attribute wrappers. No method calls on any value, just index +
            -- type(). Safe even if some candidates exist as weird userdata.
            local CANDIDATES = {
                "Value", "BaseValue", "CurrentValue", "DefaultValue",
                "Base", "Current", "Initial", "Raw",
                "Float", "FloatValue", "NumericValue",
                "Amount", "Stat", "StatValue", "Number",
                "Min", "Max", "Minimum", "Maximum",
                "Level", "Tier",
                "bOverridden", "bClamped",
                "Attribute", "AttributeValue", "InternalValue",
                "Data", "AttributeData",
            }
            local lines = { "probing at " .. trail .. " (type=" .. type(parent) .. "):" }
            local found = 0
            for _, name in ipairs(CANDIDATES) do
                local v
                pcall(function() v = parent[name] end)
                if v ~= nil then
                    found = found + 1
                    local display
                    if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                        display = tostring(v)
                    else
                        display = type(v) .. " " .. tostring(v)
                    end
                    table.insert(lines, "  " .. name .. " = " .. display)
                end
            end
            if found == 0 then
                table.insert(lines, "  (none of the standard candidates matched — try wp.probe_prop with specific guesses)")
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.damage_probe"] = {
        hidden = true, category = "debug",
        description = "Diagnostic: count which damage UFunctions fire during play. Precursor to hook-based per-player godmode.",
        usage = "wp.damage_probe <on|off|reset|stats>",
        examples = {
            "wp.damage_probe on",
            "wp.damage_probe stats",
            "wp.damage_probe off",
        },
        handler = function(args)
            local action = (args[1] or "stats"):lower()
            if action == "on" then
                Admin._damageHookEnabled = true
                return "Damage probe ENABLED. Take damage in-game, then run 'wp.damage_probe stats'. Remember to 'wp.damage_probe off' afterwards — these hooks fire on every damage event for every actor on the server."
            elseif action == "off" then
                Admin._damageHookEnabled = false
                return "Damage probe disabled."
            elseif action == "reset" then
                Admin._damageHookCounters = {}
                Admin._damageHookLastFire = {}
                return "Counters cleared."
            elseif action == "stats" then
                local keys = {}
                for k in pairs(Admin._damageHookCounters) do table.insert(keys, k) end
                table.sort(keys, function(a, b)
                    return (Admin._damageHookCounters[a] or 0) > (Admin._damageHookCounters[b] or 0)
                end)
                if #keys == 0 then
                    return "No damage hooks have fired. State: " .. (Admin._damageHookEnabled and "ENABLED" or "disabled") .. ". Turn it on with 'wp.damage_probe on' and take damage."
                end
                local now = os.time()
                local lines = { "Damage hook fires (state: " .. (Admin._damageHookEnabled and "ENABLED" or "disabled") .. "):" }
                for _, k in ipairs(keys) do
                    local count = Admin._damageHookCounters[k]
                    local last = Admin._damageHookLastFire[k]
                    local ago = last and (now - last) or 0
                    table.insert(lines, string.format("  %d fires, %ds ago | %s", count, ago, k))
                end
                return table.concat(lines, "\n")
            else
                return "Usage: wp.damage_probe <on|off|reset|stats>"
            end
        end
    }

    -- =========================================
    -- Player state: heal / kill / freeze
    -- =========================================

    Admin._commands["wp.heal"] = {
        description = "Restore a player's HP to full",
        usage = "wp.heal <player>",
        category = "admin",
        examples = {"wp.heal HumanGenome", "wp.heal John Smith"},
        playerArg = true,
        handler = function(args)
            if #args < 1 then return "Usage: wp.heal <player>" end
            local targetName = table.concat(args, " "):lower()
            local char = findCharByName(targetName)
            if not char then return "Player '" .. targetName .. "' not found" end
            local applied = false
            pcall(function()
                local hc = char.HealthComponent
                if hc and hc:IsValid() then
                    local mx = hc.MaxHealth
                    if mx and mx > 0 then
                        hc.CurrentHealth = mx
                        applied = true
                    end
                end
            end)
            if not applied then return "HealthComponent not found or MaxHealth invalid for " .. targetName end
            return "Healed " .. targetName .. " to full HP"
        end
    }

    Admin._commands["wp.kill"] = {
        description = "Kill a player (sets HP to 0)",
        usage = "wp.kill <player>",
        category = "admin",
        examples = {"wp.kill HumanGenome"},
        playerArg = true,
        handler = function(args)
            if #args < 1 then return "Usage: wp.kill <player>" end
            local targetName = table.concat(args, " "):lower()
            -- Refuse to kill while god mode is active — the disable path would
            -- restore health from the snapshot later, producing confusing state.
            if Admin._origHealth and Admin._origHealth[targetName] then
                return "Refusing: " .. targetName .. " has god mode active. Run 'wp.godmode " .. targetName .. " off' first."
            end
            local char = findCharByName(targetName)
            if not char then return "Player '" .. targetName .. "' not found" end
            local applied = false
            pcall(function()
                local hc = char.HealthComponent
                if hc and hc:IsValid() then
                    hc.CurrentHealth = 0
                    applied = true
                end
            end)
            if not applied then return "HealthComponent not found for " .. targetName end
            return "Killed " .. targetName
        end
    }

    -- Freeze stashes (modifier, maxwalkspeed) snapshots so unfreeze restores to
    -- whatever wp.speed had set prior — not to hardcoded defaults.
    Admin._origFreeze = Admin._origFreeze or {}

    Admin._commands["wp.freeze"] = {
        description = "Freeze/unfreeze a player's movement",
        usage = "wp.freeze <player> [on|off]",
        category = "admin",
        examples = {"wp.freeze HumanGenome on", "wp.freeze John Smith off"},
        playerArg = true,
        handler = function(args)
            if #args < 1 then return "Usage: wp.freeze <player> [on|off]" end
            local n = #args
            local last = args[n] and args[n]:lower() or ""
            local enable, targetName
            if last == "on" or last == "true" or last == "1" then
                enable = true
                targetName = n >= 2 and table.concat(args, " ", 1, n - 1):lower() or nil
            elseif last == "off" or last == "false" or last == "0" then
                enable = false
                targetName = n >= 2 and table.concat(args, " ", 1, n - 1):lower() or nil
            else
                enable = true
                targetName = table.concat(args, " "):lower()
            end
            if not targetName or targetName == "" then return "Player name required" end

            local pcs = FindAllOf("PlayerController")
            if not pcs then return "No players found" end
            local applied = 0
            for _, pc in ipairs(pcs) do
                if pc:IsValid() then
                    local pName = nil
                    pcall(function()
                        local ps = pc.PlayerState
                        if ps and ps:IsValid() then
                            local val = ps.PlayerNamePrivate
                            if val then
                                local ok, s = pcall(function() return val:ToString() end)
                                if ok and s then pName = s end
                            end
                        end
                    end)
                    if pName and pName:lower() == targetName then
                        pcall(function()
                            local pawn = pc.Pawn
                            if pawn and pawn:IsValid() then
                                local mc = pawn.CharacterMovement or pawn.MovementComponent
                                if mc and mc:IsValid() then
                                    if enable then
                                        if not Admin._origFreeze[targetName] then
                                            local okMod, mod = pcall(function() return mc.CheatMovementSpeedModifer end)
                                            local okMw, mw = pcall(function() return mc.MaxWalkSpeed end)
                                            Admin._origFreeze[targetName] = {
                                                modifier = okMod and mod or 1.0,
                                                maxWalk = okMw and mw or nil
                                            }
                                        end
                                        mc.CheatMovementSpeedModifer = 0
                                        mc.MaxWalkSpeed = 0
                                        applied = applied + 1
                                    else
                                        local snap = Admin._origFreeze[targetName]
                                        if snap then
                                            mc.CheatMovementSpeedModifer = snap.modifier or 1.0
                                            if snap.maxWalk then mc.MaxWalkSpeed = snap.maxWalk end
                                            Admin._origFreeze[targetName] = nil
                                            applied = applied + 1
                                        end
                                    end
                                end
                            end
                        end)
                    end
                end
            end
            if applied == 0 then
                if not enable and not Admin._origFreeze[targetName] then
                    return "Player '" .. targetName .. "' was not frozen"
                end
                return "Player '" .. targetName .. "' not found"
            end
            return (enable and "Froze " or "Unfroze ") .. targetName
        end
    }

    -- =========================================
    -- Teleport
    -- =========================================

    -- Helper: attempt to move a character to (x,y,z). Tries K2_SetActorLocation
    -- first (handles replication), falls back to direct RootComponent write.
    -- Returns true on success.
    local function setCharLocation(char, x, y, z)
        local vec = { X = x, Y = y, Z = z }
        local ok = false
        pcall(function()
            if char.K2_SetActorLocation then
                char:K2_SetActorLocation(vec, false, {}, false)
                ok = true
            end
        end)
        if ok then return true end
        pcall(function()
            if char.SetActorLocation then
                char:SetActorLocation(vec, false, {}, false)
                ok = true
            end
        end)
        if ok then return true end
        pcall(function()
            local root = char.RootComponent
            if root and root:IsValid() then
                root.RelativeLocation = vec
                ok = true
            end
        end)
        return ok
    end

    -- Helper: read a character's current world position (mirrors _getPlayers logic).
    local function getCharLocation(char)
        local x, y, z
        pcall(function()
            local rm = char.ReplicatedMovement
            if rm then
                local loc = rm.Location
                if loc then x, y, z = loc.X, loc.Y, loc.Z end
            end
        end)
        if not x then
            pcall(function()
                local root = char.RootComponent
                if root and root:IsValid() then
                    local rel = root.RelativeLocation
                    if rel then x, y, z = rel.X, rel.Y, rel.Z end
                end
            end)
        end
        return x, y, z
    end

    Admin._commands["wp.teleport"] = {
        description = "Teleport a player to coordinates",
        usage = "wp.teleport <player> <x> <y> <z>",
        category = "admin",
        examples = {"wp.teleport HumanGenome 1000 2000 150", "wp.teleport John Smith -450 1200 80"},
        playerArg = true,
        handler = function(args)
            if #args < 4 then return "Usage: wp.teleport <player> <x> <y> <z>" end
            local n = #args
            local x = tonumber(args[n - 2])
            local y = tonumber(args[n - 1])
            local z = tonumber(args[n])
            if not (x and y and z) then return "x, y, z must be numbers" end
            local targetName = table.concat(args, " ", 1, n - 3):lower()
            if targetName == "" then return "Player name required" end
            local char = findCharByName(targetName)
            if not char then return "Player '" .. targetName .. "' not found" end
            if not setCharLocation(char, x, y, z) then
                return "Failed to move " .. targetName .. " (no writable location method found)"
            end
            return string.format("Teleported %s to X=%.1f Y=%.1f Z=%.1f", targetName, x, y, z)
        end
    }

    Admin._commands["wp.tp"] = {
        description = "Teleport one player to another",
        usage = "wp.tp <source> to <destination>",
        category = "admin",
        examples = {"wp.tp Alice to Bob", "wp.tp John Smith to Jane Doe"},
        playerArg = true,
        handler = function(args)
            if #args < 3 then return "Usage: wp.tp <source> to <destination>" end
            -- Split args on the literal token "to" (case-insensitive). Names on
            -- each side may contain spaces.
            local splitIdx = nil
            for i, a in ipairs(args) do
                if a:lower() == "to" then splitIdx = i; break end
            end
            if not splitIdx or splitIdx == 1 or splitIdx == #args then
                return "Expected: wp.tp <source> to <destination>"
            end
            local srcName = table.concat(args, " ", 1, splitIdx - 1):lower()
            local dstName = table.concat(args, " ", splitIdx + 1):lower()
            local srcChar = findCharByName(srcName)
            if not srcChar then return "Source player '" .. srcName .. "' not found" end
            local dstChar = findCharByName(dstName)
            if not dstChar then return "Destination player '" .. dstName .. "' not found" end
            local x, y, z = getCharLocation(dstChar)
            if not x then return "Could not read destination position" end
            if not setCharLocation(srcChar, x, y, z) then
                return "Failed to move " .. srcName
            end
            return string.format("Teleported %s to %s (%.1f, %.1f, %.1f)", srcName, dstName, x, y, z)
        end
    }

    -- =========================================
    -- World: settime
    -- =========================================

    Admin._commands["wp.settime"] = {
        description = "Set world time of day (hours, 0-24)",
        usage = "wp.settime <hour>",
        category = "world",
        examples = {"wp.settime 12", "wp.settime 0.5", "wp.settime 23.75"},
        handler = function(args)
            if #args < 1 then return "Usage: wp.settime <hour>  (0-24)" end
            local hour = tonumber(args[1])
            if not hour then return "Hour must be a number" end
            if hour < 0 or hour > 24 then return "Hour must be between 0 and 24" end

            local types = {"R5GameMode", "R5GameState", "GameState", "WorldSettings"}
            local props = {"TimeOfDay", "CurrentTimeOfDay"}
            local writes = 0
            local attempts = {}
            for _, t in ipairs(types) do
                local objs = FindAllOf(t)
                if objs then
                    for _, obj in ipairs(objs) do
                        if obj:IsValid() then
                            for _, p in ipairs(props) do
                                pcall(function()
                                    -- Only write to props that exist (reading first keeps
                                    -- us from creating new fields on unrelated objects).
                                    local cur = obj[p]
                                    if cur ~= nil then
                                        obj[p] = hour
                                        writes = writes + 1
                                        table.insert(attempts, t .. "." .. p)
                                    end
                                end)
                            end
                        end
                    end
                end
            end
            if writes == 0 then return "No writable time property found (tried TimeOfDay/CurrentTimeOfDay on R5GameMode/GameState/WorldSettings)" end
            return "Set time to " .. hour .. " on: " .. table.concat(attempts, ", ")
        end
    }

    -- =========================================
    -- Inventory: give (experimental)
    -- =========================================

    -- Props checked post-spawn to avoid spawning N separate actors for stackables.
    local STACK_PROPS = { "StackCount", "Count", "Amount", "Quantity", "ItemCount", "StackSize" }

    -- Helper: spawn `cls` at (location, rotation) in `world`, trying the two
    -- common UE4SS SpawnActor signatures. Returns the actor or nil.
    local function spawnItemActor(world, cls, location, rotation)
        local actor = nil
        pcall(function()
            local a = world:SpawnActor(cls, location, rotation)
            if a and a:IsValid() then actor = a end
        end)
        if actor then return actor end
        pcall(function()
            local a = world:SpawnActor(cls, { Translation = location, Rotation = rotation, Scale3D = { X = 1, Y = 1, Z = 1 } })
            if a and a:IsValid() then actor = a end
        end)
        return actor
    end

    Admin._commands["wp.give"] = {
        description = "Spawn an item at a player's feet (see docs/items.md)",
        usage = "wp.give <player> <blueprint_path> [qty]",
        category = "admin",
        examples = {
            "wp.give HumanGenome /Game/Core/Items/Currency/BP_GoldCoin.BP_GoldCoin_C 100",
            "wp.give Alice /Game/Core/Items/Weapons/Ranged/BP_Flintlock.BP_Flintlock_C",
        },
        playerArg = true,
        handler = function(args)
            if #args < 2 then return "Usage: wp.give <player> <blueprint_path> [qty]" end
            -- Blueprint paths never contain spaces, so parsing is unambiguous:
            -- last arg = qty if numeric, otherwise last arg = blueprint.
            local n = #args
            local qty = 1
            local lastNum = tonumber(args[n])
            local bpIdx
            if lastNum and lastNum > 0 then
                qty = math.floor(lastNum)
                bpIdx = n - 1
            else
                bpIdx = n
            end
            if bpIdx < 2 then return "Missing player or blueprint path" end
            local bp = args[bpIdx]
            if not bp:find("^/") then
                return "Blueprint path must start with '/' (e.g., /Game/Core/Items/.../BP_X.BP_X_C). See docs/items.md"
            end
            local targetName = table.concat(args, " ", 1, bpIdx - 1):lower()
            if targetName == "" then return "Player name required" end
            if qty < 1 or qty > 1000 then return "qty must be between 1 and 1000" end

            local char = findCharByName(targetName)
            if not char then return "Player '" .. targetName .. "' not found" end

            local cls = nil
            pcall(function() cls = StaticFindObject(bp) end)
            if not cls then
                return "Blueprint class not found: " .. bp .. " (check path, must include trailing _C)"
            end

            -- Get world (prefer via char since we know it's valid).
            local world = nil
            pcall(function() world = char:GetWorld() end)
            if not world or not world:IsValid() then
                pcall(function()
                    local worlds = FindAllOf("World")
                    if worlds and worlds[1] and worlds[1]:IsValid() then world = worlds[1] end
                end)
            end
            if not world or not world:IsValid() then
                return "Could not obtain UWorld reference"
            end

            -- Target spawn location: feet of the target player.
            local x, y, z = getCharLocation(char)
            if not x then return "Could not read " .. targetName .. "'s position" end
            local rotation = { Pitch = 0, Yaw = 0, Roll = 0 }

            -- First, try to spawn one and set a stack-count prop to `qty`.
            -- If no stack prop exists, fall back to spawning qty copies with
            -- small positional jitter so they don't clip into one point.
            local first = spawnItemActor(world, cls, { X = x, Y = y, Z = z }, rotation)
            if not first then
                return "SpawnActor failed for " .. bp .. " (signature mismatch or class not spawnable)"
            end

            local stackProp = nil
            for _, p in ipairs(STACK_PROPS) do
                local exists = false
                pcall(function() if first[p] ~= nil then exists = true end end)
                if exists then stackProp = p; break end
            end

            if stackProp and qty > 1 then
                local ok = pcall(function() first[stackProp] = qty end)
                if ok then
                    return string.format("Spawned %s x%d at %s's feet (stacked via %s)", bp, qty, targetName, stackProp)
                end
                -- fall through to loop-spawn if the write threw
            end

            if qty == 1 then
                return "Spawned 1x " .. bp .. " at " .. targetName .. "'s feet"
            end

            -- No stack prop (or write failed): spawn the remaining qty-1 with a
            -- tiny XY jitter so they don't all overlap at the same point.
            local spawned = 1
            for i = 2, qty do
                local jx = x + ((i - 1) % 5) * 20 - 40
                local jy = y + math.floor((i - 1) / 5) * 20 - 40
                local a = spawnItemActor(world, cls, { X = jx, Y = jy, Z = z }, rotation)
                if a then spawned = spawned + 1 end
            end
            if spawned < qty then
                return string.format("Spawned %d/%d copies of %s (some spawns failed)", spawned, qty, bp)
            end
            return string.format("Spawned %d copies of %s at %s's feet", spawned, bp, targetName)
        end
    }

    Admin._commands["wp.health"] = {
        description = "Read player health",
        usage = "wp.health [player]",
        category = "players",
        playerArg = true,
        handler = function(args)
            local players = Admin._findPlayersByName(args[1])
            if #players == 0 then return args[1] and ("Player '" .. args[1] .. "' not found") or "No players online" end

            local lines = {}
            local chars = FindAllOf("R5Character")
            if not chars then return "No character data" end
            for _, p in ipairs(players) do
                for _, char in ipairs(chars) do
                    if char:IsValid() then
                        local charName = nil
                        pcall(function() charName = char:GetFullName():match("([^%.]+)$") end)
                        if charName == p.name then
                            pcall(function()
                                local hc = char.HealthComponent
                                if hc and hc:IsValid() then
                                    local hp = hc.CurrentHealth
                                    local maxHp = hc.MaxHealth
                                    table.insert(lines, p.name .. ": " .. (hp and tostring(hp) or "?") .. "/" .. (maxHp and tostring(maxHp) or "?") .. " HP")
                                else
                                    table.insert(lines, p.name .. ": No HealthComponent")
                                end
                            end)
                            break
                        end
                    end
                end
            end
            return #lines > 0 and table.concat(lines, "\n") or "No health data"
        end
    }

    Admin._commands["wp.pos"] = {
        description = "Get player positions",
        usage = "wp.pos [player]",
        category = "players",
        playerArg = true,
        handler = function(args)
            local players = Admin._findPlayersByName(args[1])
            if #players == 0 then return args[1] and ("Player '" .. args[1] .. "' not found") or "No players online" end
            local lines = {}
            for _, p in ipairs(players) do
                if p.x then
                    table.insert(lines, string.format("%s: X=%.1f Y=%.1f Z=%.1f", p.name, p.x, p.y, p.z))
                else
                    table.insert(lines, p.name .. ": position unknown")
                end
            end
            return table.concat(lines, "\n")
        end
    }

    -- =========================================
    -- Real-time Game Settings (modify UE4 objects live)
    -- =========================================

    Admin._commands["wp.time"] = {
        description = "Read current time of day values",
        usage = "wp.time",
        category = "world",
        handler = function(args)
            local types = {"R5GameMode", "R5GameState", "GameState", "WorldSettings"}
            local timeProps = {"TimeOfDay", "CurrentTimeOfDay", "DayCycleDuration",
                               "NightCycleDuration", "DayNightCycleSpeed", "DayLength", "NightLength"}
            local lines = {}
            for _, t in ipairs(types) do
                local objs = FindAllOf(t)
                if objs then
                    for _, obj in ipairs(objs) do
                        if obj:IsValid() then
                            for _, p in ipairs(timeProps) do
                                pcall(function()
                                    local v = obj[p]
                                    if v ~= nil then table.insert(lines, t .. "." .. p .. " = " .. tostring(v)) end
                                end)
                            end
                        end
                    end
                end
            end
            return #lines > 0 and table.concat(lines, "\n") or "No time properties found"
        end
    }

    Admin._commands["wp.stamina"] = {
        description = "Read stamina/hunger/thirst for players",
        usage = "wp.stamina [player]",
        category = "players",
        playerArg = true,
        handler = function(args)
            local targetName = args[1] and args[1]:lower() or nil
            local chars = FindAllOf("R5Character")
            if not chars then return "No character data" end

            local lines = {}
            for _, char in ipairs(chars) do
                if char:IsValid() then
                    local charName = nil
                    pcall(function() charName = char:GetFullName():match("([^%.]+)$") end)

                    local nameMatch = not targetName or (charName and charName:lower() == targetName)
                    if nameMatch then
                        local playerLines = {}
                        for _, comp in ipairs({"StaminaComponent", "HungerComponent", "ThirstComponent"}) do
                            pcall(function()
                                local c = char[comp]
                                if c and c:IsValid() then
                                    local props = {"CurrentStamina", "MaxStamina", "CurrentValue", "MaxValue",
                                                   "CurrentHunger", "MaxHunger", "CurrentThirst", "MaxThirst"}
                                    for _, p in ipairs(props) do
                                        pcall(function()
                                            local v = c[p]
                                            if v ~= nil then
                                                table.insert(playerLines, "  " .. comp .. "." .. p .. " = " .. tostring(v))
                                            end
                                        end)
                                    end
                                end
                            end)
                        end
                        if #playerLines > 0 then
                            table.insert(lines, (charName or "Unknown") .. ":")
                            for _, l in ipairs(playerLines) do table.insert(lines, l) end
                        end
                    end
                end
            end
            if #lines == 0 and targetName then return "Player '" .. targetName .. "' not found" end
            return #lines > 0 and table.concat(lines, "\n") or "No stamina data"
        end
    }

    Admin._commands["wp.discover"] = {
        hidden = true, category = "debug",
        description = "Discover all properties on a UE4 type by brute-force probing",
        usage = "wp.discover <TypeName>",
        handler = function(args)
            if #args < 1 then return "Usage: wp.discover R5GameMode" end
            local typeName = args[1]
            local obj = Admin._findFirstValid(typeName)
            if not obj then return typeName .. ": not found" end

            local found = Admin._probeObject(obj)
            local lines = {typeName .. " discovered properties:"}
            for _, entry in ipairs(found) do
                table.insert(lines, "  " .. entry.name .. " = " .. entry.value)
            end
            if #lines == 1 then table.insert(lines, "  (none found — use wp.inspect for raw view)") end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.gm"] = {
        hidden = true, category = "debug",
        description = "Read any R5GameMode property",
        usage = "wp.gm <property>",
        handler = function(args)
            if #args < 1 then return "Usage: wp.gm <property>\nExample: wp.gm XPMultiplier\nUse wp.settings to see all properties" end
            local prop = args[1]
            local obj = Admin._findFirstValid("R5GameMode")
            if not obj then return "R5GameMode not found" end

            local ok, val = pcall(function() return obj[prop] end)
            if not ok then return prop .. ": not found" end
            if val == nil then return prop .. ": nil" end
            local display = tostring(val)
            pcall(function() local s = val:ToString(); if s and s ~= "" then display = s end end)
            return prop .. " = " .. display
        end
    }

    Admin._commands["wp.settings"] = {
        hidden = true, category = "debug",
        description = "List all R5GameMode settings with current values",
        usage = "wp.settings [filter]",
        handler = function(args)
            local filter = args[1] and args[1]:lower() or nil
            local obj = Admin._findFirstValid("R5GameMode")
            if not obj then return "R5GameMode not found" end

            local found = Admin._probeObject(obj, filter)
            local lines = {"R5GameMode Settings:"}
            for _, entry in ipairs(found) do
                table.insert(lines, "  " .. entry.name .. " = " .. entry.value)
            end
            if #lines == 1 then
                table.insert(lines, "  (No readable values — use wp.gm <property> to read individual values)")
            end
            return table.concat(lines, "\n")
        end
    }

    -- =========================================
    -- Debug
    -- =========================================

    Admin._commands["wp.inspect"] = {
        hidden = true, category = "debug",
        description = "Inspect a UObject type (count + first instance details)",
        usage = "wp.inspect <TypeName>",
        handler = function(args)
            if #args < 1 then return "Usage: wp.inspect R5Character" end
            local typeName = args[1]
            local results = FindAllOf(typeName)
            if not results then return typeName .. ": not found" end
            local count = 0
            local details = {}
            for _, obj in ipairs(results) do
                if obj:IsValid() then
                    count = count + 1
                    if count <= 3 then
                        table.insert(details, obj:GetFullName())
                    end
                end
            end
            local lines = {typeName .. ": " .. count .. " instance(s)"}
            for _, d in ipairs(details) do table.insert(lines, "  " .. d) end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.props"] = {
        hidden = true, category = "debug",
        description = "List all properties on first instance of a UObject type",
        usage = "wp.props <TypeName> [filter]",
        handler = function(args)
            if #args < 1 then return "Usage: wp.props R5GameMode [filter]" end
            local typeName = args[1]
            local filter = args[2] and args[2]:lower() or nil
            local obj = Admin._findFirstValid(typeName)
            if not obj then return typeName .. ": not found" end

            local found = Admin._probeObject(obj, filter)
            local lines = {typeName .. " properties:"}
            for _, entry in ipairs(found) do
                table.insert(lines, "  " .. entry.name .. " = " .. entry.value)
            end
            if #lines == 1 then table.insert(lines, "  (no known properties found — try wp.inspect for raw view)") end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.probe_player"] = {
        hidden = true, category = "debug",
        description = "Probe all name-related properties on connected players",
        usage = "wp.probe_player",
        handler = function(args)
            local lines = {}
            -- Probe R5PlayerState
            local states = FindAllOf("R5PlayerState")
            if states then
                for i, ps in ipairs(states) do
                    if ps:IsValid() then
                        table.insert(lines, "--- R5PlayerState #" .. i .. " ---")
                        table.insert(lines, "FullName: " .. ps:GetFullName())
                        local props = {
                            "NickName", "PlayerName", "PlayerNamePrivate", "SavedNetworkAddress",
                            "UniqueId", "PlayerId", "PlayerIndex", "CompressedPing",
                            "DisplayName", "UserName", "AccountName", "CharacterName",
                            "SteamName", "PlatformName", "OnlineName", "Name",
                            "ServerNickName", "R5NickName", "R5PlayerName",
                            "PlayerNickName", "AccountId", "PlatformId", "SteamId",
                            "EpicAccountId", "PlatformAccountId", "UniqueNetId"
                        }
                        for _, prop in ipairs(props) do
                            local ok, val = pcall(function() return ps[prop] end)
                            if ok and val ~= nil then
                                -- Try :ToString() for FString/FText/FName types
                                local strOk, strVal = pcall(function() return val:ToString() end)
                                if strOk and strVal and strVal ~= "" then
                                    table.insert(lines, "  " .. prop .. " = [str] " .. strVal)
                                else
                                    table.insert(lines, "  " .. prop .. " = " .. tostring(val))
                                end
                            end
                        end
                    end
                end
            else
                table.insert(lines, "No R5PlayerState found")
            end

            -- Probe PlayerController
            local pcs = FindAllOf("PlayerController")
            if pcs then
                for i, pc in ipairs(pcs) do
                    if pc:IsValid() then
                        table.insert(lines, "--- PlayerController #" .. i .. " ---")
                        table.insert(lines, "FullName: " .. pc:GetFullName())
                        local props = {"PlayerState", "Player", "NetPlayerIndex"}
                        for _, prop in ipairs(props) do
                            local ok, val = pcall(function() return pc[prop] end)
                            if ok and val ~= nil then
                                table.insert(lines, "  " .. prop .. " = " .. tostring(val))
                            end
                        end
                    end
                end
            else
                table.insert(lines, "No PlayerController found")
            end

            -- Probe R5Character
            local chars = FindAllOf("R5Character")
            if chars then
                for i, char in ipairs(chars) do
                    if char:IsValid() then
                        table.insert(lines, "--- R5Character #" .. i .. " ---")
                        table.insert(lines, "FullName: " .. char:GetFullName())
                        local props = {"PlayerState", "Controller"}
                        for _, prop in ipairs(props) do
                            local ok, val = pcall(function() return char[prop] end)
                            if ok and val ~= nil then
                                table.insert(lines, "  " .. prop .. " = " .. tostring(val))
                            end
                        end
                    end
                end
            else
                table.insert(lines, "No R5Character found")
            end

            if #lines == 0 then return "No players connected" end
            return table.concat(lines, "\n")
        end
    }

    -- =========================================
    -- New Commands: Server Info
    -- =========================================

    Admin._commands["wp.config"] = {
        description = "Show current config values",
        usage = "wp.config",
        category = "server",
        examples = {"wp.config"},
        handler = function(args)
            local lines = {"WindrosePlus Config:"}
            table.insert(lines, "  Loot: " .. Admin._config.getLootMultiplier() .. "x")
            table.insert(lines, "  XP: " .. Admin._config.getXpMultiplier() .. "x")
            table.insert(lines, "  Stack Size: " .. Admin._config.getStackSizeMultiplier() .. "x")
            table.insert(lines, "  Craft Cost: " .. Admin._config.getCraftCostMultiplier() .. "x")
            table.insert(lines, "  Crop Speed: " .. Admin._config.getCropSpeedMultiplier() .. "x")
            table.insert(lines, "  Weight: " .. Admin._config.getWeightMultiplier() .. "x")
            table.insert(lines, "  RCON: " .. (Admin._config.isRconEnabled() and "enabled" or "disabled"))
            local mods = WindrosePlus._modules.Mods
            if mods then
                table.insert(lines, "  Mods: " .. (mods.getLoadedCount and mods.getLoadedCount() or 0))
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.multipliers"] = {
        description = "Show all gameplay multipliers",
        usage = "wp.multipliers",
        category = "server",
        examples = {"wp.multipliers"},
        handler = function(args)
            local lines = {"Multipliers:"}
            table.insert(lines, "  Loot: " .. Admin._config.getLootMultiplier() .. "x")
            table.insert(lines, "  XP: " .. Admin._config.getXpMultiplier() .. "x")
            table.insert(lines, "  Stack Size: " .. Admin._config.getStackSizeMultiplier() .. "x")
            table.insert(lines, "  Craft Cost: " .. Admin._config.getCraftCostMultiplier() .. "x")
            table.insert(lines, "  Crop Speed: " .. Admin._config.getCropSpeedMultiplier() .. "x")
            table.insert(lines, "  Weight: " .. Admin._config.getWeightMultiplier() .. "x")
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.uptime"] = {
        description = "Show server uptime",
        usage = "wp.uptime",
        category = "server",
        examples = {"wp.uptime"},
        handler = function(args)
            -- Uptime from Lua boot timestamp (no wmic to avoid CMD window flash)
            local diff = os.time() - Admin._bootTime
            local days = math.floor(diff / 86400)
            local hours = math.floor((diff % 86400) / 3600)
            local mins = math.floor((diff % 3600) / 60)
            if days > 0 then
                return string.format("Uptime: %dd %dh %dm", days, hours, mins)
            else
                return string.format("Uptime: %dh %dm", hours, mins)
            end
        end
    }

    -- =========================================
    -- New Commands: Player Info
    -- =========================================

    Admin._commands["wp.playerinfo"] = {
        description = "Show consolidated player info (health, position, status)",
        usage = "wp.playerinfo [player]",
        category = "players",
        playerArg = true,
        examples = {"wp.playerinfo", "wp.playerinfo HumanGenome"},
        handler = function(args)
            local players = Admin._findPlayersByName(args[1])
            if #players == 0 then return args[1] and ("Player '" .. args[1] .. "' not found") or "No players online" end
            local chars = FindAllOf("R5Character")
            local lines = {}
            for _, p in ipairs(players) do
                local info = {p.name .. ":"}
                if p.x then
                    table.insert(info, string.format("  Position: %.0f, %.0f, %.0f", p.x, p.y, p.z))
                end
                -- Find matching character for health
                if chars then
                    for _, char in ipairs(chars) do
                        if char:IsValid() then
                            local cn = nil
                            pcall(function() cn = char:GetFullName():match("([^%.]+)$") end)
                            if cn == p.name then
                                pcall(function()
                                    local hc = char.HealthComponent
                                    if hc and hc:IsValid() then
                                        table.insert(info, "  Health: " .. tostring(hc.CurrentHealth or "?") .. "/" .. tostring(hc.MaxHealth or "?"))
                                        local alive = hc.CurrentHealth and tonumber(tostring(hc.CurrentHealth)) > 0
                                        table.insert(info, "  Alive: " .. (alive and "Yes" or "No"))
                                    end
                                end)
                                break
                            end
                        end
                    end
                end
                -- Session time
                if Admin._playerJoinTimes and Admin._playerJoinTimes[p.name] then
                    local elapsed = os.time() - Admin._playerJoinTimes[p.name]
                    local hours = math.floor(elapsed / 3600)
                    local mins = math.floor((elapsed % 3600) / 60)
                    table.insert(info, "  Session: " .. hours .. "h " .. mins .. "m")
                end
                for _, l in ipairs(info) do table.insert(lines, l) end
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.playtime"] = {
        description = "Show how long a player has been online this session",
        usage = "wp.playtime [player]",
        category = "players",
        playerArg = true,
        examples = {"wp.playtime", "wp.playtime HumanGenome"},
        handler = function(args)
            if not Admin._playerJoinTimes then return "No session data available" end
            local players = Admin._findPlayersByName(args[1])
            if #players == 0 then return args[1] and ("Player '" .. args[1] .. "' not found") or "No players online" end
            local lines = {}
            for _, p in ipairs(players) do
                local joinTime = Admin._playerJoinTimes[p.name]
                if joinTime then
                    local elapsed = os.time() - joinTime
                    local hours = math.floor(elapsed / 3600)
                    local mins = math.floor((elapsed % 3600) / 60)
                    table.insert(lines, p.name .. ": " .. hours .. "h " .. mins .. "m")
                else
                    table.insert(lines, p.name .. ": unknown")
                end
            end
            return table.concat(lines, "\n")
        end
    }

    -- =========================================
    -- New Commands: World Monitoring
    -- =========================================

    Admin._commands["wp.creatures"] = {
        description = "Count spawned creatures by type",
        usage = "wp.creatures",
        category = "world",
        examples = {"wp.creatures"},
        handler = function(args)
            local pawns = FindAllOf("Pawn")
            if not pawns then return "No creatures found" end
            local counts = {}
            local total = 0
            for _, pawn in ipairs(pawns) do
                if pawn:IsValid() then
                    local fn = pawn:GetFullName()
                    if not fn:find("R5Character") and not fn:find("PlayerController") then
                        local name = "Unknown"
                        pcall(function()
                            name = fn:match("BP_[^_]+_([^_]+)") or fn:match("BP_([^_]+)") or "Mob"
                        end)
                        counts[name] = (counts[name] or 0) + 1
                        total = total + 1
                    end
                end
            end
            local sorted = {}
            for name, count in pairs(counts) do table.insert(sorted, {name = name, count = count}) end
            table.sort(sorted, function(a, b) return a.count > b.count end)
            local lines = {"Creatures (" .. total .. " total):"}
            for _, entry in ipairs(sorted) do
                table.insert(lines, "  " .. entry.name .. ": " .. entry.count)
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.entities"] = {
        description = "Count total entities by type (lag diagnosis)",
        usage = "wp.entities",
        category = "world",
        examples = {"wp.entities"},
        handler = function(args)
            local types = {"Pawn", "R5Character", "R5MineralNode", "PlayerController", "GameState"}
            local lines = {"Entity Counts:"}
            for _, t in ipairs(types) do
                local objs = FindAllOf(t)
                local count = 0
                if objs then
                    for _, o in ipairs(objs) do
                        if o:IsValid() then count = count + 1 end
                    end
                end
                if count > 0 then
                    table.insert(lines, "  " .. t .. ": " .. count)
                end
            end
            if #lines == 1 then table.insert(lines, "  No entities found") end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.weather"] = {
        description = "Read current weather and environmental values",
        usage = "wp.weather",
        category = "world",
        examples = {"wp.weather"},
        handler = function(args)
            local weatherProps = {"WindSpeed", "WaveHeight", "OceanCurrentSpeed",
                                  "TemperatureMultiplier", "WeatherState", "CurrentWeather",
                                  "WindDirection", "RainIntensity", "FogDensity"}
            local types = {"R5GameMode", "R5GameState", "GameState", "WorldSettings"}
            local lines = {}
            for _, t in ipairs(types) do
                local objs = FindAllOf(t)
                if objs then
                    for _, obj in ipairs(objs) do
                        if obj:IsValid() then
                            for _, p in ipairs(weatherProps) do
                                pcall(function()
                                    local v = obj[p]
                                    if v ~= nil then
                                        table.insert(lines, t .. "." .. p .. " = " .. tostring(v))
                                    end
                                end)
                            end
                        end
                    end
                end
            end
            return #lines > 0 and table.concat(lines, "\n") or "No weather data available"
        end
    }

    -- =========================================
    -- New Commands: Diagnostics
    -- =========================================

    Admin._commands["wp.memory"] = {
        description = "Show detailed memory usage",
        usage = "wp.memory",
        category = "diagnostics",
        examples = {"wp.memory"},
        handler = function(args)
            -- Memory metrics require wmic which flashes a CMD window on desktop
            -- Lua collectgarbage reports only Lua heap, not the full process
            local lines = {"Memory Usage:"}
            local luaKB = math.floor(collectgarbage("count"))
            table.insert(lines, "  Lua Heap: " .. luaKB .. " KB")
            table.insert(lines, "  Process memory: not available (use Task Manager or perfpoll)")
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.connections"] = {
        description = "Show network connection info",
        usage = "wp.connections",
        category = "diagnostics",
        examples = {"wp.connections"},
        handler = function(args)
            local lines = {"Connections:"}
            local pcs = FindAllOf("PlayerController")
            local connected = 0
            local zombies = 0
            if pcs then
                for _, pc in ipairs(pcs) do
                    if pc:IsValid() then
                        if Admin._isConnected(pc) then
                            connected = connected + 1
                        else
                            zombies = zombies + 1
                        end
                    end
                end
            end
            table.insert(lines, "  Active: " .. connected)
            if zombies > 0 then
                table.insert(lines, "  Zombie Controllers: " .. zombies)
            end
            table.insert(lines, "  Mode: " .. (WindrosePlus and WindrosePlus.state.mode or "unknown"))
            if WindrosePlus and WindrosePlus.state.lastPlayerSeen > 0 then
                local ago = os.time() - WindrosePlus.state.lastPlayerSeen
                if ago < 60 then
                    table.insert(lines, "  Last Player: " .. ago .. "s ago")
                else
                    table.insert(lines, "  Last Player: " .. math.floor(ago / 60) .. "m ago")
                end
            end
            return table.concat(lines, "\n")
        end
    }

    -- wp.givestats: queue a stat-point compensation for a player.
    -- Use case: when xp_multiplier was raised on a server with existing characters,
    -- the engine fires only one StatPointsReward per XP gain so players "skip"
    -- earned points across multiple levels. This command records a grant request
    -- to windrose_plus_data\stat_grants_queue.log for offline reconciliation.
    -- Issue: HumanGenome/WindrosePlus#4
    Admin._commands["wp.givestats"] = {
        description = "Queue stat/talent point grant for a player (Issue #4 compensation)",
        usage = "wp.givestats <player> <stat_count> [talent_count]",
        category = "players",
        examples = {"wp.givestats Alice 3", "wp.givestats Bob 5 2"},
        handler = function(args)
            if #args < 2 then return "Usage: wp.givestats <player> <stat_count> [talent_count]" end
            -- Player names can contain spaces. RCON tokenizes on whitespace,
            -- so reconstruct: walk from the right, peel off 1-2 trailing numbers
            -- as stat_count/[talent_count], everything before joins as the name.
            local n = #args
            local last = tonumber(args[n])
            local prev = n >= 3 and tonumber(args[n - 1]) or nil
            local target, statCount, talentCount
            if last and prev then
                statCount = prev
                talentCount = last
                target = table.concat(args, " ", 1, n - 2)
            elseif last then
                statCount = last
                talentCount = 0
                target = table.concat(args, " ", 1, n - 1)
            else
                return "Usage: wp.givestats <player> <stat_count> [talent_count]"
            end
            if target == "" then return "Player name required" end
            if not statCount or statCount < 1 or statCount > 100 then
                return "stat_count must be 1-100"
            end
            if talentCount < 0 or talentCount > 100 then
                return "talent_count must be 0-100"
            end

            local matched = Admin._findPlayersByName(target)
            local connected = #matched > 0

            local entry = {
                ts = os.time(),
                type = "stat_grant_request",
                player = target,
                stat_points = statCount,
                talent_points = talentCount,
                connected_at_request = connected
            }
            local ok, line = pcall(json.encode, entry)
            if not ok then return "Failed to encode grant request" end

            if not Admin._gameDir then return "Game directory not initialized" end
            local queuePath = Admin._gameDir .. "windrose_plus_data\\stat_grants_queue.log"
            local f = io.open(queuePath, "a")
            if not f then return "Failed to write grant queue at " .. queuePath end
            f:write(line .. "\n")
            f:close()

            local msg = "Queued: " .. target .. " +" .. statCount .. " stat"
            if talentCount > 0 then msg = msg .. " +" .. talentCount .. " talent" end
            if not connected then msg = msg .. " (player offline — applied on next reconciliation)" end
            return msg
        end
    }

end

-- Delegate to shared helper in WindrosePlus global
function Admin._isConnected(pc)
    return WindrosePlus._isConnected(pc)
end

-- Disk persistence for wp.godmode baselines. If the server crashes while a
-- player is in god mode, their saved HP may be 9999999; without the baseline
-- on disk we have no way to restore the real value. Cache is per-player name.
Admin._GODMODE_CACHE_FILE = "windrose_plus_data\\godmode_baselines.json"

function Admin._godmodeCachePath()
    if not Admin._gameDir then return nil end
    return Admin._gameDir .. Admin._GODMODE_CACHE_FILE
end

function Admin._saveGodmodeCache()
    local path = Admin._godmodeCachePath()
    if not path then return end
    local ok, encoded = pcall(json.encode, Admin._origHealth or {})
    if not ok then
        Log.warn("Admin", "Failed to encode godmode baselines: " .. tostring(encoded))
        return
    end
    local f = io.open(path, "w")
    if not f then
        Log.warn("Admin", "Failed to write godmode baseline cache: " .. path)
        return
    end
    f:write(encoded)
    f:close()
end

function Admin._loadGodmodeCache()
    Admin._origHealth = Admin._origHealth or {}
    local path = Admin._godmodeCachePath()
    if not path then return end
    local f = io.open(path, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return end
    local ok, decoded = pcall(json.decode, content)
    if not ok or type(decoded) ~= "table" then
        Log.warn("Admin", "Godmode baseline cache is corrupt, ignoring: " .. path)
        return
    end
    Admin._origHealth = decoded
    local names = {}
    for k in pairs(decoded) do table.insert(names, k) end
    if #names > 0 then
        Log.warn("Admin", "Stale godmode baselines loaded for: " .. table.concat(names, ", ")
            .. ". Run 'wp.godmode <player> off' when each is online to restore real HP.")
    end
end

-- ============================================================
-- Damage hook probe (Phase 1: discovery only, does NOT block damage)
-- ============================================================
-- Windrose uses GAS-style wrapped health attributes, so direct property
-- writes can't reliably modify HP. To build per-player godmode we need
-- to hook whichever UFunction carries the damage application, then in
-- a later phase short-circuit it when the victim is whitelisted.
--
-- Step 1 is figuring out WHICH function carries damage on this build.
-- We register candidate hooks at startup; each just increments a counter
-- and records a timestamp. The hook body is almost free when the probe
-- is disabled (just an early-return on the flag).
--
-- Operator flow:
--   wp.damage_probe on      -- start counting
--   <take damage in-game>
--   wp.damage_probe stats   -- see which hooks fired
--   wp.damage_probe off     -- stop counting
Admin._damageHookCounters = {}
Admin._damageHookLastFire = {}
Admin._damageHookEnabled = false
Admin._damageHooksRegistered = false

-- Candidate UFunction names. UE4SS logs a warning for any that don't
-- resolve but does not crash, so over-registering is fine.
Admin._DAMAGE_HOOK_CANDIDATES = {
    -- Stock UE Actor/Pawn/Character damage entry points
    "/Script/Engine.Actor:ReceiveAnyDamage",
    "/Script/Engine.Actor:ReceivePointDamage",
    "/Script/Engine.Actor:ReceiveRadialDamage",
    "/Script/Engine.Actor:TakeDamage",
    "/Script/Engine.Pawn:TakeDamage",
    "/Script/Engine.Character:TakeDamage",
    -- R5 character-level (confirmed package prefix: /Script/R5.)
    "/Script/R5.R5Character:TakeDamage",
    "/Script/R5.R5Character:ReceiveAnyDamage",
    "/Script/R5.R5Character:ReceivePointDamage",
    -- HealthComponent-level (we know char.HealthComponent exists)
    "/Script/R5.HealthComponent:TakeDamage",
    "/Script/R5.HealthComponent:ApplyDamage",
    "/Script/R5.HealthComponent:OnDamaged",
    "/Script/R5.R5HealthComponent:TakeDamage",
    "/Script/R5.R5HealthComponent:ApplyDamage",
    -- GAS layer (UE5 Gameplay Ability System)
    "/Script/GameplayAbilities.AbilitySystemComponent:ApplyGameplayEffectSpecToSelf",
    "/Script/GameplayAbilities.AbilitySystemComponent:ApplyGameplayEffectSpecToTarget",
}

function Admin._registerDamageHooks()
    if Admin._damageHooksRegistered then return end
    Admin._damageHooksRegistered = true
    for _, fname in ipairs(Admin._DAMAGE_HOOK_CANDIDATES) do
        -- pcall in case UE4SS raises on an unknown symbol format on this build
        pcall(function()
            RegisterHook(fname, function()
                if not Admin._damageHookEnabled then return end
                Admin._damageHookCounters[fname] = (Admin._damageHookCounters[fname] or 0) + 1
                Admin._damageHookLastFire[fname] = os.time()
            end)
        end)
    end
end

-- Helper: find players by name (case-insensitive exact match, or return all if no filter)
function Admin._findPlayersByName(targetName)
    local players = Admin._getPlayers()
    if not targetName then return players end
    local target = targetName:lower()
    local matched = {}
    for _, p in ipairs(players) do
        if p.name and p.name:lower() == target then
            table.insert(matched, p)
        end
    end
    return matched
end

-- Shared UE4 property names for discovery/inspection commands
Admin._UE4_PROPS = {
    -- Gameplay multipliers
    "XPMultiplier", "ExperienceMultiplier", "LootMultiplier", "HarvestMultiplier",
    "DamageMultiplier", "PlayerDamageMultiplier", "NPCDamageMultiplier",
    "StackSizeMultiplier", "CraftCostMultiplier", "CropGrowthMultiplier",
    "WeightMultiplier", "StructureDamageMultiplier", "ResourceAmountMultiplier",
    "ResourceRespawnMultiplier", "StaminaDrainMultiplier", "HungerDrainMultiplier",
    "ThirstDrainMultiplier", "HealthRegenMultiplier", "StaminaRegenMultiplier",
    "DurabilityMultiplier", "RepairCostMultiplier", "FuelConsumptionMultiplier",
    "SpeedMultiplier", "JumpMultiplier", "FallDamageMultiplier",
    -- Time/Day
    "TimeOfDay", "CurrentTimeOfDay", "DayCycleDuration", "NightCycleDuration",
    "DayNightCycleSpeed", "DayLength", "NightLength", "TimeDilation",
    "MatineeTimeDilation", "DemoPlayTimeDilation",
    -- Server settings
    "MaxPlayers", "ServerName", "ServerPassword", "NumPlayers", "NumBots",
    "bAllowPVP", "bAllowBuilding", "bAllowCheats", "bPauseable",
    "SpawnRate", "DifficultyLevel", "Difficulty",
    "DropOnDeath", "bDropOnDeath", "KeepInventoryOnDeath",
    "RespawnTimer", "RespawnCooldown",
    -- Physics
    "GlobalGravityZ", "GravityScale", "bGlobalGravitySet",
    "KillZ", "WorldGravityZ",
    -- Network
    "ServerTickRate", "NetServerMaxTickRate", "MaxTickRate",
    "bUseFixedFrameRate", "FixedFrameRate",
    "MinNetUpdateFrequency", "NetUpdateFrequency",
    -- Movement
    "MaxWalkSpeed", "MaxSwimSpeed", "MaxFlySpeed", "JumpZVelocity",
    "MaxAcceleration", "BrakingDecelerationWalking",
    "CheatMovementSpeedModifer", "bCanFly", "bCheatFlying",
    -- Health/Combat
    "MaxHealth", "CurrentHealth", "BaseHealth",
    "BaseDamage", "BaseArmor", "BaseResistance",
    -- Character
    "bCanBeDamaged", "bCanPickupItems", "bHidden",
    "bIsInvulnerable", "bInvincible",
    -- Game mode
    "bUseSeamlessTravel", "bStartPlayersAsSpectators",
    "bDelayedStart", "DefaultPlayerName", "bEnableWorldComposition",
    -- R5-specific
    "SailSpeed", "WindSpeed", "WaveHeight", "OceanCurrentSpeed",
    "CrewSize", "MaxCrewSize", "ShipHealth", "ShipMaxHealth",
    "CannonDamage", "CannonRange", "CannonReloadTime",
    "FishingMultiplier", "CookingSpeed", "SmeltingSpeed",
    "BuildingDamageMultiplier", "SiegeDamageMultiplier",
    "TamingSpeedMultiplier", "BreedingSpeedMultiplier",
    "FoodDrainMultiplier", "WaterDrainMultiplier",
    "OxygenDrainMultiplier", "TemperatureMultiplier",
    "NightVisionEnabled", "MapFogEnabled",
    -- General UE4
    "NetCullDistanceSquared", "NetPriority",
    "bAlwaysRelevant", "bReplicates", "NumSpectators",
    "GameSessionClass",
}

-- Helper: probe a UE4 object for properties and return found values
-- filter matches against both property name and value
function Admin._probeObject(obj, filter)
    local found = {}
    for _, prop in ipairs(Admin._UE4_PROPS) do
        pcall(function()
            local v = obj[prop]
            if v ~= nil then
                local display = tostring(v)
                pcall(function()
                    local s = v:ToString()
                    if s and s ~= "" then display = s end
                end)
                local num = tonumber(display)
                if num then display = tostring(num) end
                -- Skip raw UObject pointers
                if not display:match("^UObject:") and not display:match("^FString:") and not display:match("^FText:") then
                    if not filter or prop:lower():find(filter, 1, true) or display:lower():find(filter, 1, true) then
                        found[#found + 1] = { name = prop, value = display }
                    end
                end
            end
        end)
    end
    return found
end

-- Helper: find first valid instance of a UE4 type
function Admin._findFirstValid(typeName)
    local results = FindAllOf(typeName)
    if not results then return nil end
    for _, o in ipairs(results) do
        if o:IsValid() then return o end
    end
    return nil
end

-- Helper: get player list with positions
function Admin._getPlayers()
    local players = {}
    local chars = FindAllOf("R5Character")
    if not chars then return players end

    for _, char in ipairs(chars) do
        if char:IsValid() then
            local hasController = false
            pcall(function()
                local ctrl = char.Controller
                if ctrl and ctrl:IsValid() then hasController = true end
            end)

            if hasController then
                local player = { name = "Unknown" }

                pcall(function()
                    local fn = char:GetFullName()
                    player.name = fn:match("([^%.]+)$") or fn
                end)

                pcall(function()
                    local repMove = char.ReplicatedMovement
                    if repMove then
                        local loc = repMove.Location
                        if loc then
                            player.x = loc.X
                            player.y = loc.Y
                            player.z = loc.Z
                        end
                    end
                end)

                if not player.x then
                    pcall(function()
                        local root = char.RootComponent
                        if root and root:IsValid() then
                            local rel = root.RelativeLocation
                            if rel then
                                player.x = rel.X
                                player.y = rel.Y
                                player.z = rel.Z
                            end
                        end
                    end)
                end

                table.insert(players, player)
            end
        end
    end
    return players
end

return Admin
