import flag
import gg
import gx
import math
import os
import sokol.sapp
import time
import v.embed_file
import x.json2

const (
	c_background     = gx.hex(0x94A3B8FF)
	c_anim           = gx.hex(0xE2E8F0FF)
	c_cell_empty     = gx.hex(0x8A9AAFAA)
	c_cell_empty2    = gx.hex(0x728299AA)
	c_cell_unknown   = gx.hex(0x334155FF)
	c_cell_unknown2  = gx.hex(0x293548FF)
	c_cell_mine      = gx.hex(0x3073F1FF)
	c_cell_mine2     = gx.hex(0x2563EBFF)
	c_cell_revealed  = gx.hex(0x172033FF)
	c_cell_revealed2 = gx.hex(0x0F172AFF)

	default_window_width  = 1280
	default_window_height = 720

	horizontal_width = 40
	vertical_width   = int(math.sqrt((horizontal_width * 2) * (horizontal_width * 2) - horizontal_width * horizontal_width))

	log_timeout      = 2 * time.second

	background_noise = ($embed_file('assets/background_noise.png')).to_bytes()
	compaign_maps    = [
		mk_campaign_map('01-01', $embed_file('assets/campaign/map00-01.tmap', .zlib)),
		mk_campaign_map('01-02', $embed_file('assets/campaign/map00-02.tmap', .zlib)),
	]
	main_menu_map    = GameMap{'main', 'main_menu.tmap', false, ($embed_file('assets/main_menu.tmap', .zlib)).to_string()}
)

fn mk_campaign_map(name string, data embed_file.EmbedFileData) GameMap {
	filename := data.path.split('/').last()
	return GameMap{name, filename, false, data.to_string()}
}

struct GameMap {
	name          string
	filename      string
	is_custom_map bool
mut: // editor
	map_data string
}

struct MapData {
mut:
	cells  [][]Cell
	text   string
	groups []gx.Color

	remaining_mines int
	remaining_other int
	mistakes        int
}

struct TriangoliApp {
mut:
	gg        &gg.Context    = 0
	state TriangoliState = .menu

	current_map GameMap
	map_data    MapData

	background_noise gg.Image
	// last_frame time.Time
	cli_launch bool

	logs []Log

	savestate_slot       string = '1'
	savestate_completion []string
}

fn (mut app TriangoliApp) log(text string) {
	log := Log{text, time.now()}
	app.logs << log
	eprintln('[LOG] $text')
}

enum TriangoliState {
	menu
	ingame
	editor
}

struct Cell {
mut:
	typ         CellType
	is_revealed bool
	count       int
	group       int
	id          string
}

enum CellType {
	not_mine
	mine
	empty
}

struct Log {
	text string
	time time.Time
}

fn main() {
	$if macos {
		if os.getwd() == '/' {
			// if you're running the file as .app, the cwd will be /
			// so set it to something sensible, like the home directory or Documents
			if os.exists(os.join_path(os.home_dir(), 'Documents')) {
				os.chdir(os.join_path(os.home_dir(), 'Documents')) or {}
			} else {
				os.chdir(os.home_dir()) or {}
			}
		}
	}

	mut app := &TriangoliApp{}
	app.gg = gg.new_context(
		bg_color: c_background
		width: default_window_width
		height: default_window_height
		window_title: 'Triangoli'
		init_fn: init
		frame_fn: frame
		event_fn: event
		user_data: app
		enable_dragndrop: true
		max_dropped_files: 1
		max_dropped_file_path_length: 2048
	)

	$if !disable_cli ? {
		mut fp := flag.new_flag_parser(os.args)
		fp.application('triangoli')
		fp.version('v0.1.0')
		fp.limit_free_args(0, 0) ?
		fp.description('Triangoli game')
		fp.skip_executable()

		mapname := fp.string('map', `m`, '', 'instantly load map')
		editor := fp.bool('editor', `e`, false, 'open editor')
		fp.finalize() or {
			eprintln(err)
			println(fp.usage())
			exit(1)
		}
		if mapname != '' {
			app.state = .ingame
			data := os.read_file(mapname) or {
				if !editor {
					eprintln('failed to load map file: $err')
					exit(1)
				}
				'{"cells": []}'
			}
			app.current_map = GameMap{mapname, mapname, true, data}
			app.map_data = load_map(data)
			app.cli_launch = true
		}
		if editor {
			app.state = .editor
			if mapname == '' {
				app.current_map = GameMap{'Untitled', 'untitled.tmap', true, '{"cells": []}'}
			}
			expand_map(mut app.map_data, 30, 10)
			app.cli_launch = true
		}
	}

	if !app.cli_launch {
		load_savestate(mut app)
	}
	if app.state == .menu {
		load_main_menu_map(mut app)
	}

	app.gg.run()
}

