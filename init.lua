--- Property based testing utility specific for testing in game.
--
-- @module check.lua

local gen = {}

function gen_error(msg)
    error({ gen_error = true, msg = msg }, 2)
end

function deferred()
    local self = {}

    local pending = 0
    local results = {}
    local done_cbs = {}
    local all_done_cbs = {}

    self.is_done = true

    local finished = false

    function self.call(fn)
        self.is_done = false

        pending = pending + 1
        local index = pending

        fn(function(value)
            if results[index] ~= nil then
                return
            end -- guard double done

            results[index] = value

            -- fire per-item callbacks
            for _, cb in ipairs(done_cbs) do
                cb(value, index)
            end

            pending = pending - 1

            if pending == 0 and not finished then
                finished = true
                for _, cb in ipairs(all_done_cbs) do
                    cb(results)
                end
            end
        end)
    end

    function self.done(cb)
        table.insert(done_cbs, cb)
    end

    function self.all_done(cb)
        if finished then
            cb(results)
            self.is_done = true
        else
            table.insert(all_done_cbs, cb)
        end
    end

    return self
end

function gen.pick_key(tbl)
    local keys = {}
    for k in pairs(tbl) do
        table.insert(keys, k)
    end
    if #keys == 0 then
        -- TODO: Might want to throw even harder to get out of that test.
        gen_error("Table is empty, cannot pick key")
    end
    return keys[math.random(#keys)]
end

function gen.node_name()
    return gen.pick_key(core.regregistered_nodes)
end

function gen.pos_near_player(radius, player)
    local p = (player or gen.player()):get_pos() -- may throw random_error
    return {
        x = p.x + random(-10, 10),
        y = math.max(0, p.y + random(-5, 5)),
        z = p.z + random(-10, 10),
    }
end

function gen.node_near_player(radius)
    local pos = gen.pos_near_player(radius)

    return node, pos
end

---
-- Returns a node that is loaded.
-- @function gen.world_node
--
-- @tparam table param
-- @tfield param.radius
function gen.world_node(param)
    local pos = gen.pos_near_player(param.radius, param.player)
    local node = core.get_node_or_nil(pos)

    if node == nil then
        gen_error("Not a loaded node.")
    end

    return node, pos
end

---
-- Gets the node regardless if it is loaded or not.
function gen.node_or_nil(minp, maxp)
    return core.get_node_or_nil(gen.pos(minp, maxp))
end

function gen.get_node_or_ignore(minp, maxp)
    return core.get_node(gen.pos(minp, maxp))
end

function gen.player()
    local players = core.get_connected_players()
    if #players == 0 then
        error("player: no connected players")
    end

    return players[math.random(#players)]
end

function gen.integer(from, till)
    return math.random(from, till)
end

function gen.itemstack()
    local name = gen.item_name()
    local count = gen.integer(1, 99)

    return ItemStack(name .. " " .. count)
end

--- pick
-- @function gen.pick
--
-- @tparam table list
--
-- @treturn any value
-- @treturn integer index
function gen.pick(table)
    local index = math.random(#table)

    return table[index], index
end

function gen.pick_value(table)
    --TODO
end

function gen.node_definition()
    return gen.pick(core.registered_node)
end

function gen.item_definition()
    return gen.pick_value(core.registered_items)
end

function gen.item_name()
    return gen.pick_key(core.registered_items)
end

function gen.vector(params)
    params = params or {}
    local minp = params.minp or vector.new(-100, -10, -100)
    local maxp = params.maxp or vector.new(100, 50, 100)

    return vector.new(math.random(minp.x, maxp.x), math.random(minp.y, maxp.y), math.random(minp.z, maxp.z))
end

--- when
-- @function gen.when
-- @tparam boolean bool
-- @raise When the predicate is not true the when fn throws.
function gen.where(bool)
    if bool == false then
        gen_error("Does not comply with when predicate")
    end
end

function make_t(done_cb)
    local t = {}

    function t.done(...)
        done_cb(...)
    end

    local emerge = deferred()

    function t.on_emerge(callback)
        local players = core.get_connected_players()
        if #players == 0 then
            callback()
            return
        end

        -- likely starting area in most maps
        local start_minp = vector.new(-50, 0, -50)
        local start_maxp = vector.new(50, 50, 50)

        for _, player in ipairs(players) do
            emerge.call(function(done)
                local pos = player:get_pos()
                assert(pos, "Player position must not be nil")

                -- create a larger box around the player
                local emerge_minp = vector.subtract(pos, vector.new(25, 10, 25))
                local emerge_maxp = vector.add(pos, vector.new(25, 20, 25))

                core.emerge_area(emerge_minp, emerge_maxp, function(_, _, remaining)
                    if remaining == 0 then
                        done()
                    end
                end)
            end)
        end

        emerge.all_done(function()
            callback()
        end)
    end

    return t
end

local function property(name, ...)
    local checkpoints = { ... }
    local args = {} -- results from previous checkpoint
    local i = 1
    local run_checkpoint

    local run_count = 0 -- resets on restart
    local total_runs = 0 -- never resets

    local restart_threshold = 1
    local fail_threshold = 1000

    print("[luanti_check] Running property:", name)

    local function run_next(...)
        run_count = 0
        args = { ... }
        i = i + 1

        local next_checkpoint = checkpoints[i]
        if next_checkpoint then
            run_checkpoint(next_checkpoint)
        else
            print("[luanti_check] Finished all checkpoints for property:", name)
        end
    end

    run_checkpoint = function(checkpoint)
        run_count = run_count + 1
        total_runs = total_runs + 1

        print("Counts", run_count, total_runs)

        if total_runs > fail_threshold then
            error("[luanti_check] Property '" .. name .. "' failed: too many total runs")
        elseif run_count > restart_threshold then
            print("[luanti_check] Restarting property after", run_count, "runs")
            run_count = 0
            i = 1
            args = {}
            run_checkpoint(checkpoints[i])
            return
        end

        print("[luanti_check] Running checkpoint", i, "for:", name, total_runs)
        local t = make_t(run_next)

        local ok, err = xpcall(function()
            checkpoint(t, unpack(args))
        end, debug.traceback)

        if not ok then
            if type(err) == "table" and err.gen_error then
                print("[luanti_check] Creating new generated values:", err.msg)
                run_checkpoint(checkpoint) -- retry
            else
                print("[luanti_check] Fatal error in test:", err)
                error(err)
            end
        end
    end

    -- start first checkpoint
    run_checkpoint(checkpoints[i])
end

function gen.player_pos(param)
    param = param or {}

    local player = gen.player(param)
    local pos = gen.pos(param)

    player:set_pos(pos)

    return player, pos
end

-- Alias for gen.vector
function gen.pos(param)
    param = param or {}
    local player_pos = (param.player or gen.player()):get_pos()
    local pos = vector.add(player_pos, gen.vector())

    -- figure this out
    pos.y = param.pos.y

    return pos
end

core.register_chatcommand("check", {
    params = "<modname>",
    description = "Check status of a mod and run check.lua if present",
    privs = { server = true },
    func = function(name, param)
        if param == "" then
            return false, "Usage: /check <modname>"
        end

        local modname = param
        local modpath = core.get_modpath(modname)
        if not modpath then
            return false, "Mod '" .. modname .. "' is not loaded"
        end

        -- mod is loaded
        local check_file = modpath .. "/check.lua"
        local ok, err = pcall(dofile, check_file)
        if ok then
            return true, "Mod '" .. modname .. "' is loaded. check.lua executed successfully."
        else
            if string.find(err, "No such file or directory") then
                return true, "Mod '" .. modname .. "' is loaded. No check.lua found."
            else
                return false, "Error running check.lua: " .. tostring(err)
            end
        end
    end,
})

local function ok(v)
    if v == false then
        error("not true!")
    end
end

function luanti_check()
    print("CALLED")
    return property, gen
end

return luanti_check
