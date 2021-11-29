import flag
import gg
import gx
import math
import os
import rand
import sokol.sapp
import time
import v.embed_file
import x.json2

const (
	c_background     = gx.hex(0x94A3B8FF)
	c_anim           = gx.hex(0x8F9EB4FF)
	c_cell_empty     = gx.hex(0x8A9AAFAA)
	c_cell_empty2    = gx.hex(0x728299AA)
	c_cell_unknown   = gx.hex(0x334155FF)
	c_cell_unknown2  = gx.hex(0x293548FF)
	c_cell_mine      = gx.hex(0x3073F1FF)
	c_cell_mine2     = gx.hex(0x2563EBFF)
	c_cell_revealed  = gx.hex(0x172033FF)
	c_cell_revealed2 = gx.hex(0x0F172AFF)

	horizontal_width = 40
	vertical_width   = int(math.sqrt((horizontal_width * 2) * (horizontal_width * 2) - horizontal_width * horizontal_width))

	log_timeout      = 5 * time.second

	compaign_maps    = [
		mk_campaign_map('Map 01', $embed_file('campaign/map00-01.tmap')),
		mk_campaign_map('Map 02', $embed_file('campaign/map00-02.tmap')),
	]
)

fn mk_campaign_map(name string, data embed_file.EmbedFileData) GameMap {
	filename := data.path.split('/').last()
	return GameMap{name, filename, true, data.to_string()}
}

struct GameMap {
	name            string
	filename        string
	is_campaign_map bool
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
	gamestate TriangoliState = .menu

	current_map GameMap
	map_data    MapData

	background_animation []Point
	// last_frame time.Time
	cli_launch bool

	logs []Log
}

fn (mut app TriangoliApp) log(text string) {
	log := Log{text, time.now()}
	app.logs << log
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
}

enum CellType {
	not_mine
	mine
	empty
}

struct Point {
mut:
	x  f64
	y  f64
	vx f64
	vy f64
}

struct Log {
	text string
	time time.Time
}

fn main() {
	mut app := &TriangoliApp{}
	app.gg = gg.new_context(
		bg_color: c_background
		width: 1280
		height: 720
		window_title: 'Triangoli'
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
			app.gamestate = .ingame
			data := os.read_file(mapname) or {
				if !editor {
					eprintln('failed to load map file: $err')
					exit(1)
				}
				'{"cells": []}'
			}
			app.current_map = GameMap{mapname, mapname, false, data}
			app.map_data = load_map(data)
			app.cli_launch = true
		}
		if editor {
			app.gamestate = .editor
			if mapname == '' {
				app.current_map = GameMap{'Untitled', 'untitled.tmap', false, '{"cells": []}'}
			}
			expand_map(mut app.map_data, 30, 10)
			app.cli_launch = true
		}
	}

	for _ in 0 .. 40 {
		app.background_animation << Point{rand.f64(), rand.f64(), rand.f64() * 2 - 1, rand.f64() * 2 - 1}
	}

	app.gg.run()
}

fn frame(mut app TriangoliApp) {
	app.gg.begin()
	for mut point in app.background_animation {
		axc := (rand.f64() * 2 - 1) * 0.005
		ayc := (rand.f64() * 2 - 1) * 0.005
		point.vx = math.max(-1, math.min(1, point.vx + axc))
		point.vy = math.max(-1, math.min(1, point.vy + ayc))
		point.x = math.fmod(point.x + point.vx * 0.00002, 1)
		point.y = math.fmod(point.y + point.vy * 0.00002, 1)
		if point.x < 0 {
			point.x = 1 - point.x
		}
		if point.y < 0 {
			point.y = 1 - point.y
		}
		// app.gg.draw_circle(int(point.x * app.gg.width), int(point.y * app.gg.height), 2, c_anim)
	}
	for i, mut point in app.background_animation {
		mut nearest1 := -1
		mut nearest1d := f64(1)
		mut nearest2 := -1
		mut nearest2d := f64(1)
		for j, point2 in app.background_animation {
			distance := math.abs(point.x - point2.x) + math.abs(point.y - point2.y)
			if distance > 0.1 && i != j {
				if distance < nearest1d {
					nearest2 = nearest1
					nearest2d = nearest1d
					nearest1 = j
					nearest1d = distance
				} else if distance < nearest2d {
					nearest2 = j
					nearest2d = distance
				}
			}
		}
		if nearest1 >= 0 && nearest2 >= 0 {
			x1 := int(point.x * app.gg.width)
			y1 := int(point.y * app.gg.height)
			point2 := app.background_animation[nearest1]
			x2 := int(point2.x * app.gg.width)
			y2 := int(point2.y * app.gg.height)
			point3 := app.background_animation[nearest2]
			x3 := int(point3.x * app.gg.width)
			y3 := int(point3.y * app.gg.height)
			app.gg.draw_triangle(x1, y1, x2, y2, x3, y3, c_anim)
		}
	}
	match app.gamestate {
		.menu { draw_menu(mut app) }
		.ingame { draw_game(mut app) }
		.editor { draw_editor(mut app) }
	}
	for app.logs.len > 0 && time.now() - app.logs[0].time > log_timeout {
		app.logs.delete(0)
	}
	if app.logs.len > 0 {
		for i, log in app.logs {
			app.gg.draw_text_def(1, app.gg.height - 21 - 20 * i, log.text)
		}
	}
	app.gg.end()
}