fn init(mut app TriangoliApp) {
	app.background_noise = app.gg.create_image_from_byte_array(background_noise)
}

fn frame(mut app TriangoliApp) {
	app.gg.begin()
	alpha := 0x80 - byte(math.sin(f64(app.gg.frame) / 60) * 0x30)
	background_color := gx.hex(c_anim.rgba8() & 0xffffff00 + alpha)
	app.gg.draw_image_with_config(
		img: &app.background_noise,
		img_rect: gg.Rect{0, 0, default_window_width, default_window_height},
		part_rect: gg.Rect{0, 0, default_window_width, default_window_height},
		color: background_color
	)
	match app.state {
		.menu { draw_menu(mut app) }
		.ingame { draw_game(mut app) }
		.editor { draw_editor(mut app) }
	}
	for app.logs.len > 0 && time.now() - app.logs[0].time > log_timeout {
		app.logs.delete(0)
	}
	if app.logs.len > 0 {
		size := 8 * int(app.gg.scale)
		for i, log in app.logs {
			app.gg.draw_text(1, app.gg.height - 21 - size * i, log.text, size: size)
		}
	}
	app.gg.end()
}

fn event(mut ev gg.Event, mut app TriangoliApp) {
	if ev.typ == .resized {
		normalized_width := f64(ev.framebuffer_width) / default_window_width
		normalized_height := f64(ev.framebuffer_height) / default_window_height
		app.gg.scale = f32(math.min(normalized_width, normalized_height))
	}
	match app.state {
		.menu { event_menu(mut ev, mut app) }
		.ingame { event_game(mut ev, mut app) }
		.editor { event_editor(mut ev, mut app) }
	}
}

fn savestate_location() string {
	$if macos {
		// ~/Library/Application Support/triangoli
		return os.join_path(os.home_dir(), 'Library', 'Application Support', 'triangoli')
	}
	$else $if windows {
		// %APPDATA%\traingoli
		if os.getenv('APPDATA') != '' {
			return os.join_path(os.getenv('APPDATA'), 'triangoli')
		}
		// ~/.triangoli (fallback)
		return os.join_path(os.home_dir(), '.triangoli')
	}
	$else {
		// ~/.triangoli
		return os.join_path(os.home_dir(), '.triangoli')
	}
}

fn load_savestate(mut app TriangoliApp) {
	app.savestate_completion = []string{}
	loc := os.join_path(savestate_location(), 'slot_$app.savestate_slot')
	if !os.exists(loc) {
		return
	}
	raw_data := os.read_file(loc) or {
		app.log('failed to read savestate: $err')
		return
	}
	decoded_data := json2.raw_decode(raw_data) or { panic(err) }
	for value in decoded_data.arr() {
		app.savestate_completion << value.str()
	}
}

fn save_savestate(mut app TriangoliApp) {
	dir := savestate_location()
	loc := os.join_path(dir, 'slot_$app.savestate_slot')

	if !os.exists(dir) {
		os.mkdir_all(dir) or {
			app.log('failed to save savestate: $err')
			return
		}
	}
	mut data := []json2.Any{}
	for completed in app.savestate_completion {
		data << json2.Any(completed)
	}
	os.write_file(loc, data.str()) or {
		app.log('failed to save savestate: $err')
		return
	}
	app.log('progress saved')
}

fn load_map(raw_data string) MapData {
	mut md := MapData{}
	decoded_data := json2.raw_decode(raw_data) or { panic(err) }
	data := decoded_data.as_map()
	cells := (data['cells'] or { panic('missing cells in map data') }).arr()
	if 'text' in data {
		md.text = (data['text'] or { '' }).str()
	}
	for drow in cells {
		mut row := []Cell{}
		for dcol in drow.arr() {
			raw_cell := dcol.as_map()
			mut typ := CellType.empty
			if 'is_mine' in raw_cell {
				is_mine := (raw_cell['is_mine'] or { false }).bool()
				typ = if is_mine { CellType.mine } else { CellType.not_mine }
			}
			cell := Cell{
				typ: typ
				is_revealed: (raw_cell['is_revealed'] or { false }).bool()
				count: (raw_cell['count'] or { 0 }).int()
				group: (raw_cell['group'] or { -1 }).int()
				id: (raw_cell['id'] or { '' }).str()
			}
			row << cell
			if !cell.is_revealed && typ != .empty {
				if typ == .mine {
					md.remaining_mines++
				} else {
					md.remaining_other++
				}
			}
		}
		md.cells << row
	}
	if 'groups' in data {
		groups := (data['groups'] or { 0 }).arr()
		for color in groups {
			md.groups << gx.hex(color.int())
		}
	}
	return md
}

