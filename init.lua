-- ghost_schematic CSM
local modname = minetest.get_current_modname()

-- CSM node-read shim: servers may restrict or rename this
local csm_get_node = minetest.get_node
	or minetest.get_node_or_nil
	or false

local function safe_get_node(pos)
	if not csm_get_node then return nil end
	local ok, node = pcall(csm_get_node, pos)
	if ok and node then return node end
	return nil
end

local state = {
	loaded         = nil,
	schematic_name = "",
	json_input     = "",
	export_text    = "",
	ghosts         = {},
	uid_counter    = 0,
	p1             = nil,
	p2             = nil,
	placed         = false,
	status         = "No schematic loaded.",
	verify_result  = nil,
	formspec_open  = false,
	captured       = nil,
}

-- Ghost node helpers

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
	state.ghosts        = {}
	state.placed        = false
	state.verify_result = nil
end

-- Mapblock helpers

local MAPBLOCK = 16

local function pos_to_mapblock(pos)
	return vector.new(
		math.floor(pos.x / MAPBLOCK),
		math.floor(pos.y / MAPBLOCK),
		math.floor(pos.z / MAPBLOCK)
	)
end

local function mapblock_origin(mb)
	return vector.new(mb.x * MAPBLOCK, mb.y * MAPBLOCK, mb.z * MAPBLOCK)
end

local function mapblock_key(mb)
	return mb.x .. "," .. mb.y .. "," .. mb.z
end

