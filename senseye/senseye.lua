-- Copyright 2014-2015, Björn Ståhl
-- License: 3-Clause BSD
-- Reference: http://senseye.arcan-fe.com
-- Description:
--  Main entry-points for the 'senseye' arcan application.
--  It passively listens on an external connection key (senseye)
--  for data 'senses' that connect through the senseye ARCAN_CONNPATH
--  and provides UI mappings and type- specific graphical
--  representations for data that these senses deliver.
--
connection_path = "senseye";
wndcnt = 0;
pending_lim = 4;

--
-- global, used in all menus and messages
--
menu_text_fontstr = "\\fdefault.ttf,16\\#cccccc ";

--
-- customized dispatch handlers based on registered sensor type
-- populated by scanning senses/[name].lua
--
type_handlers = {};

translators = {};
data_meta_popup = {
	{
		label = "Activate Translator...",
		submenu = function()
			return #translator_popup > 0 and translator_popup or {
				{
				label = "No Translators Connected",
				handler = function() end
				}
			};
		end
	}
};

function senseye()
	system_load("mouse.lua")();
	symtable = system_load("symtable.lua")();
	system_load("keybindings.lua")();
	system_load("stringext.lua")();
	system_load("composition_surface.lua")();
	system_load("popup_menu.lua")();
	system_load("gconf.lua")();
	system_load("wndshared.lua")();
	system_load("shaders.lua")();
	system_load("translators.lua")();