fn export_map(md MapData) string {
	mut cells := []json2.Any{}
	for row in md.cells {
		mut rowdata := []json2.Any{}
		for cell in row {
			mut celldata := map[string]json2.Any{}
			if cell.is_revealed && cell.typ != .empty {
				celldata['is_revealed'] = true
			}
			if cell.typ != .empty {
				celldata['is_mine'] = cell.typ == .mine
			}
			if cell.count != 0 && cell.typ == .not_mine {
				celldata['count'] = cell.count
			}
			if cell.group >= 0 {
				celldata['group'] = cell.group
			}
			if cell.id != '' {
				celldata['id'] = cell.id
			}
			rowdata << celldata
		}
		// "compression"
		for rowdata.len > 0 && rowdata.last().as_map().len == 0 {
			rowdata.pop()
		}
		cells << json2.Any(rowdata)
	}
	mut data := map[string]json2.Any{}
	data['cells'] = json2.Any(cells) // autofree bug
	if md.text != '' {
		data['text'] = json2.Any(md.text) // autofree bug
	}
	if md.groups.len > 0 {
		mut groups := []json2.Any{}
		for color in md.groups {
			groups << color.rgba8()
		}
		data['groups'] = json2.Any(groups)
	}
	return data.str()
}

fn expand_map(mut md MapData, width int, height int) {
	for mut row in md.cells {
		for row.len < width {
			cell := Cell{.empty, false, 0, -1, ''}
			row << cell
		}
	}
	for md.cells.len < height {
		mut row := []Cell{}
		for _ in 0 .. width {
			cell := Cell{.empty, false, 0, -1, ''}
			row << cell
		}
		md.cells << row
	}
}

fn load_main_menu_map(mut app TriangoliApp) {
	app.current_map = main_menu_map
	app.map_data = load_map(main_menu_map.map_data)
	// 'campaign/map01-01.tmap'
	map_ids := [
		'01-01', '04-01',
		'01-02', '01-03', '04-02', '04-03',
		'02-01', '07-01', '05-01',
		'02-02', '02-03', '05-02', '05-03',
		// none
		'03-01', '07-02', '07-03', '06-01',
		'03-02', '03-03', '06-02', '06-03'
	]!
	mut map_ids_idx := 0
	mut groups_done := [false, false, false, false, false, false, false]!
	for i in 1 .. (groups_done.len + 1) {
		for j in 1 .. 4 {
			if '0$i-$j' !in app.savestate_completion {
				break
			}
			if j == 3 {
				groups_done[i] = true
			}
		}
	}
	for i in 0 .. app.map_data.cells.len {
		for j in 0 .. app.map_data.cells[i].len {
			if app.map_data.cells[i][j].typ == .mine {
				app.map_data.cells[i][j].id = map_ids[map_ids_idx]
				if map_ids[map_ids_idx] in app.savestate_completion {
					app.map_data.cells[i][j].group = 0
				}
				group := map_ids[map_ids_idx].all_before('-').int()
				if group == 1 || groups_done[group - 2] {
					app.map_data.cells[i][j].is_revealed = true
				}
				map_ids_idx++
			}
		}
	}
}

fn draw_menu(mut app TriangoliApp) {
	draw_map(mut app)
}

