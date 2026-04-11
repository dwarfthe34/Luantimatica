-- ghost_schematic CSM
-- Litematica-style schematic placer using ghost nodes (CSM-safe, no file IO)

local modname = minetest.get_current_modname()
local modpath = minetest.get_modpath(modname)

-- ────────────────────────────────────────────────────────────────────────────
-- State
-- ────────────────────────────────────────────────────────────────────────────

local state = {
	loaded         = nil,
	schematic_name = "",
	json_input     = "",

	ghosts         = {},   -- uid -> {pos, node_name}
	uid_counter    = 0,

	p1             = nil,
	p2             = nil,

	placed         = false,
	status         = "No schematic loaded.",
	verify_result  = nil,
	formspec_open  = false,
}

-- ────────────────────────────────────────────────────────────────────────────
-- Ghost node helpers
-- ────────────────────────────────────────────────────────────────────────────

local function new_uid()
	state.uid_counter = state.uid_counter + 1
	return state.uid_counter
end

local function add_ghost(pos, node_name)
	local uid = new_uid()
	state.ghosts[uid] = {pos = pos, node_name = node_name}
	minetest.set_ghost_node(pos, {name = node_name})
	return uid
end

local function clear_all_ghosts()
	for _, entry in pairs(state.ghosts) do
		minetest.remove_ghost_node(entry.pos)
	end
	state.ghosts = {}
	state.placed = false
	state.verify_result = nil
end

-- ────────────────────────────────────────────────────────────────────────────
-- Schematic I/O (CSM-safe: paste only)
-- ────────────────────────────────────────────────────────────────────────────

local function load_schematic_from_json(raw)
	if not raw or raw == "" then
		return nil, "Empty JSON input."
	end

	local data = minetest.parse_json(raw)
	if not data then return nil, "Invalid JSON." end
	if not data.blocks or #data.blocks == 0 then
		return nil, "Schematic has no blocks."
	end

	return data, nil
end

-- ────────────────────────────────────────────────────────────────────────────
-- Place / verify
-- ────────────────────────────────────────────────────────────────────────────

local function place_ghosts()
	if not state.loaded then return false, "No schematic loaded." end
	if not state.p1 then return false, "P1 not set." end

	clear_all_ghosts()

	local origin = state.p1
	for _, b in ipairs(state.loaded.blocks) do
		local pos = vector.new(origin.x + b.x, origin.y + b.y, origin.z + b.z)
		add_ghost(pos, b.name)
	end

	state.placed = true
	state.status = "Placed " .. #state.loaded.blocks .. " ghost nodes."
	return true
end

local function run_verify()
	if not state.loaded or not state.placed then
		return nil, "No ghosts placed."
	end

	local origin = state.p1
	local correct, missing, wrong, total = 0, 0, 0, #state.loaded.blocks

	for _, b in ipairs(state.loaded.blocks) do
		local pos = vector.new(origin.x + b.x, origin.y + b.y, origin.z + b.z)
		local node = minetest.get_node(pos)

		if node then
			if node.name == b.name then
				correct = correct + 1
			elseif node.name == "air" or node.name == "ignore" then
				missing = missing + 1
			else
				wrong = wrong + 1
			end
		else
			missing = missing + 1
		end
	end

	return {total = total, correct = correct, missing = missing, wrong = wrong}
end

-- ────────────────────────────────────────────────────────────────────────────
-- Utils
-- ────────────────────────────────────────────────────────────────────────────

local function fmt_pos(pos)
	if not pos then return "not set" end
	return string.format("(%d, %d, %d)", pos.x, pos.y, pos.z)
end

local function field_val(pos, axis)
	if not pos then return "" end
	return tostring(pos[axis])
end

local function read_pos(fields, prefix)
	local x = tonumber(fields[prefix .. "x"])
	local y = tonumber(fields[prefix .. "y"])
	local z = tonumber(fields[prefix .. "z"])
	if x and y and z then return vector.new(x, y, z) end
	return nil
end

local function esc(s)
	return minetest.formspec_escape(tostring(s))
end

local function ghost_count()
	local n = 0
	for _ in pairs(state.ghosts) do n = n + 1 end
	return n
end

-- ────────────────────────────────────────────────────────────────────────────
-- Formspec
-- ────────────────────────────────────────────────────────────────────────────