--
-- load sense- specific user interfaces (name matches the
-- identification string that the connected frameserver sensor
-- segment provides, it does not define any additional trust barriers,
-- only user interface semantics.
--
	local res = glob_resource("senses/*.lua", APPL_RESOURCE);
	if (res) then
		for i,v in ipairs(res) do
			base, ext = string.extension(v);
			if (ext ~= nil and ext == "lua") then
				local tbl = system_load("senses/" .. v, 0);
				if (tbl ~= nil) then
					tbl = tbl();
				else
					warning("could not load sensor handler ( " ..
						v .. " ), parsing errors likely.");
				end

				if (tbl ~= nil) then
					type_handlers[base] = tbl;
				end
			end
		end
	end

-- uncomment for non-native cursor (would be visible in video recording)
--	show_image(cursimg);
--  mouse_setup(cursimg, 1000, 1, true);

	cursimg = load_image("cursor.png", 0, 10, 16);
	mouse_setup_native(cursimg);
--
-- create a window manager for the composition surface
--
	wm = compsurf_create(VRESW, VRESH, {});
	table.insert(wm.handlers.select, focus_window);
	table.insert(wm.handlers.deselect, defocus_window);
	table.insert(wm.handlers.destroy, check_listeners);

	local bgimg = load_image("background.png");
	image_tracetag(bgimg, "background");
	wm:set_background(bgimg);

	switch_default_texfilter(FILTER_NONE); -- barely anything should be filtered

--
-- map bindings to default UI actions (wndshared.lua + keybindings.lua)
--
	setup_dispatch(wm.dispatch);

	local lp = target_alloc(connection_path, new_connection);
	if (not valid_vid(lp)) then
		return
			shutdown("couldn't allocate connection_path (" .. connection_path ")");
	end
	image_tracetag(lp, connection_path .. "conn_" .. tonumber(wndcnt));
end

function add_window(source)
	local wnd = wm:add_window(source, {});
	window_shared(wnd);
	wnd.fullscreen_disabled = true;
	wnd.ctrl_id = source;
	wnd.source_listener = {};
	wnd.popup = controlwnd_menu;
	return wnd;
end

local function add_subwindow(parent, id)
	local wnd = wm:add_window(id, {});
	window_shared(wnd);
	wnd.ctrl_id = id;
	wnd.pending = 0;
	wnd.source_listener = {};
	wnd.highlight = shader_update_range;
	wnd:set_parent(parent, ANCHOR_UR);
	nudge_image(wnd.anchor, 2, 0);
	image_shader(wnd.canvas, shaders_2dview[1].shid);
	wnd.popup_meta = data_meta_popup;
	wnd.shader_group = shaders_2dview;
	wnd.shind = 1;
	target_flags(id, TARGET_VSTORE_SYNCH);
	return wnd;
end

--
-- safeguard against pileups, the stepframe_target can have a steep
-- cost for each sensor and when events accumulate it might block
-- more important ones (switching clocking modes etc.) so make these
-- requests synchronous with delivery.
--
local defstep = stepframe_target;
function stepframe_target(src, id)
	local wnd = wm:find(src);
	if (wnd == nil) then
		return defstep(src, id);
	end

	if (wnd.pending == nil) then
		defstep(src, id);
		return;
	elseif (wnd.pending < pending_lim) then
		defstep(src, id);
		wnd.pending = wnd.pending + 1;
	end
end

--
-- just hooked for now, using this as a means for having
-- UI notifications of future errors.
--
function error_message(note)
	warning(note);
end

local function def_sourceh(wnd, source, status)
	if (wnd.handler_tbl[status.kind]) then
		wnd.handler_tbl[status.kind](wnd, source, status);
	end
end

--
-- switch a window to expose one set of UI functions in
-- favor of another. Only really performed when a segment
-- sends an identity update.
--
function convert_type(wnd, th, basemenu)
	if (th == nil) then
		return;
	end

	local tbl = th.dispatch_sub;
	for k,v in pairs(tbl) do
		wnd.dispatch[k] = v;
	end

	wnd.popup = merge_menu(basemenu, th.popup_sub);
	wnd.basename = th.name;
	wnd.name = wnd.name .. "_" .. th.name;
	wnd.map = th.map;

	if (th.source_listener) then
		wnd.source_handler = def_sourceh;
		wnd.handler_tbl = th.source_listener;
		table.insert(wnd.source_listener, wnd);
	end

	th.init(wnd);

	if (wm.selected == wnd) then
		focus_window(wnd);
	else
		defocus_window(wnd);
	end
end

--
-- this is the minimized default subwindow handle, it works
-- as such until the point where we receive an ident message
-- with the suggested UI type.
--
function subid_handle(source, status)
	local wnd = wm:find(source);

	if (wnd.pending > 0 and status.kind == "framestatus") then
		wnd.pending = wnd.pending - 1;
	end

	if (status.kind == "resized") then
		wnd:resize(status.width, status.height);

	elseif (status.kind == "ident") then
		convert_type(wnd, type_handlers[status.message], subwnd_menu);
	else
	end

	for i,v in ipairs(wnd.source_listener) do
		v:source_handler(source, status);
	end
end

--
-- Default handle for the control- segment (main window)
-- to the sensor, other data components will be provided
-- as subsegments.
--
function default_wh(source, status)
	local wnd = wm:find(source);

	if (status.kind == "resized" and wnd ~= nil) then
		wnd:resize(status.width, status.height);
--
-- currently permitting infinite subsegments
-- (allocated from main one) in more sensitive settings,
-- this may be a bad idea (malicious process just spamming
-- requests) if that is a concern, rate-limit and kill.
--
	elseif (status.kind == "segment_request") then
		local id = accept_target();
		target_verbose(id);
		local subwnd = add_subwindow(wnd, id);
		subwnd.ctrl_id = id;
		local prop = image_surface_properties(id);
		subwnd:resize(status.width, status.height);
		subwnd:select();
		target_updatehandler(id, subid_handle);

	elseif (status.kind == "ident") then
		convert_type(wnd, type_handlers[status.message], {});
	end

	for k,v in ipairs(wnd.source_listener) do
		v:source_handler(source, status);
	end
end

--
-- note: translators are initially considered to be on
-- the same privilege level as the main senseye process,
-- it is only individual sessions that are deemed tainted.
-- Thus we assume that status.message is reasonable.
--
function translate_wh(source, status)
	if (status.kind == "ident") then
		if (translators[status.message] ~= nil) then
			warning("translator for that type already exists, terminating.");
			delete_image(source);
			return;
		else
			translators[status.message] = source;
			translators[source] = status.message;
			table.insert(translator_popup, {
				value = source,
				label = string.gsub(status.message, "\\", "\\\\") -- filter more?
			});
		end
	elseif (status.kind == "terminated") then
		for k,v in ipairs(translator_popup) do
			if (v.value == source) then
				table.remove(translator_popup, k);
				break;
			end
		end
		table.remove_vmatch(translators, source);
	end
end

--
-- there might be incentive to only permit windows that
-- registers with the correct subid to remain alive, and
-- have a timeout (i.e. mouse_tick on pending connections)
-- but >currently< we expect the sensor to cooperate.
--
function new_connection(source, status)
-- need to distinguish between a translator (data interpreter)
-- and a sensor (data provider) as they have different usr-int schemes
	if (status.kind ~= "registered") then
		delete_image(source);
		warning("connection attempted from uncooperative client." .. status.kind);

	else
		if (status.segkind == "sensor") then
			target_updatehandler(source, default_wh);
			local wnd = add_window(source);
			wnd:select();
			default_wh(source, status);

		elseif (status.segkind == "encoder") then
			target_updatehandler(source, translate_wh);

		else
			warning("attempted connection from unsupported type, " .. status.segkind);
			delete_image(source);
		end
	end

	local vid = target_alloc(connection_path, new_connection);

	if (not valid_vid(vid)) then
		warning("connection limit reached, non-auth connections disabled.");
		return;
	end

	wndcnt = wndcnt + 1;
	image_tracetag(vid, connection_path .. "conn_" .. tonumber(wndcnt));
end

function senseye_clock_pulse()
	mouse_tick(1);
	wm:tick(1);
end

function senseye_shutdown()
	gconfig_shutdown();
end

--
-- the mid-c flip-flop buffer is a common workaround for the issue of
-- mouse devices reporting data on multiple axis (design flaw that
-- won't really be fixed), so we wait for two events and forward
-- when we have a tuple.
--
mid_c = 0;
mid_v = {0, 0};
function senseye_input(iotbl)
	if (iotbl.source == "mouse") then
		if (iotbl.kind == "digital") then
			mouse_button_input(iotbl.subid, iotbl.active);
		else
			mid_v[iotbl.subid+1] = iotbl.samples[1];
			mid_c = mid_c + 1;

			if (mid_c == 2) then
				mouse_absinput(mid_v[1], mid_v[2]);
				mid_c = 0;
			end
		end

	elseif (iotbl.translated) then
		local sym = symtable[ iotbl.keysym ];

-- propagate meta-key state (for resize / drag / etc.)
		if (sym == BINDINGS["META"]) then
			wm.meta = iotbl.active and true or nil;
		end

-- wm input takes care of other management as well, i.e.
-- data routing, locking etc. so just forward
		if (iotbl.active) then
			wm:input_sym(sym);
		end

	else
		wm:input(iotbl);
	end
end