fn event_menu(mut ev gg.Event, mut app TriangoliApp) {
	match ev.typ {
		.key_down {
			modifier := $if macos { gg.Modifier.super } $else { gg.Modifier.ctrl }
			if ev.key_code == .n && gg.Modifier(ev.modifiers) == modifier {
				data := '{"cells":[]}'
				app.current_map = GameMap{'Untitled', 'untitled.tmap', true, data}
				app.map_data = load_map(app.current_map.map_data)
				app.state = .ingame
				app.log('creating new map')
			}
			if ev.key_code == .e && gg.Modifier(ev.modifiers) == modifier {
				data := '{"cells":[]}'
				app.current_map = GameMap{'Untitled', 'untitled.tmap', true, data}
				app.map_data = load_map(app.current_map.map_data)
				expand_map(mut app.map_data, 30, 10)
				app.state = .editor
				app.log('opening new map in editor')
			}
			// TODO: add more
			if ev.modifiers == 0 {
				match ev.key_code {
					._1 {
						app.savestate_slot = '1'
					}
					._2 {
						app.savestate_slot = '2'
					}
					._3 {
						app.savestate_slot = '3'
					}
					.escape {
						app.gg.quit()
						return
					}
					else {
						return
					}
				}
				load_savestate(mut app)
				load_main_menu_map(mut app)
				app.log('loaded save state slot: $app.savestate_slot')
			}
			if ev.key_code == ._1 {
			}
			if ev.key_code == .escape {
			}
		}
		.files_droped {
			num_dropped := sapp.get_num_dropped_files()
			if num_dropped < 1 {
				return
			}
			filename := sapp.get_dropped_file_path(0)
			data := os.read_file(filename) or {
				app.log('failed to read file: $err')
				return
			}
			app.current_map = GameMap{'Drag and Drop', filename, true, data}
			app.map_data = load_map(app.current_map.map_data)
			app.state = .ingame
			app.log('opening map $filename')
		}
		.mouse_down {
			if ev.mouse_button != .left {
				return
			}
			cell, _, _ := pointing_at_cell(app) or {
				return
			}
			if cell.typ != .mine {
				return
			}
			if !cell.is_revealed {
				app.log('you have not unlocked this campaign map yet')
				return
			}
			for cmap in compaign_maps {
				if cmap.name == cell.id {
					app.current_map = cmap
					app.map_data = load_map(cmap.map_data)
					app.state = .ingame
					app.log('playing campaign $cmap.name')
					return
				}
			}
			app.log('unable to find campaign: $cell.id, maybe the map is not implemented yet?')
		}
		else {}
	}
}

fn draw_game(mut app TriangoliApp) {
	size := 8 * int(app.gg.scale)
	app.gg.draw_text(0, 0, 'Mistakes: $app.map_data.mistakes  Remaining: $app.map_data.remaining_mines', size: size)

	// diff := time.now() - app.last_frame
	// app.last_frame = time.now()
	// app.gg.draw_text_def(0, 10, "${1 / (f64(diff.nanoseconds()) / time.second)} fps")

	draw_map(mut app)

	if app.map_data.remaining_mines == 0 && app.map_data.remaining_other == 0 {
		text := 'You did it!'
		width, height := app.gg.text_size(text)
		app.gg.draw_rect((app.gg.width - width) / 2 - 10, (app.gg.height - height) / 2 - 5,
			width + 20, height + 10, gx.black)
		app.gg.draw_text((app.gg.width - width) / 2, (app.gg.height - height) / 2, text,
			color: gx.white)
	}

	if app.map_data.text != '' {
		app.gg.set_cfg(gx.TextCfg{ size: size * 2 })
		width := app.gg.text_width(app.map_data.text)
		app.gg.draw_text((int(app.gg.scale * app.gg.width / 2) - width) / 2, int(app.gg.scale * app.gg.height / 2) - size * 2 - 10, app.map_data.text,
			size: size * 2)
	}
}