fn event(mut ev gg.Event, mut app TriangoliApp) {
	match app.gamestate {
		.menu { event_menu(mut ev, mut app) }
		.ingame { event_game(mut ev, mut app) }
		.editor { event_editor(mut ev, mut app) }
	}
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
			if cell.is_revealed {
				celldata['is_revealed'] = true
			}
			if cell.typ != .empty {
				celldata['is_mine'] = cell.typ == .mine
			}
			if cell.count > 0 && cell.typ == .not_mine {
				celldata['count'] = cell.count
			}
			if cell.group >= 0 {
				celldata['group'] = cell.group
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
			cell := Cell{.empty, false, 0, -1}
			row << cell
		}
	}
	for md.cells.len < height {
		mut row := []Cell{}
		for _ in 0 .. width {
			cell := Cell{.empty, false, 0, -1}
			row << cell
		}
		md.cells << row
	}
}

fn draw_menu(mut app TriangoliApp) {
	app.gg.draw_text_def(5, 5, 'menu')
	app.gg.draw_text_def(5, 65, 'compaign:')
	$if macos {
		if os.getwd() == '/' {
			// if the cwd is / it probably should be the home dir
			os.chdir(os.home_dir()) or {}
		}
	}
	for i, cmap in compaign_maps {
		app.gg.draw_text(5 + 100 * i, 85, cmap.name, color: gx.dark_blue)
	}
}

fn event_menu(mut ev gg.Event, mut app TriangoliApp) {
	if ev.typ == .key_down {
		modifier := $if macos { gg.Modifier.super } $else { gg.Modifier.ctrl }
		if ev.key_code == .n && gg.Modifier(ev.modifiers) == modifier {
			data := '{"cells":[]}'
			app.current_map = GameMap{'Untitled', 'untitled.tmap', false, data}
			app.map_data = load_map(app.current_map.map_data)
			app.gamestate = .ingame
			app.log('creating new map')
		}
		if ev.key_code == .e && gg.Modifier(ev.modifiers) == modifier {
			data := '{"cells":[]}'
			app.current_map = GameMap{'Untitled', 'untitled.tmap', false, data}
			app.map_data = load_map(app.current_map.map_data)
			expand_map(mut app.map_data, 30, 10)
			app.gamestate = .editor
			app.log('opening new map in editor')
		}
		if ev.key_code == .escape {
			app.gg.quit()
		}
		return
	}
	if ev.typ == .files_droped {
		num_dropped := sapp.get_num_dropped_files()
		if num_dropped < 1 {
			return
		}
		filename := sapp.get_dropped_file_path(0)
		data := os.read_file(filename) or {
			app.log('failed to read file: $err')
			eprintln('unable to read file: $err')
			return
		}
		app.current_map = GameMap{'Drag and Drop', filename, false, data}
		app.map_data = load_map(app.current_map.map_data)
		app.gamestate = .ingame
		app.log('opening map $filename')
	}
	if ev.typ != .mouse_down {
		return
	}
	if ev.mouse_button != .left {
		return
	}
	font_size := 11
	if app.gg.mouse_pos_y < 85 || app.gg.mouse_pos_y > 85 + font_size {
		return
	}
	cmap_id := int(app.gg.mouse_pos_x - 5) / 100
	if cmap_id >= compaign_maps.len {
		return
	}
	cmap := compaign_maps[cmap_id]
	app.current_map = cmap
	app.map_data = load_map(cmap.map_data)
	app.gamestate = .ingame
	app.log('loading campaign $cmap.name')
}