local function build_formspec()
	local W, H = 13, 10
	local vr = state.verify_result

	local verify_line = ""
	if vr then
		local pct = math.floor(vr.correct / math.max(vr.total, 1) * 100)
		verify_line = string.format(
			"%d%% done  |  %d/%d correct  |  %d missing  |  %d wrong",
			pct, vr.correct, vr.total, vr.missing, vr.wrong
		)
	end

	local loaded_name = state.loaded and (state.loaded.name or state.schematic_name) or "—"
	local block_count = state.loaded and #state.loaded.blocks or 0

	return table.concat({
		"formspec_version[4]",
		"size[" .. W .. "," .. H .. "]",
		"bgcolor[#0d1117;true]",

		"box[0,0;" .. W .. ",0.75;#161b22]",
		"label[0.25,0.38;▣ Ghost Schematic]",
		"button[" .. (W-1.1) .. ",0.1;0.95,0.55;close;✕]",

		"box[0.1,0.85;5.7,8.8;#161b22]",
		"box[0.1,0.85;5.7,0.45;#21262d]",
		"label[0.35,1.07;SCHEMATIC]",

		"label[0.35,1.55;Name]",
		"field[0.35,1.75;3.7,0.6;schematic_name;;" .. esc(state.schematic_name) .. "]",
		"button[4.15,1.72;1.45,0.63;load_json;Load]",

		-- JSON paste input
		"label[0.35,2.35;Paste JSON]",
		"textarea[0.35,2.55;5.2,2.6;json_input;;" .. esc(state.json_input) .. "]",

		"box[0.2,5.25;5.5,1.2;#0d1117]",
		"label[0.45,5.45;Loaded: " .. esc(loaded_name) .. "]",
		"label[0.45,5.75;Blocks: " .. block_count .. "]",
		"label[0.45,6.05;Ghosts: " .. ghost_count() .. "]",

		"button[0.25,6.4;5.4,0.7;place;Place Ghost Nodes]",
		"button[0.25,7.2;5.4,0.7;clear;Clear Ghost Nodes]",
		"button[0.25,8.0;5.4,0.7;verify;Verify]",

		"box[6,0.85;6.9,8.8;#161b22]",

		"label[6.25,1.1;P1]",
		"label[6.25,1.45;" .. esc(fmt_pos(state.p1)) .. "]",

		"field[6.25,1.9;1.5,0.6;p1x;;" .. field_val(state.p1,"x") .. "]",
		"field[8.0,1.9;1.5,0.6;p1y;;" .. field_val(state.p1,"y") .. "]",
		"field[9.75,1.9;1.5,0.6;p1z;;" .. field_val(state.p1,"z") .. "]",

		"button[6.25,2.6;3.2,0.6;p1_here;Set P1]",
		"button[9.55,2.6;3.2,0.6;p1_apply;Apply]",

		"label[6.25,3.4;P2]",
		"label[6.25,3.75;" .. esc(fmt_pos(state.p2)) .. "]",

		"field[6.25,4.2;1.5,0.6;p2x;;" .. field_val(state.p2,"x") .. "]",
		"field[8.0,4.2;1.5,0.6;p2y;;" .. field_val(state.p2,"y") .. "]",
		"field[9.75,4.2;1.5,0.6;p2z;;" .. field_val(state.p2,"z") .. "]",

		"button[6.25,4.9;3.2,0.6;p2_here;Set P2]",
		"button[9.55,4.9;3.2,0.6;p2_apply;Apply]",

		"label[6.25,5.7;STATUS]",
		"label[6.25,6.1;" .. esc(state.status) .. "]",

		"label[6.25,6.6;" .. esc(verify_line ~= "" and verify_line or "No verify") .. "]",
	}, "")
end

local function show_formspec()
	state.formspec_open = true
	minetest.show_formspec("ghost_schematic:main", build_formspec())
end

local function refresh()
	if state.formspec_open then show_formspec() end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Input
-- ────────────────────────────────────────────────────────────────────────────

minetest.register_on_formspec_input(function(formname, fields)
	if formname ~= "ghost_schematic:main" then return end

	if fields.quit or fields.close then
		state.formspec_open = false
		return
	end

	if fields.schematic_name ~= nil then
		state.schematic_name = fields.schematic_name
	end

	if fields.json_input ~= nil then
		state.json_input = fields.json_input
	end

	if fields.load_json then
		local data, err = load_schematic_from_json(state.json_input)
		if err then
			state.status = "Error: " .. err
		else
			state.loaded = data
			state.status = "Loaded JSON schematic (" .. #data.blocks .. " blocks)."
		end
	end

	if fields.p1_here then
		local p = minetest.localplayer
		if p then state.p1 = vector.round(p:get_pos()) end
	end

	if fields.p2_here then
		local p = minetest.localplayer
		if p then state.p2 = vector.round(p:get_pos()) end
	end

	if fields.p1_apply then
		local pos = read_pos(fields, "p1")
		if pos then state.p1 = pos end
	end

	if fields.p2_apply then
		local pos = read_pos(fields, "p2")
		if pos then state.p2 = pos end
	end

	if fields.place then
		local ok, err = place_ghosts()
		if not ok then state.status = "Error: " .. err end
	end

	if fields.clear then
		clear_all_ghosts()
		state.status = "Cleared."
	end

	if fields.verify then
		local result, err = run_verify()
		if result then
			state.verify_result = result
		else
			state.status = "Error: " .. err
		end
	end

	refresh()
end)

-- ────────────────────────────────────────────────────────────────────────────
-- Chat
-- ────────────────────────────────────────────────────────────────────────────

minetest.register_chatcommand("gs", {
	func = show_formspec
})