fn event_game(mut ev gg.Event, mut app TriangoliApp) {
	match ev.typ {
		.key_down {
			modifier := $if macos { gg.Modifier.super } $else { gg.Modifier.ctrl }
			if ev.key_code == .r && gg.Modifier(ev.modifiers) == modifier {
				app.map_data = load_map(app.current_map.map_data)
			}
			if ev.key_code == .e && gg.Modifier(ev.modifiers) == modifier
				&& app.current_map.is_custom_map {
				app.map_data = load_map(app.current_map.map_data)
				expand_map(mut app.map_data, 30, 10)
				app.state = .editor
			}
			if ev.key_code == .escape {
				if app.cli_launch {
					app.gg.quit()
				} else {
					load_main_menu_map(mut app)
					app.state = .menu
				}
			}
		}
		.files_droped {
			if !app.current_map.is_custom_map {
				app.log('current map forbids loading of other maps')
				return
			}
			if app.cli_launch {
				app.log('cannot load map when starting by using the cli')
				return
			}
			num_dropped := sapp.get_num_dropped_files()
			if num_dropped < 1 {
				return
			}
			filename := sapp.get_dropped_file_path(0)
			data := os.read_file(filename) or {
				app.log('failed to read file: $err')
				return
			}
			app.current_map = GameMap{'Drag and Drop', filename, true, data}
			app.map_data = load_map(app.current_map.map_data)
			app.log('opening map $filename')
		}
		.mouse_down {
			if ev.mouse_button != .left && ev.mouse_button != .right {
				return
			}
			mark_as_mine := ev.mouse_button == .left

			cell, cy, cx := pointing_at_cell(app) or {
				return
			}

			if cell.is_revealed || cell.typ == .empty {
				return
			}
			if mark_as_mine == (cell.typ == .mine) {
				app.map_data.cells[cy][cx].is_revealed = true
				if cell.typ == .mine {
					app.map_data.remaining_mines--
				} else if cell.typ == .not_mine {
					app.map_data.remaining_other--
				}
			} else {
				app.map_data.mistakes++
				app.log('Mistake!')
			}
			if app.map_data.remaining_mines == 0 && app.map_data.remaining_other == 0 {
				app.log('Map cleared!')
				if !app.current_map.is_custom_map {
					app.savestate_completion << app.current_map.name
					save_savestate(mut app)
				}
			}
		}
		else {}
	}
}

fn draw_editor(mut app TriangoliApp) {
	if !app.current_map.is_custom_map {
		return
	}

	draw_map(mut app)
}

fn event_editor(mut ev gg.Event, mut app TriangoliApp) {
	if !app.current_map.is_custom_map { // small safeguard that should never happen
		return
	}
	match ev.typ {
		.key_down {
			modifier := $if macos { gg.Modifier.super } $else { gg.Modifier.ctrl }
			if ev.key_code == .s && gg.Modifier(ev.modifiers) == modifier {
				data := export_map(app.map_data)
				app.current_map.map_data = data
				os.write_file(app.current_map.filename, data) or {
					app.log('failed to save map: $err')
					return
				}
				$if macos {
					app.log('saved map into ${os.join_path(os.getwd(), app.current_map.filename)}')
				} $else {
					app.log('saved map into $app.current_map.filename')
				}
			}
			if ev.key_code == .p && gg.Modifier(ev.modifiers) == modifier {
				data := export_map(app.map_data)
				app.current_map.map_data = data
				app.map_data = load_map(app.current_map.map_data)
				app.state = .ingame
				app.log('Switched to playing')
			}
			if ev.key_code == .escape {
				if app.cli_launch {
					app.gg.quit()
				} else {
					load_main_menu_map(mut app)
					app.state = .menu
				}
			}
		}
		.files_droped {
			if app.cli_launch {
				app.log('cannot load map when starting using the cli')
				return
			}
			num_dropped := sapp.get_num_dropped_files()
			if num_dropped < 1 {
				return
			}
			filename := sapp.get_dropped_file_path(0)
			data := os.read_file(filename) or {
				app.log('failed to read file: $err')
				return
			}
			app.current_map = GameMap{'Drag and Drop', filename, true, data}
			app.map_data = load_map(app.current_map.map_data)
			app.log('opening map $filename')
		}
		.mouse_down {
			if ev.mouse_button != .left && ev.mouse_button != .right && ev.mouse_button != .middle {
				return
			}
			cell, cy, cx := pointing_at_cell(app) or {
				return
			}
			if ev.mouse_button == .middle {
				if cell.typ != .empty {
					app.map_data.cells[cy][cx].is_revealed = !cell.is_revealed
				}
			} else {
				if (ev.mouse_button == .left && cell.typ == .mine)
					|| (ev.mouse_button == .right && cell.typ == .not_mine) {
					app.map_data.cells[cy][cx].typ = .empty
					app.map_data.cells[cy][cx].is_revealed = false
				} else {
					app.map_data.cells[cy][cx].typ = if ev.mouse_button == .left {
						CellType.mine
					} else {
						CellType.not_mine
					}
				}
			}
		}
		.mouse_scroll {
			if ev.scroll_y == 0 {
				return
			}
			cell, cy, cx := pointing_at_cell(app) or {
				return
			}
			if cell.typ == .not_mine {
				mut count := cell.count
				if ev.scroll_y > 0 {
					count++
				} else {
					count--
				}
				if count < -1 {
					count = -1
				}
				app.map_data.cells[cy][cx].count = count
			}
		}
		else {}
	}
}