fn draw_game(mut app TriangoliApp) {
	offset_x := vertical_width / 2
	offset_y := horizontal_width / 2
	app.gg.draw_text_def(0, 0, 'Mistakes: $app.map_data.mistakes  Remaining: $app.map_data.remaining_mines')

	// diff := time.now() - app.last_frame
	// app.last_frame = time.now()
	// app.gg.draw_text_def(0, 10, "${1 / (f64(diff.nanoseconds()) / time.second)} fps")

	for i, row in app.map_data.cells {
		for j, cell in row {
			if cell.typ == .empty {
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
				mut color := c_cell_unknown
				if cell.is_revealed {
					color = if cell.typ == .mine { c_cell_mine } else { c_cell_revealed }
				}
				app.gg.draw_triangle(offset_x + x1, offset_y + y1, offset_x + x2, offset_y + y2,
					offset_x + x3, offset_y + y3, color)
				if cell.is_revealed && cell.typ == .not_mine {
					x := j * horizontal_width + horizontal_width / 2 - 4
					y := i * vertical_width + vertical_width / 2
					app.gg.draw_text(offset_x + x, offset_y + y, cell.count.str(),
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
				mut color := c_cell_unknown2
				if cell.is_revealed {
					color = if cell.typ == .mine { c_cell_mine2 } else { c_cell_revealed2 }
				}
				app.gg.draw_triangle(offset_x + x1, offset_y + y1, offset_x + x2, offset_y + y2,
					offset_x + x3, offset_y + y3, color)
				if cell.is_revealed && cell.typ == .not_mine {
					x := j * horizontal_width + horizontal_width / 2 - 4
					y := i * vertical_width + vertical_width / 4
					app.gg.draw_text(offset_x + x, offset_y + y, cell.count.str(),
						color: gx.white
					)
				}
			}
		}
	}

	if app.map_data.remaining_mines == 0 && app.map_data.remaining_other == 0 {
		text := 'You did it!'
		width, height := app.gg.text_size(text)
		app.gg.draw_rect((app.gg.width - width) / 2 - 10, (app.gg.height - height) / 2 - 5,
			width + 20, height + 10, gx.black)
		app.gg.draw_text((app.gg.width - width) / 2, (app.gg.height - height) / 2, text,
			color: gx.white)
	}

	if app.map_data.text != '' {
		app.gg.set_cfg(gx.TextCfg{ size: 30 })
		width, height := app.gg.text_size(app.map_data.text)
		app.gg.draw_text((app.gg.width - width) / 2, app.gg.height - height - 10, app.map_data.text,
			size: 30)
		app.gg.set_cfg(gx.TextCfg{})
	}
}

fn event_game(mut ev gg.Event, mut app TriangoliApp) {
	if ev.typ == .key_down {
		modifier := $if macos { gg.Modifier.super } $else { gg.Modifier.ctrl }
		if ev.key_code == .r && gg.Modifier(ev.modifiers) == modifier {
			app.map_data = load_map(app.current_map.map_data)
		}
		if ev.key_code == .e && gg.Modifier(ev.modifiers) == modifier
			&& !app.current_map.is_campaign_map {
			app.map_data = load_map(app.current_map.map_data)
			expand_map(mut app.map_data, 30, 10)
			app.gamestate = .editor
		}
		if ev.key_code == .escape {
			if app.cli_launch {
				app.gg.quit()
			} else {
				app.gamestate = .menu
			}
		}
		return
	}
	if ev.typ == .files_droped {
		if app.current_map.is_campaign_map {
			app.log('cannot load map while playing campaign')
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
			eprintln('unable to read file: $err')
			return
		}
		app.current_map = GameMap{'Drag and Drop', filename, false, data}
		app.map_data = load_map(app.current_map.map_data)
		app.log('opening map $filename')
	}
	if ev.typ != .mouse_down {
		return
	}
	if ev.mouse_button != .left && ev.mouse_button != .right {
		return
	}
	mark_as_mine := ev.mouse_button == .left

	// figure out which cell
	x := f32(app.gg.mouse_pos_x) * 2 - horizontal_width / 2
	y := f32(app.gg.mouse_pos_y) * 2 - vertical_width / 2
	if x < 0 || y < 0 {
		return
	}

	mut cx := x / horizontal_width / 2
	cy := y / vertical_width / 2

	if cy >= app.map_data.cells.len {
		return
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
		return
	}
	cell := row[int(cx)]

	if cell.is_revealed || cell.typ == .empty {
		return
	}
	if mark_as_mine == (cell.typ == .mine) {
		app.map_data.cells[int(cy)][int(cx)].is_revealed = true
		if cell.typ == .mine {
			app.map_data.remaining_mines--
		} else if cell.typ == .not_mine {
			app.map_data.remaining_other--
		}
	} else {
		app.map_data.mistakes++
		app.log('Mistake!')
	}
}

fn draw_editor(mut app TriangoliApp) {
	if app.current_map.is_campaign_map {
		return
	}

	offset_x := vertical_width / 2
	offset_y := horizontal_width / 2

	for i, row in app.map_data.cells {
		for j, cell in row {
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
				if cell.typ == .not_mine {
					x := j * horizontal_width + horizontal_width / 2 - 4
					y := i * vertical_width + vertical_width / 2
					app.gg.draw_text(offset_x + x, offset_y + y, cell.count.str(),
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
				if cell.typ == .not_mine {
					x := j * horizontal_width + horizontal_width / 2 - 4
					y := i * vertical_width + vertical_width / 4
					app.gg.draw_text(offset_x + x, offset_y + y, cell.count.str(),
						color: gx.white
					)
				}
			}
		}
	}

	if app.map_data.text != '' {
		app.gg.set_cfg(gx.TextCfg{ size: 30 })
		width, height := app.gg.text_size(app.map_data.text)
		app.gg.draw_text((app.gg.width - width) / 2, app.gg.height - height - 10, app.map_data.text,
			size: 30)
		app.gg.set_cfg(gx.TextCfg{})
	}
}

fn event_editor(mut ev gg.Event, mut app TriangoliApp) {
	if app.current_map.is_campaign_map {
		return
	}
	if ev.typ == .key_down {
		modifier := $if macos { gg.Modifier.super } $else { gg.Modifier.ctrl }
		if ev.key_code == .s && gg.Modifier(ev.modifiers) == modifier {
			data := export_map(app.map_data)
			app.current_map.map_data = data
			os.write_file(app.current_map.filename, data) or {
				app.log('failed to save map: $err')
				eprintln('failed to save map: $err')
				return
			}
			println('saved map into $app.current_map.filename')
			app.log('saved map into $app.current_map.filename')
		}
		if ev.key_code == .p && gg.Modifier(ev.modifiers) == modifier {
			data := export_map(app.map_data)
			app.current_map.map_data = data
			app.map_data = load_map(app.current_map.map_data)
			app.gamestate = .ingame
			app.log('Switched to playing')
		}
		if ev.key_code == .escape {
			if app.cli_launch {
				app.gg.quit()
			} else {
				app.gamestate = .menu
			}
		}
		return
	}
	if ev.typ == .files_droped {
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
			eprintln('unable to read file: $err')
			return
		}
		app.current_map = GameMap{'Drag and Drop', filename, false, data}
		app.map_data = load_map(app.current_map.map_data)
		app.log('opening map $filename')
	}
	if ev.typ != .mouse_down && ev.typ != .mouse_scroll {
		return
	}
	if ev.typ == .mouse_down && ev.mouse_button != .left && ev.mouse_button != .right
		&& ev.mouse_button != .middle {
		return
	}
	if ev.typ == .mouse_scroll && ev.scroll_y == 0 {
		return
	}

	// figure out which cell
	x := f32(app.gg.mouse_pos_x) * 2 - horizontal_width / 2
	y := f32(app.gg.mouse_pos_y) * 2 - vertical_width / 2
	if x < 0 || y < 0 {
		return
	}

	mut cx := x / horizontal_width / 2
	cy := y / vertical_width / 2

	if cy >= app.map_data.cells.len {
		return
	}
	row := app.map_data.cells[int(cy)]

	// println("mouse $x $y")
	// println("cell $cx $cy")
	// println("h: $vertical_width w: $horizontal_width")
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
		return
	}
	cell := row[int(cx)]

	if ev.typ == .mouse_down {
		if ev.mouse_button == .middle {
			if cell.typ != .empty {
				app.map_data.cells[int(cy)][int(cx)].is_revealed = !cell.is_revealed
			}
		} else {
			if (ev.mouse_button == .left && cell.typ == .mine)
				|| (ev.mouse_button == .right && cell.typ == .not_mine) {
				app.map_data.cells[int(cy)][int(cx)].typ = .empty
				app.map_data.cells[int(cy)][int(cx)].is_revealed = false
			} else {
				app.map_data.cells[int(cy)][int(cx)].typ = if ev.mouse_button == .left {
					CellType.mine
				} else {
					CellType.not_mine
				}
			}
		}
	} else {
		if cell.typ == .not_mine {
			mut count := cell.count
			if ev.scroll_y > 0 {
				count++
			} else {
				count--
			}
			if count < 0 {
				count = 0
			}
			app.map_data.cells[int(cy)][int(cx)].count = count
		}
	}
}