local function get_mapblock_list(p1, p2)
	local mn = vector.new(math.min(p1.x,p2.x), math.min(p1.y,p2.y), math.min(p1.z,p2.z))
	local mx = vector.new(math.max(p1.x,p2.x), math.max(p1.y,p2.y), math.max(p1.z,p2.z))
	local mb_min = pos_to_mapblock(mn)
	local mb_max = pos_to_mapblock(mx)
	local list = {}
	for bx = mb_min.x, mb_max.x do
		for by = mb_min.y, mb_max.y do
			for bz = mb_min.z, mb_max.z do
				list[#list+1] = vector.new(bx, by, bz)
			end
		end
	end
	return list
end

-- Capture

local function capture_region()
	if not csm_get_node then
		return nil, "Server has blocked CSM node reading (csm_restriction_flags). Cannot capture."
	end
	if not state.p1 or not state.p2 then
		return nil, "P1 and P2 must be set."
	end

	local mn = vector.new(
		math.min(state.p1.x, state.p2.x),
		math.min(state.p1.y, state.p2.y),
		math.min(state.p1.z, state.p2.z))
	local mx = vector.new(
		math.max(state.p1.x, state.p2.x),
		math.max(state.p1.y, state.p2.y),
		math.max(state.p1.z, state.p2.z))

	local blocks  = {}
	local mb_set  = {}
	local ignored = 0

	local mb_list = get_mapblock_list(mn, mx)
	for _, mb in ipairs(mb_list) do
		local key    = mapblock_key(mb)
		local origin = mapblock_origin(mb)
		mb_set[key]  = {
			mapblock = {x = mb.x, y = mb.y, z = mb.z},
			origin   = {x = origin.x, y = origin.y, z = origin.z},
			nodes    = {},
		}
	end

	for x = mn.x, mx.x do
		for y = mn.y, mx.y do
			for z = mn.z, mx.z do
				local pos  = vector.new(x, y, z)
				local node = safe_get_node(pos)

				if not node or node.name == "ignore" then
					ignored = ignored + 1
				else
					local rel = {
						x      = x - mn.x,
						y      = y - mn.y,
						z      = z - mn.z,
						name   = node.name,
						param1 = node.param1 or 0,
						param2 = node.param2 or 0,
					}

					if node.name ~= "air" then
						blocks[#blocks+1] = rel
					end

					local mb  = pos_to_mapblock(pos)
					local key = mapblock_key(mb)
					if mb_set[key] then
						local lx = x - mb_set[key].origin.x
						local ly = y - mb_set[key].origin.y
						local lz = z - mb_set[key].origin.z
						mb_set[key].nodes[#mb_set[key].nodes+1] = {
							lx     = lx, ly = ly, lz = lz,
							name   = node.name,
							param1 = node.param1 or 0,
							param2 = node.param2 or 0,
						}
					end
				end
			end
		end
	end

	local mapblocks = {}
	for _, v in pairs(mb_set) do
		mapblocks[#mapblocks+1] = v
	end

	local captured = {
		name      = state.schematic_name,
		origin    = {x = mn.x, y = mn.y, z = mn.z},
		size      = {x = mx.x-mn.x+1, y = mx.y-mn.y+1, z = mx.z-mn.z+1},
		blocks    = blocks,
		mapblocks = mapblocks,
		ignored   = ignored,
	}

	state.captured = captured
	return captured, nil
end

-- Schematic I/O

local function load_schematic_from_json(raw)
	if not raw or raw == "" then return nil, "Empty JSON input." end
	local data = minetest.parse_json(raw)
	if not data then return nil, "Invalid JSON." end
	if not data.blocks or #data.blocks == 0 then return nil, "Schematic has no blocks." end
	return data, nil
end

local function export_captured()
	local c = state.captured
	if not c then return "Nothing captured. Use 'Capture Region' first." end

	local parts = {}
	parts[#parts+1] = '{"name":' .. minetest.write_json(c.name)
	parts[#parts+1] = ',"origin":{"x":' .. c.origin.x .. ',"y":' .. c.origin.y .. ',"z":' .. c.origin.z .. '}'
	parts[#parts+1] = ',"size":{"x":' .. c.size.x .. ',"y":' .. c.size.y .. ',"z":' .. c.size.z .. '}'
	parts[#parts+1] = ',"ignored":' .. c.ignored

	local bparts = {}
	for _, b in ipairs(c.blocks) do
		bparts[#bparts+1] = string.format(
			'{"x":%d,"y":%d,"z":%d,"name":%s,"p1":%d,"p2":%d}',
			b.x, b.y, b.z, minetest.write_json(b.name), b.param1, b.param2)
	end
	parts[#parts+1] = ',"blocks":[' .. table.concat(bparts, ",") .. "]"

	local mbparts = {}
	for _, mb in ipairs(c.mapblocks) do
		local nparts = {}
		for _, n in ipairs(mb.nodes) do
			if n.name ~= "air" then
				nparts[#nparts+1] = string.format(
					'{"lx":%d,"ly":%d,"lz":%d,"name":%s,"p1":%d,"p2":%d}',
					n.lx, n.ly, n.lz, minetest.write_json(n.name), n.param1, n.param2)
			end
		end
		mbparts[#mbparts+1] = string.format(
			'{"mb":{"x":%d,"y":%d,"z":%d},"origin":{"x":%d,"y":%d,"z":%d},"nodes":[%s]}',
			mb.mapblock.x, mb.mapblock.y, mb.mapblock.z,
			mb.origin.x, mb.origin.y, mb.origin.z,
			table.concat(nparts, ","))
	end
	parts[#parts+1] = ',"mapblocks":[' .. table.concat(mbparts, ",") .. "]}"

	return table.concat(parts)
end

local function export_schematic()
	if state.captured then return export_captured() end
	if not state.loaded then return "Nothing loaded." end
	local lines = {'{"name":' .. minetest.write_json(state.schematic_name or "") .. ',"blocks":['}
	local blocks = state.loaded.blocks
	for i, b in ipairs(blocks) do
		local comma = i < #blocks and "," or ""
		lines[#lines+1] = string.format(
			'{"x":%d,"y":%d,"z":%d,"name":%s}%s',
			b.x, b.y, b.z, minetest.write_json(b.name), comma)
	end
	lines[#lines+1] = "]}"
	return table.concat(lines, "\n")
end

-- Place / verify

local function place_ghosts()
	if not state.loaded then return false, "No schematic loaded." end
	if not state.p1     then return false, "P1 not set." end
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
	if not state.loaded or not state.placed then return nil, "No ghosts placed." end
	if not csm_get_node then return nil, "Server has blocked CSM node reading." end
	local origin = state.p1
	local correct, missing, wrong, total = 0, 0, 0, #state.loaded.blocks
	for _, b in ipairs(state.loaded.blocks) do
		local pos  = vector.new(origin.x + b.x, origin.y + b.y, origin.z + b.z)
		local node = safe_get_node(pos)
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

-- Utils

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

local function esc(s) return minetest.formspec_escape(tostring(s)) end

local function ghost_count()
	local n = 0
	for _ in pairs(state.ghosts) do n = n + 1 end
	return n
end

local function capture_status()
	if not csm_get_node      then return "Node reading blocked by server" end
	if not state.captured    then return "Not captured" end
	local c = state.captured
	return string.format("Captured %d blocks | %d mapblocks | %d ignored",
		#c.blocks, #c.mapblocks, c.ignored)
end

-- Formspec

local function build_formspec()
	local W, H = 13, 12
	local vr   = state.verify_result

	local verify_line = ""
	if vr then
		local pct = math.floor(vr.correct / math.max(vr.total, 1) * 100)
		verify_line = string.format(
			"%d%% done  |  %d/%d correct  |  %d missing  |  %d wrong",
			pct, vr.correct, vr.total, vr.missing, vr.wrong)
	end

	local loaded_name = state.loaded and (state.loaded.name or state.schematic_name) or "—"
	local block_count = state.loaded and #state.loaded.blocks or 0

	local mb_summary = ""
	if state.captured and #state.captured.mapblocks > 0 then
		local mbs   = state.captured.mapblocks
		local parts = {}
		for i = 1, math.min(3, #mbs) do
			local mb = mbs[i].mapblock
			parts[#parts+1] = string.format("MB(%d,%d,%d):%dn", mb.x, mb.y, mb.z, #mbs[i].nodes)
		end
		if #mbs > 3 then parts[#parts+1] = "+" .. (#mbs-3) .. " more" end
		mb_summary = table.concat(parts, "  ")
	end

	local mb_rows = ""
	if state.p1 and state.p2 then
		local mbs   = get_mapblock_list(state.p1, state.p2)
		local lines = {}
		for i = 1, math.min(5, #mbs) do
			local mb = mbs[i]
			lines[#lines+1] = string.format(
				"label[6.25,%.2f;MB (%d,%d,%d) → origin (%d,%d,%d)]",
				5.7 + i * 0.4,
				mb.x, mb.y, mb.z,
				mb.x * MAPBLOCK, mb.y * MAPBLOCK, mb.z * MAPBLOCK)
		end
		if #mbs > 5 then
			lines[#lines+1] = string.format(
				"label[6.25,%.2f;... +%d more mapblocks]",
				5.7 + 6 * 0.4, #mbs - 5)
		end
		mb_rows = table.concat(lines)
	else
		mb_rows = "label[6.25,6.1;—]"
	end

	return table.concat({
		"formspec_version[4]",
		"size[" .. W .. "," .. H .. "]",
		"bgcolor[#0d1117;true]",

		"box[0,0;" .. W .. ",0.75;#161b22]",
		"label[0.25,0.38;▣ Ghost Schematic]",
		"button[" .. (W-1.1) .. ",0.1;0.95,0.55;close;✕]",

		-- Left panel
		"box[0.1,0.85;5.7,10.8;#161b22]",

		"field[0.35,1.4;3.7,0.6;schematic_name;;" .. esc(state.schematic_name) .. "]",
		"button[4.15,1.35;1.45,0.63;load_json;Load]",

		"textarea[0.35,2.1;5.2,2.2;json_input;;" .. esc(state.json_input) .. "]",

		"button[0.35,4.4;5.2,0.7;place;Place Ghost Nodes]",
		"button[0.35,5.2;5.2,0.7;clear;Clear Ghost Nodes]",
		"button[0.35,6.0;5.2,0.7;verify;Verify]",
		"button[0.35,6.8;5.2,0.7;capture;Capture Region (P1→P2)]",
		"button[0.35,7.6;5.2,0.7;export;Export]",

		"label[0.35,8.6;" .. esc(capture_status()) .. "]",
		"label[0.35,9.0;" .. esc(mb_summary) .. "]",

		"textarea[0.35,9.4;5.2,2.0;export_box;;" .. esc(state.export_text) .. "]",

		-- Right panel
		"box[6,0.85;6.9,10.8;#161b22]",

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

		"label[6.25,5.7;MAPBLOCKS IN SELECTION]",
		mb_rows,

		"label[6.25,9.0;STATUS]",
		"label[6.25,9.4;" .. esc(state.status) .. "]",
		"label[6.25,9.8;" .. esc(verify_line ~= "" and verify_line or "No verify") .. "]",

		"label[6.25,10.3;Loaded: " .. esc(loaded_name) .. "]",
		"label[6.25,10.7;Blocks: " .. block_count .. "  Ghosts: " .. ghost_count() .. "]",
	}, "")
end

local function show_formspec()
	state.formspec_open = true
	minetest.show_formspec("ghost_schematic:main", build_formspec())
end

local function refresh()
	if state.formspec_open then show_formspec() end
end

-- Input

minetest.register_on_formspec_input(function(formname, fields)
	if formname ~= "ghost_schematic:main" then return end

	if fields.quit or fields.close then
		state.formspec_open = false
		return
	end

	if fields.schematic_name then state.schematic_name = fields.schematic_name end
	if fields.json_input     then state.json_input     = fields.json_input     end

	if fields.load_json then
		local data, err = load_schematic_from_json(state.json_input)
		if err then
			state.status = err
		else
			state.loaded   = data
			state.captured = nil
			state.status   = "Loaded schematic."
		end
	end

	if fields.capture then
		local c, err = capture_region()
		if err then
			state.status = "Capture failed: " .. err
		else
			state.status = string.format(
				"Captured: %d blocks across %d mapblocks (%d ignored)",
				#c.blocks, #c.mapblocks, c.ignored)
		end
	end

	if fields.export then
		state.export_text = export_schematic()
	end

	if fields.place then place_ghosts()     end
	if fields.clear then clear_all_ghosts() end

	if fields.verify then
		local vr, err = run_verify()
		if err then
			state.status = err
		else
			state.verify_result = vr
		end
	end

	if fields.p1_here then
		local p = minetest.localplayer
		if p then state.p1 = vector.round(p:get_pos()); state.captured = nil end
	end
	if fields.p2_here then
		local p = minetest.localplayer
		if p then state.p2 = vector.round(p:get_pos()); state.captured = nil end
	end
	if fields.p1_apply then state.p1 = read_pos(fields, "p1"); state.captured = nil end
	if fields.p2_apply then state.p2 = read_pos(fields, "p2"); state.captured = nil end

	refresh()
end)

-- Chat commands

minetest.register_chatcommand("gs", {
	func = function()
		show_formspec()
		return true, "Opened Ghost Schematic"
	end
})

minetest.register_chatcommand("gs_capture", {
	func = function()
		local c, err = capture_region()
		if err then return false, "Capture failed: " .. err end
		return true, string.format("Captured %d blocks across %d mapblocks (%d ignored)",
			#c.blocks, #c.mapblocks, c.ignored)
	end
})

minetest.register_chatcommand("gs_p1", {
	func = function()
		local p = minetest.localplayer
		if not p then return false, "No local player" end
		state.p1       = vector.round(p:get_pos())
		state.captured = nil
		return true, "P1 set to " .. fmt_pos(state.p1)
	end
})

minetest.register_chatcommand("gs_p2", {
	func = function()
		local p = minetest.localplayer
		if not p then return false, "No local player" end
		state.p2       = vector.round(p:get_pos())
		state.captured = nil
		return true, "P2 set to " .. fmt_pos(state.p2)
	end
})