fn pointing_at_cell(app TriangoliApp) ?(Cell, int, int) {
	x := f32(app.gg.mouse_pos_x) * 2 - horizontal_width / 2
	y := f32(app.gg.mouse_pos_y) * 2 - vertical_width / 2
	if x < 0 || y < 0 {
		return error('not pointing at cell')
	}

	mut cx := x / horizontal_width / 2
	cy := y / vertical_width / 2

	if cy >= app.map_data.cells.len {
		return error('not pointing at cell')
	}
	row := app.map_data.cells[int(cy)]

	// println("mouse $x $y")
	// println("cell $cx $cy")
	if (int(cx) + int(cy)) % 2 == 0 {
		if math.fmod(cx, 1) + math.fmod(cy, 1) < 1 {
			cx -= 1
		}
	} else {
		if 1 - math.fmod(cx, 1) + math.fmod(cy, 1) > 1 {
			cx -= 1
		}
	}
	// println("=> $cx $cy")
	if cx < 0 || cx >= row.len {
		return error('not pointing at cell')
	}
	cell := row[int(cx)]
	return cell, int(cy), int(cx)
}
fn draw_map(mut app TriangoliApp) {
	offset_x := vertical_width / 2
	offset_y := horizontal_width / 2
	for i, row in app.map_data.cells {
		for j, cell in row {
			if cell.typ == .empty && app.state != .editor {
				continue
			}
			if (i + j) % 2 == 0 {
				mut x1 := j * horizontal_width - horizontal_width / 2
				mut y1 := (i + 1) * vertical_width
				mut x2 := (j + 1) * horizontal_width + horizontal_width / 2
				mut y2 := (i + 1) * vertical_width
				mut x3 := j * horizontal_width + horizontal_width / 2
				mut y3 := i * vertical_width
				if cell.group >= 0 {
					color := app.map_data.groups[cell.group]
					app.gg.draw_triangle(offset_x + x1, offset_y + y1, offset_x + x2,
						offset_y + y2, offset_x + x3, offset_y + y3, color)
					x1 += 2
					y1 -= 1
					x2 -= 2
					y2 -= 1
					y3 += 2
				}
				mut color := if cell.typ == .empty { c_cell_empty } else { c_cell_unknown }
				if cell.is_revealed {
					color = if cell.typ == .mine { c_cell_mine } else { c_cell_revealed }
				}
				app.gg.draw_triangle(offset_x + x1, offset_y + y1, offset_x + x2, offset_y + y2,
					offset_x + x3, offset_y + y3, color)
				if cell.typ == .not_mine && (cell.is_revealed || app.state == .editor) {
					x := j * horizontal_width + horizontal_width / 2 - 4
					y := i * vertical_width + vertical_width / 2
					text := if cell.count >= 0 { cell.count.str() } else { '?' }
					app.gg.draw_text(offset_x + x, offset_y + y, text,
						color: gx.white
					)
				}
			} else {
				mut x1 := j * horizontal_width - horizontal_width / 2
				mut y1 := i * vertical_width
				mut x2 := (j + 1) * horizontal_width + horizontal_width / 2
				mut y2 := i * vertical_width
				mut x3 := j * horizontal_width + horizontal_width / 2
				mut y3 := (i + 1) * vertical_width
				if cell.group >= 0 {
					color := app.map_data.groups[cell.group]
					app.gg.draw_triangle(offset_x + x1, offset_y + y1, offset_x + x2,
						offset_y + y2, offset_x + x3, offset_y + y3, color)
					x1 += 2
					y1 += 1
					x2 -= 2
					y2 += 1
					y3 -= 2
				}
				mut color := if cell.typ == .empty { c_cell_empty2 } else { c_cell_unknown2 }
				if cell.is_revealed {
					color = if cell.typ == .mine { c_cell_mine2 } else { c_cell_revealed2 }
				}
				app.gg.draw_triangle(offset_x + x1, offset_y + y1, offset_x + x2, offset_y + y2,
					offset_x + x3, offset_y + y3, color)
				if cell.typ == .not_mine && (cell.is_revealed || app.state == .editor) {
					x := j * horizontal_width + horizontal_width / 2 - 4
					y := i * vertical_width + vertical_width / 4
					text := if cell.count >= 0 { cell.count.str() } else { '?' }
					app.gg.draw_text(offset_x + x, offset_y + y, text,
						color: gx.white
					)
				}
			}
		}
	}
}