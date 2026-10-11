@tool
extends EditorPlugin
## Grass Painter plugin: mode panel (paint / exclusion pen), viewport input routing,
## per-region creation parameters and batch operations on existing regions.
## Self-contained: no references outside this addon folder.

# ---- Paths ----
const REGION_SCRIPT := preload("res://addons/grass_painter/core/grass_region.gd")
const LAYOUT := preload("res://addons/grass_painter/core/paint_layout.gd")
const MESH_SURFACE := preload("res://addons/grass_painter/core/mesh_surface.gd")
const BUILTIN_PRESET := preload("res://addons/grass_painter/presets/grass_default_procedural.tres")

# ---- Tunables ----
const RAY_MAX := 200.0
const BATCH_CONFIRM_LIMIT := 50
const PER_FRAME := 4
const PREVIEW_GRID_LIMIT := 400
const CIRCLE_STEPS := 48
const METADATA_SECTION := "grass_painter_v2"
const PRESET_DIR := "res://grass_presets"

# ---- Panel widgets ----
var _mode_box: OptionButton
var _size_box: SpinBox
var _density_box: SpinBox
var _height_box: SpinBox
var _height_var_box: SpinBox
var _tilt_box: SpinBox
var _thin_box: SpinBox
var _circle_radius_box: SpinBox
var _source_box: OptionButton
var _preset_box: OptionButton
var _degrid_box: CheckBox
var _degrid_angle_box: SpinBox
var _slope_box: SpinBox
var _height_window_box: SpinBox
var _mask_box: SpinBox
var _pick_mask_box: SpinBox       # editor picking collision mask
var _pick_areas_box: CheckBox     # editor picking hits areas too
var _excluded_names_box: LineEdit
var _face_limit_box: SpinBox
var _auto_rebuild_box: CheckBox
var _status: Label
var _buttons: Array[Button] = []

# ---- Dialogs ----
var _confirm_box: ConfirmationDialog
var _pending_points: Array = []
var _pending_height := 0.0
var _pending_scene: Node
var _common_confirm: ConfirmationDialog
var _gizmo: EditorNode3DGizmoPlugin

var _readback := false
var _busy := false
var _abort_request := false   # Esc during a busy batch/series: stop after the current frame slice
var _memory_timer: Timer

# ---- Picking index ----
var _index = null
var _index_aabb := AABB()

var _region_cache: Array = []

# ---- Drag / pen state ----
var _dragging := false
var _drag_start := Vector3.ZERO
var _box_erase := false
var _pen_active := false
var _pen_region: Node3D
var _pen_snapshot: Dictionary = {}
var _pen_erase := false
var _hover_point = null
var _pen_last_x := NAN
var _pen_last_z := NAN
var _pen_circles: Array = []
var _pen_regions: Array = []
var _swallow := false

# ---- Temp preview (owner=null, never saved) ----
var _preview_mi: MeshInstance3D
var _preview_mat: StandardMaterial3D


# ================= Lifecycle =================

func _enter_tree() -> void:
	set_input_event_forwarding_always_enabled()
	_ensure_global_shader_param()

	_panel_build()
	_gizmo = preload("res://addons/grass_painter/gizmo/grass_region_gizmo.gd").new()
	add_node_3d_gizmo_plugin(_gizmo)


func _exit_tree() -> void:
	_flush_memory()
	if _memory_timer != null:
		_memory_timer.queue_free()
		_memory_timer = null
	_close_preview()
	if _gizmo != null:
		remove_node_3d_gizmo_plugin(_gizmo)
		_gizmo = null
	if _confirm_box != null:
		_confirm_box.queue_free()
		_confirm_box = null
	if _common_confirm != null:
		_common_confirm.queue_free()
		_common_confirm = null
	if _panel != null:
		remove_control_from_docks(_panel)
		_panel.free()
		_panel = null

var _panel: VBoxContainer


# ================= Panel construction =================

func _panel_build() -> void:
	_panel = VBoxContainer.new()
	_panel.name = "Grass Painter"
	var title := Label.new()
	title.text = "Grass Painter（快铺 / 排除笔 / 擦除 / 预设 / 分帧）"
	_panel.add_child(title)

	_mode_box = OptionButton.new()
	_mode_box.add_item("选择（不拦截视口）", 0)
	_mode_box.add_item("快铺（点=1块 / Shift+拖=批量 / Ctrl+点=擦除 / Ctrl+Shift+拖=框擦）", 1)
	_mode_box.add_item("排除笔（拖动画圆 / Ctrl+拖=擦圆）", 2)
	_mode_box.set_tooltip_text("0 不拦截视口；1 快铺；2 排除笔")
	_mode_box.item_selected.connect(func(_i: int) -> void:
		# Clear hover/temp preview on mode switch
		_hover_point = null
		_close_preview()
		_save_panel())
	_panel.add_child(_mode_box)

	# --- Fold A: creation parameters ---
	var param_box := VBoxContainer.new()
	_add_fold(_panel, "新建区域参数", param_box)
	_panel.add_child(param_box)
	_size_box = _add_number(param_box, "区域尺寸 m", 0.01, 60.0, 4.0, 0.01)
	_density_box = _add_number(param_box, "密度 丛/m²", 0.5, 60.0, 10.0, 0.5)
	_height_box = _add_number(param_box, "草高度 m", 0.03, 3.0, 0.16, 0.01)
	_height_var_box = _add_number(param_box, "高度随机 ±%", 0.0, 60.0, 25.0, 5.0)
	_tilt_box = _add_number(param_box, "倾斜上限 °", 0.0, 30.0, 12.0, 0.5)
	_thin_box = _add_number(param_box, "胖瘦随机 ±%", 0.0, 50.0, 25.0, 5.0)
	_circle_radius_box = _add_number(param_box, "排除圆半径 m", 0.5, 10.0, 2.0, 0.5)

	_source_box = OptionButton.new()
	_source_box.add_item("表面：仅碰撞体", 0)
	_source_box.add_item("表面：碰撞体优先 + 网格兜底", 1)
	_source_box.add_item("表面：取最高（碰撞+网格）", 2)
	_source_box.add_item("表面：网格优先（可见面说了算）", 3)
	_source_box.item_selected.connect(func(_i: int) -> void:
		if not _readback:
			_save_panel())
	param_box.add_child(_source_box)

	_preset_box = OptionButton.new()
	_preset_box.set_tooltip_text("草种预设；切换会载入该预设的默认密度/草高")
	_preset_box.item_selected.connect(func(_i: int) -> void:
		if _readback:
			return
		_on_preset_chosen())
	param_box.add_child(_preset_box)
	var preset_row := HBoxContainer.new()
	param_box.add_child(preset_row)
	_add_button(preset_row, "↻ 草种", _populate_presets)
	_add_button(preset_row, "💾 存预设", _save_as_preset)

	_degrid_box = CheckBox.new()
	_degrid_box.text = "栅格旋转去走格"
	_degrid_box.button_pressed = true
	_degrid_box.set_tooltip_text("撒点格子整体转种子派生角度，破行列感")
	_degrid_box.toggled.connect(func(_v: bool) -> void: _save_panel())
	param_box.add_child(_degrid_box)
	_degrid_angle_box = _add_number(param_box, "栅格转角上限 °", 0.0, 90.0, 45.0, 1.0)
	_slope_box = _add_number(param_box, "坡度法线阈值", 0.0, 1.0, 0.75, 0.05)
	_slope_box.set_tooltip_text("命中面法线.y 低于此值时不撒草；0.75≈41° 坡")
	_height_window_box = _add_number(param_box, "高度窗口 m", 0.05, 10.0, 0.5, 0.05)
	_height_window_box.set_tooltip_text("落点与区域节点 y 差超过此值即跳过——某处零草先查它")
	_mask_box = _add_number(param_box, "区域碰撞掩码(位)", 1.0, 4294967295.0, 4294967295.0, 1.0)
	_mask_box.set_tooltip_text("碰撞层位掩码整数：第 1 层=1，第 2 层=2，第 8 层=128（第 N 层 = 2^(N-1)）；多层取各位相加")
	_pick_mask_box = _add_number(param_box, "拾取掩码(位)", 1.0, 4294967295.0, 4294967295.0, 1.0)
	_pick_mask_box.set_tooltip_text("编辑器点击射线使用的碰撞层位掩码（整数写法同上）")
	_pick_areas_box = CheckBox.new()
	_pick_areas_box.text = "拾取也命中 Area"
	_pick_areas_box.button_pressed = true
	_pick_areas_box.toggled.connect(func(_v: bool) -> void: _save_panel())
	param_box.add_child(_pick_areas_box)
	_excluded_names_box = LineEdit.new()
	_excluded_names_box.text = ""
	_excluded_names_box.placeholder_text = "示例：树, 水面, 岩石"
	_excluded_names_box.set_tooltip_text("可见网格名包含任一词即排除，逗号分隔；留空=不排除任何网格")
	_excluded_names_box.text_changed.connect(func() -> void: _save_later())
	param_box.add_child(_excluded_names_box)
	_face_limit_box = _add_number(param_box, "网格面数上限", 0.0, 200000.0, 30000.0, 1000.0)

	_auto_rebuild_box = CheckBox.new()
	_auto_rebuild_box.text = "铺/画完自动重建"
	_auto_rebuild_box.button_pressed = true
	_auto_rebuild_box.toggled.connect(func(_v: bool) -> void: _save_panel())
	param_box.add_child(_auto_rebuild_box)
	for s in [_size_box, _density_box, _height_box, _height_var_box, _tilt_box, _thin_box,
			_circle_radius_box, _degrid_angle_box, _slope_box, _height_window_box,
			_mask_box, _pick_mask_box, _face_limit_box]:
		s.value_changed.connect(func(_v: float) -> void: _save_later())
	_size_box.set_tooltip_text("区域边长；批量铺格距=尺寸，块不重叠")
	_density_box.set_tooltip_text("每 m² 丛数：程序化约 8~15，扫描约 2~4")
	_height_box.set_tooltip_text("草高中值 m")
	_height_var_box.set_tooltip_text("草高随机幅度 ±%")
	_tilt_box.set_tooltip_text("每丛随机倾斜上限；破剪影同构")
	_thin_box.set_tooltip_text("每丛水平缩放随机 ±%，与草高解耦")
	_circle_radius_box.set_tooltip_text("排除笔画圆半径；[ / ] 快捷调整")

	# --- Fold B: batch operations ---
	var ops_box := VBoxContainer.new()
	_add_fold(_panel, "批量操作", ops_box)
	_panel.add_child(ops_box)
	_add_button(ops_box, "从选中区域读取参数", _read_selected)
	_add_button(ops_box, "草高度应用到选中区域", func() -> void: _apply_height(false))
	_add_button(ops_box, "草高度应用到全部区域", func() -> void: _apply_height(true))
	_add_button(ops_box, "姿态胖瘦应用到选中区域", func() -> void: _apply_posture(false))
	_add_button(ops_box, "姿态胖瘦应用到全部区域", func() -> void: _apply_posture(true))
	_add_button(ops_box, "密度应用到选中区域", func() -> void: _apply_density(false))
	_add_button(ops_box, "密度应用到全部区域", func() -> void: _apply_density(true))
	_add_button(ops_box, "表面来源应用到选中区域", _apply_source)
	_add_button(ops_box, "草种应用到选中区域", _apply_preset)
	_add_button(ops_box, "重建选中区域", _rebuild_selected)
	_add_button(ops_box, "重建全部 + 保存场景", _rebuild_all)
	_add_button(ops_box, "选中节点处建草地区域", _anchor_region)
	_add_button(ops_box, "清除选中区域草", _clear_selected_grass)
	_add_button(ops_box, "清除选中区域排除圆", _clear_selected_circles)
	_add_button(ops_box, "合并选中区域为一个大区域", _merge_selected)
	_add_button(ops_box, "剥离烘焙：选中区域→运行时重建", func() -> void: _strip_baked(false))
	_add_button(ops_box, "剥离烘焙：全部区域→运行时重建", func() -> void: _strip_baked(true))

	_status = Label.new()
	_status.text = "就绪。无碰撞体的大地面靠网格兜底长草。"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(_status)
	add_control_to_dock(DOCK_SLOT_RIGHT_UR, _panel)

	_preview_mat = _make_preview_material()
	_populate_presets()
	_load_panel()


# ---- small widget helpers ----

func _add_fold(parent: Container, title_text: String, content: Control) -> CheckButton:
	var b := CheckButton.new()
	b.text = "[-] " + title_text
	b.button_pressed = true
	b.toggled.connect(func(on: bool) -> void:
		content.visible = on
		b.text = ("[-] " if on else "[+] ") + title_text)
	parent.add_child(b)
	return b


func _add_button(parent: Container, label_text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = label_text
	b.pressed.connect(callback)
	parent.add_child(b)
	_buttons.append(b)
	return b


func _add_number(parent: VBoxContainer, label_text: String, lo: float, hi: float,
		value: float, step: float = 0.5) -> SpinBox:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(130, 0)
	row.add_child(l)
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(s)
	parent.add_child(row)
	return s


func _parse_names(text: String) -> Array[String]:
	var out: Array[String] = []
	for piece in text.split(",", false):
		var s: String = piece.strip_edges()
		if s != "":
			out.append(s)
	return out


func _names_to_text(arr) -> String:
	var out: Array = []
	for s in arr:
		out.append(String(s))
	return ", ".join(out)


# ================= Busy lock =================

func _set_busy(v: bool) -> void:
	_busy = v
	for b in _buttons:
		if is_instance_valid(b):
			b.disabled = v
	# Input widgets too: changing creation parameters mid-rebuild would be applied to
	# regions already rebuilt with the old values (silent inconsistency)
	for w in [_size_box, _density_box, _height_box, _height_var_box,
			_tilt_box, _thin_box, _circle_radius_box, _degrid_angle_box, _slope_box,
			_height_window_box, _mask_box, _pick_mask_box, _face_limit_box]:
		if is_instance_valid(w):
			(w as SpinBox).set_editable(not v)
	for w in [_mode_box, _source_box, _preset_box]:
		if is_instance_valid(w):
			(w as OptionButton).disabled = v
	for w in [_degrid_box, _pick_areas_box, _auto_rebuild_box]:
		if is_instance_valid(w):
			(w as CheckBox).disabled = v
	if is_instance_valid(_excluded_names_box):
		_excluded_names_box.editable = not v


# ================= Persistence =================

func _save_later() -> void:
	if _readback:
		return
	if _memory_timer == null:
		_memory_timer = Timer.new()
		_memory_timer.one_shot = true
		_memory_timer.wait_time = 0.3
		get_editor_interface().get_base_control().add_child(_memory_timer)
		_memory_timer.timeout.connect(_save_panel)
	_memory_timer.start()


func _flush_memory() -> void:
	if _memory_timer != null and _memory_timer.is_active():
		_memory_timer.stop()
		_save_panel()


func _save_panel() -> void:
	if _panel == null or _readback:
		return
	var es := get_editor_interface().get_editor_settings()
	es.set_project_metadata(METADATA_SECTION, "mode", _mode_box.selected)
	es.set_project_metadata(METADATA_SECTION, "size", _size_box.value)
	es.set_project_metadata(METADATA_SECTION, "density", _density_box.value)
	es.set_project_metadata(METADATA_SECTION, "height", _height_box.value)
	es.set_project_metadata(METADATA_SECTION, "height_var", _height_var_box.value)
	es.set_project_metadata(METADATA_SECTION, "tilt", _tilt_box.value)
	es.set_project_metadata(METADATA_SECTION, "thin", _thin_box.value)
	es.set_project_metadata(METADATA_SECTION, "radius", _circle_radius_box.value)
	es.set_project_metadata(METADATA_SECTION, "source", _source_box.selected)
	es.set_project_metadata(METADATA_SECTION, "preset_path", _selected_preset_path())
	es.set_project_metadata(METADATA_SECTION, "auto_rebuild", _auto_rebuild_box.button_pressed)
	es.set_project_metadata(METADATA_SECTION, "degrid", _degrid_box.button_pressed)
	es.set_project_metadata(METADATA_SECTION, "degrid_angle", _degrid_angle_box.value)
	es.set_project_metadata(METADATA_SECTION, "slope", _slope_box.value)
	es.set_project_metadata(METADATA_SECTION, "height_window", _height_window_box.value)
	es.set_project_metadata(METADATA_SECTION, "mask", _mask_box.value)
	es.set_project_metadata(METADATA_SECTION, "pick_mask", _pick_mask_box.value)
	es.set_project_metadata(METADATA_SECTION, "pick_areas", _pick_areas_box.button_pressed)
	es.set_project_metadata(METADATA_SECTION, "excluded_names", _excluded_names_box.text)
	es.set_project_metadata(METADATA_SECTION, "face_limit", _face_limit_box.value)


func _load_panel() -> void:
	var es := get_editor_interface().get_editor_settings()
	_readback = true
	_mode_box.select(int(es.get_project_metadata(METADATA_SECTION, "mode", 0)))
	_size_box.value = float(es.get_project_metadata(METADATA_SECTION, "size", 4.0))
	_density_box.value = float(es.get_project_metadata(METADATA_SECTION, "density", 10.0))
	_height_box.value = float(es.get_project_metadata(METADATA_SECTION, "height", 0.16))
	_height_var_box.value = float(es.get_project_metadata(METADATA_SECTION, "height_var", 25.0))
	_tilt_box.value = float(es.get_project_metadata(METADATA_SECTION, "tilt", 12.0))
	_thin_box.value = float(es.get_project_metadata(METADATA_SECTION, "thin", 25.0))
	_circle_radius_box.value = float(es.get_project_metadata(METADATA_SECTION, "radius", 2.0))
	_source_box.select(int(es.get_project_metadata(METADATA_SECTION, "source", 1)))
	_auto_rebuild_box.button_pressed = bool(es.get_project_metadata(METADATA_SECTION, "auto_rebuild", true))
	_degrid_box.button_pressed = bool(es.get_project_metadata(METADATA_SECTION, "degrid", true))
	_degrid_angle_box.value = float(es.get_project_metadata(METADATA_SECTION, "degrid_angle", 45.0))
	_slope_box.value = float(es.get_project_metadata(METADATA_SECTION, "slope", 0.75))
	_height_window_box.value = float(es.get_project_metadata(METADATA_SECTION, "height_window", 0.5))
	_mask_box.value = float(es.get_project_metadata(METADATA_SECTION, "mask", 4294967295.0))
	_pick_mask_box.value = float(es.get_project_metadata(METADATA_SECTION, "pick_mask", 4294967295.0))
	_pick_areas_box.button_pressed = bool(es.get_project_metadata(METADATA_SECTION, "pick_areas", true))
	_excluded_names_box.text = String(es.get_project_metadata(METADATA_SECTION, "excluded_names", ""))
	_face_limit_box.value = float(es.get_project_metadata(METADATA_SECTION, "face_limit", 30000.0))
	var saved_preset_path := String(es.get_project_metadata(METADATA_SECTION, "preset_path", ""))
	_select_preset_path(saved_preset_path)
	_readback = false


# ================= Preset dropdown =================

## First item = built-in procedural; following items = .tres files in PRESET_DIR
func _populate_presets() -> void:
	_readback = true
	_preset_box.clear()
	_preset_box.add_item("程序化默认（内置）")
	_preset_box.set_item_metadata(0, "")
	var dir := DirAccess.open(PRESET_DIR)
	if dir != null:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if not dir.current_is_dir and fname.ends_with(".tres"):
				var path: String = PRESET_DIR + "/" + fname
				var res := load(path)
				if res is GrassPreset:
					var idx := _preset_box.get_item_count()
					_preset_box.add_item((res as GrassPreset).preset_name)
					_preset_box.set_item_metadata(idx, path)
			fname = dir.get_next()
		dir.list_dir_end()
	_readback = false


## Path stored in the selected item's metadata ("" = built-in)
func _selected_preset_path() -> String:
	if _preset_box.selected < 0:
		return ""
	var md = _preset_box.get_item_metadata(_preset_box.selected)
	return "" if md == null else String(md)


func _select_preset_path(path: String) -> void:
	for i in _preset_box.item_count:
		var md = _preset_box.get_item_metadata(i)
		if ("" if md == null else String(md)) == path:
			_preset_box.select(i)
			return
	_preset_box.select(0)


func _selected_preset() -> GrassPreset:
	var path := _selected_preset_path()
	if path == "":
		return BUILTIN_PRESET
	return load(path)


## Choosing a preset loads its default density/height into the creation fields
func _on_preset_chosen() -> void:
	var p := _selected_preset()
	_density_box.value = p.default_density
	_height_box.value = (p.default_height_min + p.default_height_max) * 0.5
	_save_panel()


## Save the current creation parameters as a new project preset .tres
func _save_as_preset() -> void:
	DirAccess.make_dir_recursive_absolute(PRESET_DIR)
	var p := GrassPreset.new()
	p.preset_name = "Preset %d" % Time.get_ticks_msec()
	p.is_procedural = true
	p.default_density = _density_box.value
	var heights := _height_range()
	p.default_height_min = heights.x
	p.default_height_max = heights.y
	p.shader_kind = GrassPreset.ShaderKind.PROCEDURAL
	var path := PRESET_DIR + "/grass_preset_%d.tres" % Time.get_unix_time_from_system()
	var err := ResourceSaver.save(p, path)
	if err != OK:
		_set_status("保存预设失败，错误码 %d" % err)
		return
	# The new file may reference external textures: scan just that folder (a full
	# project scan on every editor start was removed; this is the only path that
	# needs the filesystem scan to pick up fresh imports).
	var efs := get_editor_interface().get_resource_filesystem()
	efs.update_files([PRESET_DIR + "/"])
	efs.sources_changed_expose([PRESET_DIR + "/"])
	_populate_presets()
	_select_preset_path(path)
	_set_status("预设已保存：%s（外部资产/贴图可在 Inspector 补充）" % path)


# ================= Viewport input =================

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if _panel == null:
		return AFTER_GUI_INPUT_PASS
	if _busy:
		# Esc while a frame-sliced batch/rebuild is running: request an abort (stops after
		# the current slice); everything else is passed through so the user can keep working
		var ke_busy := event as InputEventKey
		if ke_busy != null and ke_busy.pressed and not ke_busy.echo and ke_busy.keycode == KEY_ESCAPE:
			_abort_request = true
			_set_status("取消请求已收到，当前分帧段结束后停止……")
			return AFTER_GUI_INPUT_STOP
		return AFTER_GUI_INPUT_PASS
	var mode := _mode_box.selected
	if mode == 0:
		if _dragging or _pen_active or _swallow:
			_reset_drag()
		return AFTER_GUI_INPUT_PASS

	# Esc cancels the gesture
	var ke := event as InputEventKey
	if ke != null and ke.pressed and not ke.echo and ke.keycode == KEY_ESCAPE \
			and (_dragging or _pen_active):
		if _dragging:
			_dragging = false
			_swallow = false
			_close_preview()
			_set_status("已取消本次拖框（未铺任何块）")
		else:
			# Pen Esc = true rollback (restore the pre-stroke snapshot, not an undo action);
			# box-drag Esc stays a plain cancel
			_cancel_pen()
			_swallow = false
		return AFTER_GUI_INPUT_STOP

	# [ ] adjusts the circle radius
	if ke != null and ke.pressed and not ke.echo and mode in [1, 2]:
		match ke.keycode:
			KEY_BRACKETLEFT:
				_circle_radius_box.value = maxf(_circle_radius_box.min_value, _circle_radius_box.value - 0.5)
				_set_status("笔刷半径 %.2f m（[ / ] 调整）" % _circle_radius_box.value)
				return AFTER_GUI_INPUT_STOP
			KEY_BRACKETRIGHT:
				_circle_radius_box.value = minf(_circle_radius_box.max_value, _circle_radius_box.value + 0.5)
				_set_status("笔刷半径 %.2f m（[ / ] 调整）" % _circle_radius_box.value)
				return AFTER_GUI_INPUT_STOP

	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_reset_drag()
			_index = null
			var hit := _pick(camera, mb.position)
			_swallow = true
			if hit.is_empty():
				_set_status("射线没打到任何面——检查网格可见性/拾取掩码/排除名。")
				return AFTER_GUI_INPUT_STOP
			if mode == 1:
				if mb.ctrl_pressed and mb.shift_pressed:
					_box_erase = true
					_dragging = true
					_drag_start = hit.position
					_refresh_region_cache()
					_draw_drag_box(hit.position, hit.position, true)
				elif mb.ctrl_pressed:
					_erase_region(hit.position)
				elif mb.shift_pressed:
					_box_erase = false
					_dragging = true
					_drag_start = hit.position
					_refresh_region_cache()
					_draw_drag_box(hit.position, hit.position, false)
				else:
					_refresh_region_cache()
					_place_region(hit.position, true, hit.get("source", "collider"))
				return AFTER_GUI_INPUT_STOP
			if mode == 2:
				_pen_erase = mb.ctrl_pressed
				_start_pen(hit.position)
				return AFTER_GUI_INPUT_STOP
		else:
			if _swallow:
				_swallow = false
				if mode == 1 and _dragging:
					_dragging = false
					_close_preview()
					# A release that lands on nothing (sky / excluded surface) cancels the
					# drag instead of silently falling back to the start point
					var hit2 := _pick(camera, mb.position)
					if hit2.is_empty():
						_set_status("松开处射线没打到任何面——已取消本次拖框（未铺/擦任何块）")
					elif _box_erase:
						_do_box_erase(_drag_start, hit2.position)
					else:
						_batch_place(_drag_start, hit2.position)
				elif mode == 2 and _pen_active:
					_finish_pen()
				return AFTER_GUI_INPUT_STOP

	var mm := event as InputEventMouseMotion
	if mm != null:
		if mode == 1 and _dragging:
			# Releasing outside the viewport never delivers a release event; detect it via
			# the button mask on the next motion and treat it as a cancel (nothing placed)
			if not bool(mm.button_mask & MOUSE_BUTTON_MASK_LEFT):
				_dragging = false
				_swallow = false
				_close_preview()
				_set_status("检测到左键已在视口外松开——已取消本次拖框（未铺/擦任何块）")
				return AFTER_GUI_INPUT_STOP
			var hit3 := _pick(camera, mm.position)
			if not hit3.is_empty():
				_draw_drag_box(_drag_start, hit3.position, _box_erase)
			return AFTER_GUI_INPUT_STOP
		if mode == 2:
			# Releasing outside the viewport mid-stroke = finish the stroke normally
			if _swallow and _pen_active and not bool(mm.button_mask & MOUSE_BUTTON_MASK_LEFT):
				_swallow = false
				_finish_pen()
				return AFTER_GUI_INPUT_STOP
			var hit4 := _pick(camera, mm.position)
			if not hit4.is_empty():
				if _pen_active:
					if _pen_erase:
						_erase_pen_point(hit4.position)
					else:
						_draw_pen_point(hit4.position)
				else:
					_hover_point = {"point": hit4.position, "r": _circle_radius_box.value}
					_redraw_pen_circles()
			elif not _pen_active:
				_hover_point = null
				_close_preview()
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


# ================= Picking =================

func _pick(camera: Camera3D, screen_point: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(screen_point)
	var direction := camera.project_ray_normal(screen_point)
	var q := PhysicsRayQueryParameters3D.create(origin, origin + direction * RAY_MAX,
		int(_pick_mask_box.value))
	q.collide_with_areas = _pick_areas_box.button_pressed
	var physics_point: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(q)
	if not physics_point.is_empty():
		physics_point["source"] = "collider"
	var mode: int = _source_box.selected
	if mode == 0:
		return physics_point
	match mode:
		1:
			if not physics_point.is_empty():
				return physics_point
			return _mesh_pick(origin, direction, RAY_MAX)
		3:
			var gp3 := _mesh_pick(origin, direction, RAY_MAX)
			return gp3 if not gp3.is_empty() else physics_point
		2:
			if physics_point.is_empty():
				return _mesh_pick(origin, direction, RAY_MAX)
			var gp := _mesh_pick(origin, direction, RAY_MAX)
			if gp.is_empty():
				return physics_point
			var dp: float = (physics_point["position"] as Vector3).distance_squared_to(origin)
			var dm: float = (gp["position"] as Vector3).distance_squared_to(origin)
			return gp if dm < dp else physics_point
	return physics_point


## Build/rebuild the mesh index used for viewport picking. Exclude names, skeleton skip and
## the face limit all come from the panel so that "where you can click" matches "where grass
## grows" (the rebuild path passes the same values); MESH_SURFACE.build() resets state, so
## reusing the instance is safe.
func _build_pick_index(scene_root: Node, aabb: AABB) -> void:
	_index_aabb = aabb
	if _index == null:
		_index = MESH_SURFACE.new()
	_index.build(scene_root, aabb, _parse_names(_excluded_names_box.text), true,
		int(_face_limit_box.value))


func _mesh_pick(origin: Vector3, direction: Vector3, max_dist: float) -> Dictionary:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return {}
	var end := origin + direction * max_dist
	# Corridor AABB around the whole ray (the old fixed ±60 m box around the camera
	# silently missed mesh hits beyond it while RAY_MAX is 200 m)
	var lo := origin.min(end) + Vector3(-2.0, -2.0, -2.0)
	var hi := origin.max(end) + Vector3(2.0, 2.0, 2.0)
	var corridor := AABB(lo, hi - lo)
	if _index == null or not _index.bounds.encloses(corridor):
		# Reuse an index that the new corridor fully fits inside; otherwise rebuild
		if _index != null and corridor.encloses(_index.bounds):
			_build_pick_index(scene_root, _index.bounds.merge(corridor))
		else:
			_build_pick_index(scene_root, corridor)
	var point: Dictionary = _index.ray_pick_direction(origin, direction, max_dist)
	if not point.is_empty():
		point["source"] = "mesh"
	return point


func _pick_ground(origin: Vector3) -> Dictionary:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return {}
	var q := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * RAY_MAX,
		int(_pick_mask_box.value))
	q.collide_with_areas = _pick_areas_box.button_pressed
	var hit: Dictionary = scene_root.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		hit["source"] = "collider"
	var mode: int = _source_box.selected
	if mode == 0:
		return hit
	var mesh_point := {}
	if hit.is_empty() or mode == 2 or mode == 3:
		# Down-pick band: XZ around the point, y from the raycast ceiling downward
		var band := AABB(Vector3(origin.x - 3.0, origin.y, origin.z - 3.0),
			Vector3(6.0, RAY_MAX + 3.0, 6.0))
		if _index == null or not _index.bounds.encloses(band):
			_build_pick_index(scene_root, band)
		mesh_point = _index.hit_down(origin.x, origin.z, origin.y, origin.y - RAY_MAX)
		if not mesh_point.is_empty():
			mesh_point["source"] = "mesh"
	match mode:
		1:
			return hit if not hit.is_empty() else mesh_point
		3:
			return mesh_point if not mesh_point.is_empty() else hit
		2:
			if hit.is_empty():
				return mesh_point
			if mesh_point.is_empty():
				return hit
			return mesh_point if (mesh_point["position"] as Vector3).y > (hit["position"] as Vector3).y else hit
	return hit


func _prebuild_batch_index(points: Array, top: float) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null or points.is_empty():
		return
	var minx: float = points[0].x
	var maxx: float = points[0].x
	var minz: float = points[0].y
	var maxz: float = points[0].y
	for p in points:
		minx = minf(minx, p.x)
		maxx = maxf(maxx, p.x)
		minz = minf(minz, p.y)
		maxz = maxf(maxz, p.y)
	var edge := 2.0
	_build_pick_index(scene_root, AABB(Vector3(minx - edge, top - RAY_MAX - 5.0, minz - edge),
		Vector3(maxx - minx + edge * 2.0, RAY_MAX + 10.0, maxz - minz + edge * 2.0)))


# ================= Region placement =================

func _place_region(world_point: Vector3, check_dup: bool = true, source: String = "collider",
		ur = null, salt: int = 0) -> Node3D:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		_set_status("没有打开的场景")
		return null
	if check_dup and _find_region(scene_root, world_point, 0.1) != null:
		_set_status("该处已有草地区域，跳过（防重叠）")
		return null
	var region := Node3D.new()
	region.set_script(REGION_SCRIPT)
	region.name = "GrassRegion_%d_%d" % [roundi(world_point.x), roundi(world_point.z)]
	var s: float = _size_box.value
	region.set("size", Vector3(s, 1.0, s))
	region.set("density", _density_box.value)
	var heights := _height_range()
	region.set("height_min", heights.x)
	region.set("height_max", heights.y)
	region.set("tilt_max", _tilt_box.value)
	region.set("thin_variation", _thin_box.value * 0.01)
	region.set("surface_source", _source_box.selected)
	var preset_path := _selected_preset_path()
	if preset_path != "":
		region.set("preset", load(preset_path))
	region.set("degrid_rotation", _degrid_box.button_pressed)
	region.set("degrid_angle", _degrid_angle_box.value)
	region.set("normal_slope_threshold", _slope_box.value)
	region.set("height_window", _height_window_box.value)
	region.set("collision_mask", int(_mask_box.value))
	region.set("excluded_mesh_names", _parse_names(_excluded_names_box.text))
	region.set("mesh_face_limit", int(_face_limit_box.value))
	var seed_base := int(absf(world_point.x * 7.31 + world_point.z * 13.7))
	region.set("seed", 1 + absi((seed_base * 2654435761) ^ (salt * 40503)) % 99991)
	region.position = scene_root.to_local(world_point)
	if ur != null:
		ur.add_do_method(scene_root, "add_child", region, true)
		ur.add_do_property(region, "owner", scene_root)
		ur.add_do_reference(region)
		ur.add_undo_property(region, "owner", scene_root)
		ur.add_undo_method(scene_root, "remove_child", region)
		return region
	var u := get_undo_redo()
	u.create_action("Place Grass Region")
	u.add_do_method(scene_root, "add_child", region, true)
	u.add_do_property(region, "owner", scene_root)
	u.add_do_reference(region)
	u.add_undo_property(region, "owner", scene_root)
	u.add_undo_method(scene_root, "remove_child", region)
	u.commit_action()
	if _auto_rebuild_box.button_pressed:
		region.call("build")
		_attach_owner(region, scene_root)
	_refresh_region_cache()
	_gizmo.refresh_region(region)
	_set_status("铺了一块 @ (%.1f, %.1f, %.1f) 落点=%s" % [
		world_point.x, world_point.y, world_point.z, source])
	return region


func _height_range() -> Vector2:
	var h: float = _height_box.value
	var v: float = _height_var_box.value * 0.01
	return Vector2(maxf(0.02, h * (1.0 - v)), maxf(0.02, h * (1.0 + v)))


# ---- batch placement ----

func _batch_place(a: Vector3, b: Vector3) -> void:
	# Shift+click (no drag) falls back to one region — resolved through the current surface
	# source mode rather than hardcoding "collider"; nothing under the point = place nothing
	if absf(a.x - b.x) < 0.1 and absf(a.z - b.z) < 0.1:
		var near := _pick_ground(Vector3(a.x, a.y + 60.0, a.z))
		if near.is_empty():
			_set_status("Shift+点：该处没有可长草表面（碰撞体/视觉网格均未命中）")
			return
		_place_region(near.position, true, near.get("source", "collider"))
		return
	var center := Vector2((a.x + b.x) * 0.5, (a.z + b.z) * 0.5)
	var half := Vector2(absf(a.x - b.x) * 0.5, absf(a.z - b.z) * 0.5)
	var points := LAYOUT.grid_points(center, half, _size_box.value)
	var top := maxf(a.y, b.y) + 60.0
	if points.size() > BATCH_CONFIRM_LIMIT:
		_ask_batch(points, top)
		return
	_run_batch(points, top)


func _ask_batch(points: Array, top: float) -> void:
	if _confirm_box == null:
		_confirm_box = ConfirmationDialog.new()
		_confirm_box.title = "批量铺确认"
		_confirm_box.confirmed.connect(func() -> void:
			var pending := _pending_points
			_pending_points = []
			if not _scene_valid(_pending_scene):
				_set_status("批量铺取消：场景已关闭或切换")
				return
			_run_batch(pending, _pending_height))
		get_editor_interface().get_base_control().add_child(_confirm_box)
	_pending_points = points
	_pending_height = top
	_pending_scene = get_editor_interface().get_edited_scene_root()
	_confirm_box.dialog_text = "框内要铺 %d 块区域（格距 %.1fm）。分帧执行，整批一次撤销。确定？" % [
		points.size(), _size_box.value]
	_confirm_box.popup_centered()


func _run_batch(points: Array, top: float) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	_set_busy(true)
	_abort_request = false   # clear any stale Esc request from a previous run
	var aborted := false
	var unlocked := false
	var unlock := func() -> void:
		if not unlocked:
			unlocked = true
			_set_busy(false)
	_refresh_region_cache()
	if _source_box.selected != 0:
		_prebuild_batch_index(points, top)
	var to_build: Array = []
	var skipped := 0
	var fallback := 0
	for i in points.size():
		var p = points[i]
		var hit := _pick_ground(Vector3(p.x, top, p.y))
		if not hit.is_empty():
			var code := _cache_code(hit.position, 0.1)
			if code == 0:
				var source: String = hit.get("source", "collider")
				if source == "mesh":
					fallback += 1
				to_build.append({"point": hit.position, "source": source})
				_region_cache.append({"region": null, "half_x": _size_box.value * 0.5,
					"half_z": _size_box.value * 0.5, "pending": hit.position})
			else:
				skipped += 1
		else:
			skipped += 1
		if i % PER_FRAME == PER_FRAME - 1:
			_set_status("批量铺：找落点 %d/%d …" % [i + 1, points.size()])
			await get_tree().process_frame
			if not _scene_valid(scene_root) or _abort_request:
				aborted = true
				break
	unlock.call()
	if aborted:
		_set_status("批量铺已中止（场景关闭/切换或按了 Esc；尚未铺任何块）")
		return
	if to_build.is_empty():
		_set_status("批量铺 0 块（跳过 %d；网格兜底 %d）" % [skipped, fallback])
		return
	_register_and_rebuild(to_build, "批量铺", skipped, fallback)


func _register_and_rebuild(to_build: Array, label: String, skipped: int = 0,
		fallback: int = -1) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null or to_build.is_empty():
		return
	var ur := get_undo_redo()
	ur.create_action("%s ×%d" % [label, to_build.size()])
	var regions: Array[Node3D] = []
	for k in to_build.size():
		var region := _place_region(to_build[k]["point"], false, to_build[k]["source"], ur, k + 1)
		if region != null:
			regions.append(region)
	ur.commit_action()
	_refresh_region_cache()
	var rebuild_text := "，未重建"
	if _auto_rebuild_box.button_pressed:
		var res := await _frame_rebuild(regions, label, true)
		if res["aborted"]:
			_set_status("%s中断：场景切换，已登记 %d 块（可 Ctrl+Z）" % [label, regions.size()])
			return
		rebuild_text = "，已重建（完成 %d，跳过 %d）" % [res["done"], res["skipped"]]
	if fallback >= 0:
		_set_status("%s %d 块（跳过 %d；兜底 %d）%s——整批一次 Ctrl+Z" % [
			label, regions.size(), skipped, fallback, rebuild_text])
	else:
		_set_status("%s %d 块（跳过 %d）%s——整批一次 Ctrl+Z" % [
			label, regions.size(), skipped, rebuild_text])


# ================= Eraser =================

func _erase_region(world_point: Vector3) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	var region := _find_region(scene_root, world_point, 0.0)
	if region == null:
		_set_status("Ctrl+擦除：光标下没有草地区域")
		return
	var parent: Node = region.get_parent()
	var ur := get_undo_redo()
	ur.create_action("删除草地区域")
	ur.add_undo_method(self, "_undo_select_node", region)
	ur.add_do_property(region, "owner", null)
	ur.add_do_method(parent, "remove_child", region)
	ur.add_do_reference(region)
	ur.add_undo_property(region, "owner", scene_root)
	ur.add_undo_method(parent, "add_child", region, true)
	ur.commit_action()
	_refresh_region_cache()
	_gizmo.forget_region(region)
	_set_status("已擦除「%s」（Ctrl+Z 可恢复并选中）" % region.name)


func _undo_select_node(node) -> void:
	if is_instance_valid(node) and node.is_inside_tree():
		get_editor_interface().get_selection().add_to_selection(node)


## Box erase: remove every region whose XZ AABB intersects the world rectangle,
## one undo action (restores owner and selection).
func _do_box_erase(a: Vector3, b: Vector3) -> void:
	var minx := minf(a.x, b.x)
	var maxx := maxf(a.x, b.x)
	var minz := minf(a.z, b.z)
	var maxz := maxf(a.z, b.z)
	var target: Array = []
	for e in _region_cache:
		if e.has("pending"):
			continue
		var region: Node3D = e["region"]
		if not is_instance_valid(region):
			continue
		var p: Vector3 = region.global_position
		var rx0: float = p.x - float(e["half_x"])
		var rx1: float = p.x + float(e["half_x"])
		var rz0: float = p.z - float(e["half_z"])
		var rz1: float = p.z + float(e["half_z"])
		if rx1 < minx or rx0 > maxx or rz1 < minz or rz0 > maxz:
			continue
		target.append(region)
	if target.is_empty():
		_set_status("框擦：框内没有草地区域")
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	var ur := get_undo_redo()
	ur.create_action("框擦草地区域 ×%d" % target.size())
	for region in target:
		ur.add_undo_method(self, "_undo_select_node", region)
	for region in target:
		var parent: Node = region.get_parent()
		ur.add_do_property(region, "owner", null)
		ur.add_do_method(parent, "remove_child", region)
		ur.add_do_reference(region)
		ur.add_undo_property(region, "owner", scene_root)
		ur.add_undo_method(parent, "add_child", region, true)
	ur.commit_action()
	_refresh_region_cache()
	for region in target:
		_gizmo.forget_region(region)
	_set_status("框擦删除 %d 个区域（一次 Ctrl+Z 恢复）" % target.size())


# ================= Anchor regions =================

func _anchor_region() -> void:
	var selected := get_editor_interface().get_selection().get_selected_nodes()
	if selected.is_empty():
		_set_status("先在场景树选中节点当区域中心锚点")
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	_index = null
	_refresh_region_cache()
	var to_build: Array = []
	var skipped := 0
	var fallback := 0
	var last_msg := ""
	for node in selected:
		var n3 := node as Node3D
		if n3 == null:
			skipped += 1
			continue
		var origin: Vector3 = n3.global_position
		var hit := _pick_ground(Vector3(origin.x, origin.y + 60.0, origin.z))
		if hit.is_empty():
			last_msg = "「%s」下方无碰撞体也无可见网格" % n3.name
			skipped += 1
			continue
		var code := _cache_code(hit.position, 0.1)
		if code != 0:
			last_msg = "「%s」处已有区域或锚点重叠" % n3.name
			skipped += 1
			continue
		if hit.get("source", "collider") == "mesh":
			fallback += 1
		to_build.append({"point": hit.position, "source": hit.get("source", "collider")})
		_region_cache.append({"region": null, "half_x": _size_box.value * 0.5,
			"half_z": _size_box.value * 0.5, "pending": hit.position})
	if to_build.is_empty():
		_set_status(last_msg if last_msg != "" else "没有可用 Node3D 锚点（跳过 %d）" % skipped)
		return
	_register_and_rebuild(to_build, "锚点建区", skipped, fallback)


# ================= Merge =================

func _merge_selected() -> void:
	var selected: Array = []
	for n in get_editor_interface().get_selection().get_selected_nodes():
		if n.get_script() == REGION_SCRIPT:
			selected.append(n)
	var plan: Dictionary = LAYOUT.merge_plan(selected)
	if not plan["ok"]:
		_set_status(plan["error"])
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	var new_region := Node3D.new()
	new_region.set_script(REGION_SCRIPT)
	new_region.name = "GrassRegion_Merged_%d_%d" % [
		roundi((plan["center"] as Vector3).x), roundi((plan["center"] as Vector3).z)]
	new_region.position = scene_root.to_local(plan["center"])
	new_region.set("size", plan["size"])
	new_region.set("exclusion_circles", plan["exclusion_circles"])
	new_region.set("seed", plan["seed"])
	var base: Node3D = selected[0]
	# Must cover every creation/behavior parameter, or the merged region silently reverts
	# to defaults (rebuild_on_start in particular: merging stripped regions would turn
	# runtime grass back into baked)
	for k in ["density", "height_min", "height_max", "tilt_max", "thin_variation",
			"surface_source", "normal_slope_threshold", "height_window", "raycast_height",
			"collision_mask", "excluded_mesh_names", "excluded_node_prefix", "mesh_face_limit",
			"degrid_rotation", "degrid_angle", "rebuild_on_start"]:
		new_region.set(k, base.get(k))
	# Preset: share the base region's preset resource (null for the built-in)
	var base_preset: GrassPreset = base.get("preset")
	if base_preset != null:
		new_region.set("preset", base_preset)
	var ur := get_undo_redo()
	ur.create_action("合并草地区域 ×%d" % selected.size())
	for old in plan["old_regions"]:
		ur.add_undo_method(self, "_undo_select_node", old)
	ur.add_do_method(scene_root, "add_child", new_region, true)
	ur.add_do_property(new_region, "owner", scene_root)
	ur.add_do_reference(new_region)
	for old in plan["old_regions"]:
		ur.add_do_property(old, "owner", null)
		ur.add_do_method(old.get_parent(), "remove_child", old)
		ur.add_undo_property(old, "owner", scene_root)
		ur.add_undo_method(old.get_parent(), "add_child", old, true)
	ur.add_undo_method(scene_root, "remove_child", new_region)
	ur.commit_action()
	_refresh_region_cache()
	if _auto_rebuild_box.button_pressed:
		new_region.call("build")
		_attach_owner(new_region, scene_root)
	_gizmo.refresh_region(new_region)
	_set_status("合并完成：%d → 1（尺寸 %.1fm，圆 %d 个，一次 Ctrl+Z）" % [
		selected.size(), (plan["size"] as Vector3).x, (plan["exclusion_circles"] as Array).size()])


# ================= Baked stripping =================

func _strip_baked(all: bool) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	var target: Array = []
	if all:
		target = _all_regions(scene_root) if scene_root != null else []
	else:
		for n in get_editor_interface().get_selection().get_selected_nodes():
			if n.get_script() == REGION_SCRIPT:
				target.append(n)
	if target.is_empty():
		_set_status("没有目标区域")
		return
	_confirm_common("剥离烘焙数据",
		"将对 %d 个区域设置「启动时自动重建」并删除当前草层。\n保存后场景大幅瘦身；不可撤销（恢复=重建全部+保存）。\n建议先合并小区域。确定？" % target.size(),
		func() -> void:
			# The scene may have been closed or switched while the dialog was open: the
			# captured nodes belong to the old scene, so re-validate before touching them
			var root_now := get_editor_interface().get_edited_scene_root()
			if root_now == null or root_now != scene_root:
				_set_status("剥离烘焙取消：场景已关闭或切换")
				return
			var live: Array = []
			for r in target:
				if is_instance_valid(r) and r.is_inside_tree() \
						and r.get_tree() != null and r.get_tree().edited_scene_root == root_now:
					live.append(r)
			if live.is_empty():
				_set_status("剥离烘焙取消：目标区域均已失效")
				return
			for r in live:
				r.set("rebuild_on_start", true)
				r.call("clear_grass")
			_gizmo_refresh_all(live)
			_set_status("已剥离 %d 个区域——请立即保存；运行时自动重建" % live.size()))


# ================= Exclusion pen =================

func _start_pen(world_point: Vector3) -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	_refresh_region_cache()
	_pen_circles = []
	_pen_regions = []
	_pen_snapshot = {}
	_hover_point = null
	_pen_active = true
	if not _switch_pen(scene_root, world_point):
		_pen_active = false
		_set_status("光标下没有草地区域（排除笔只能在区域内）")
		return
	if _pen_erase:
		_erase_pen_point(world_point)
	else:
		_draw_pen_point(world_point)


func _switch_pen(scene_root: Node, world_point: Vector3) -> bool:
	var region := _find_region(scene_root, world_point, 0.0)
	if region == null:
		return false
	_pen_region = region
	_pen_last_x = NAN
	_pen_last_z = NAN
	if not _pen_snapshot.has(region):
		_pen_snapshot[region] = (region.get("exclusion_circles") as Array).duplicate()
	if not _pen_regions.has(region):
		_pen_regions.append(region)
	return true


func _draw_pen_point(world_point: Vector3) -> void:
	if _pen_region == null:
		return
	var local0: Vector3 = _pen_region.to_local(world_point)
	var size0: Vector3 = _pen_region.get("size")
	var inside := absf(local0.x) <= size0.x * 0.5 and absf(local0.z) <= size0.z * 0.5
	if not inside:
		var scene_root := get_editor_interface().get_edited_scene_root()
		var new_region := _find_region(scene_root, world_point, 0.0)
		if new_region == null or new_region == _pen_region:
			return
		_pen_region = null
		if not _switch_pen(scene_root, world_point):
			return
	var local: Vector3 = _pen_region.to_local(world_point)
	var radius: float = _circle_radius_box.value
	if not is_nan(_pen_last_x):
		var dx := local.x - _pen_last_x
		var dz := local.z - _pen_last_z
		if dx * dx + dz * dz < radius * radius * 0.64:
			return
	if _pen_region.call("add_exclusion_circle", local.x, local.z, radius):
		_pen_last_x = local.x
		_pen_last_z = local.z
		_sync_pen_circles()
		_set_status("排除圆 @本地(%.1f, %.1f) r=%.1f（%s）" % [
			local.x, local.z, radius, _pen_region.name])


func _erase_pen_point(world_point: Vector3) -> void:
	if _pen_region == null:
		return
	var local0: Vector3 = _pen_region.to_local(world_point)
	var size0: Vector3 = _pen_region.get("size")
	if absf(local0.x) > size0.x * 0.5 or absf(local0.z) > size0.z * 0.5:
		var scene_root := get_editor_interface().get_edited_scene_root()
		var new_region := _find_region(scene_root, world_point, 0.0)
		if new_region == null or new_region == _pen_region:
			return
		_pen_region = null
		if not _switch_pen(scene_root, world_point):
			return
	var local: Vector3 = _pen_region.to_local(world_point)
	# Same 0.8r throttle as the draw path: without it every motion event duplicates the
	# whole circle list and rebuilds all ring previews (dozens of redundant passes per drag)
	var radius: float = _circle_radius_box.value
	if not is_nan(_pen_last_x):
		var dx := local.x - _pen_last_x
		var dz := local.z - _pen_last_z
		if dx * dx + dz * dz < radius * radius * 0.64:
			return
	if _pen_region.call("remove_exclusion_circle", local.x, local.z):
		_pen_last_x = local.x
		_pen_last_z = local.z
		_sync_pen_circles()
		_set_status("擦除排除圆 @本地(%.1f, %.1f)（%s）" % [local.x, local.z, _pen_region.name])


func _sync_pen_circles() -> void:
	_pen_circles = []
	for r in _pen_regions:
		if not (is_instance_valid(r) and r.is_inside_tree()):
			continue
		for c in r.get("exclusion_circles"):
			var world: Vector3 = r.global_transform * Vector3(c.x, 0.0, c.y)
			_pen_circles.append({"point": world, "r": c.z})
	_redraw_pen_circles()


func _finish_pen() -> void:
	_pen_active = false
	_pen_region = null
	var ur := get_undo_redo()
	if not _pen_regions.is_empty():
		ur.create_action("排除笔")
		for region in _pen_regions:
			if not (is_instance_valid(region) and region.is_inside_tree()):
				continue
			var now: Array = (region.get("exclusion_circles") as Array).duplicate()
			var old: Array = _pen_snapshot.get(region, now)
			ur.add_do_property(region, "exclusion_circles", now)
			ur.add_undo_property(region, "exclusion_circles", old)
		ur.commit_action()
	_hover_point = null
	_close_preview()
	if not _auto_rebuild_box.button_pressed or _pen_regions.is_empty():
		_set_status("排除笔收笔：涉及 %d 个区域，未重建" % _pen_regions.size())
		return
	_rebuild_pen_regions()


func _rebuild_pen_regions() -> void:
	var regions: Array = []
	for r in _pen_regions:
		if is_instance_valid(r) and r.is_inside_tree():
			regions.append(r)
	_pen_regions = []
	if regions.is_empty():
		return
	var res := await _frame_rebuild(regions, "排除笔")
	if res["aborted"]:
		_set_status("排除笔中断：场景切换（已重建 %d）" % res["done"])
	else:
		_gizmo_refresh_all(regions)
		_set_status("排除笔：已重建 %d 个区域（跳过 %d；整笔一次 Ctrl+Z）" % [
			res["done"], res["skipped"]])


## Esc during an exclusion stroke: roll back to the pre-stroke snapshot (no undo action is
## created — the stroke leaves no history at all); rebuild the touched regions frame-sliced
## when auto-rebuild is on.
func _cancel_pen() -> void:
	_pen_active = false
	_pen_region = null
	var regions: Array = []
	for r in _pen_regions:
		if is_instance_valid(r) and r.is_inside_tree() and _pen_snapshot.has(r):
			r.set("exclusion_circles", (_pen_snapshot[r] as Array).duplicate())
			regions.append(r)
	_pen_regions = []
	_hover_point = null
	_close_preview()
	_gizmo_refresh_all(regions)
	if not _auto_rebuild_box.button_pressed or regions.is_empty():
		_set_status("Esc 取消：本次排除圆已回滚（涉及 %d 个区域，未重建）" % regions.size())
		return
	var res := await _frame_rebuild(regions, "排除笔回滚", true)
	if res["aborted"]:
		_set_status("排除笔回滚中断：场景切换（已重建 %d）" % res["done"])
	else:
		_gizmo_refresh_all(regions)
		_set_status("Esc 回滚：已重建 %d 个区域（跳过 %d；整笔不入撤销历史）" % [
			res["done"], res["skipped"]])


# ================= Frame rebuild =================

func _frame_rebuild(regions: Array, label: String, clustered: bool = false) -> Dictionary:
	var start_ms := Time.get_ticks_msec()
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return {"done": 0, "skipped": regions.size(), "aborted": true}
	_set_busy(true)
	_abort_request = false   # each rebuild starts with a clean Esc state
	var done := 0
	var skipped := 0
	var aborted := false
	var n := regions.size()
	var cluster_map: Dictionary = {}
	if clustered:
		cluster_map = _build_cluster_map(regions)
	for i in n:
		var r: Node = regions[i]
		if not is_instance_valid(r) or not r.is_inside_tree():
			skipped += 1
			continue
		# Scene closed/switched or the user asked to abort - stop after this slice
		if get_editor_interface().get_edited_scene_root() != scene_root or _abort_request:
			aborted = true
			break
		if cluster_map.has(r):
			var desc: Dictionary = cluster_map[r]
			if not desc.has("index"):
				var idx = MESH_SURFACE.new()
				idx.build(scene_root, desc["aabb"], desc["names"], true, int(desc["face_limit"]))
				desc["index"] = idx
			r.call("build", desc["index"])
		else:
			r.call("build")
		_attach_owner(r, scene_root)
		done += 1
		if (done + skipped) % PER_FRAME == 0:
			_set_status("%s：重建中 %d/%d …" % [label, done + skipped, n])
			await get_tree().process_frame
	var clumps := 0
	for r in regions:
		if is_instance_valid(r) and r.get("last_transforms") != null:
			clumps += (r.get("last_transforms") as Array).size()
	_set_busy(false)
	return {"done": done, "skipped": skipped, "aborted": aborted,
		"clumps": clumps, "ms": Time.get_ticks_msec() - start_ms}


func _build_cluster_map(regions: Array) -> Dictionary:
	const adjacency := 8.0
	var groups: Dictionary = {}
	for r in regions:
		if not (is_instance_valid(r) and r.is_inside_tree()):
			continue
		if int(r.get("surface_source")) == 0:
			continue
		var names: Array = r.get("excluded_mesh_names")
		var sorted_names: Array = []
		for s in names:
			sorted_names.append(String(s))
		sorted_names.sort()
		var signature: String = "/".join(sorted_names) + "#" + str(int(r.get("mesh_face_limit")))
		if not groups.has(signature):
			groups[signature] = []
		groups[signature].append({"region": r, "aabb": r.call("_mesh_range"),
			"names": r.get("excluded_mesh_names"), "face_limit": int(r.get("mesh_face_limit"))})
	var out: Dictionary = {}
	for signature in groups.keys():
		var members: Array = groups[signature]
		var cluster_list: Array = []
		for e in members:
			var merged: AABB = e["aabb"]
			var cluster_id = -1
			for ci in cluster_list.size():
				if (cluster_list[ci]["aabb"] as AABB).grow(adjacency).intersects(merged):
					cluster_id = ci
					break
			if cluster_id < 0:
				cluster_list.append({"aabb": merged, "members": [e],
					"names": (e["names"] as Array).duplicate(), "face_limit": e["face_limit"]})
			else:
				var c0: Dictionary = cluster_list[cluster_id]
				c0["aabb"] = (c0["aabb"] as AABB).merge(merged)
				(c0["members"] as Array).append(e)
				for s in e["names"]:
					if not (c0["names"] as Array).has(s):
						(c0["names"] as Array).append(s)
				c0["face_limit"] = maxi(int(c0["face_limit"]), int(e["face_limit"]))
		for desc in cluster_list:
			desc["range"] = (desc["aabb"] as AABB).grow(1.0)
			for e2 in desc["members"]:
				out[e2["region"]] = desc
	return out


func _rebuild_selected() -> void:
	if _busy:
		return
	var target: Array = []
	for node in get_editor_interface().get_selection().get_selected_nodes():
		if node.get_script() == REGION_SCRIPT:
			target.append(node)
	if target.is_empty():
		_set_status("选中里没有草地区域")
		return
	var res := await _frame_rebuild(target, "重建选中", true)
	_set_status("重建选中完成 %d 个（跳过 %d%s）" % [
		res["done"], res["skipped"], "，已中止" if res["aborted"] else ""])


func _rebuild_all() -> void:
	if _busy:
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		_set_status("没有打开的场景")
		return
	var regions := _all_regions(scene_root)
	if regions.is_empty():
		_set_status("场景里没有草地区域")
		return
	if regions.size() > BATCH_CONFIRM_LIMIT:
		_confirm_common("重建全部确认",
			"将分帧重建 %d 个区域并保存场景，确定？" % regions.size(),
			func() -> void: _do_rebuild_all(regions))
		return
	_do_rebuild_all(regions)


func _do_rebuild_all(regions: Array) -> void:
	var res := await _frame_rebuild(regions, "重建全部", true)
	if res["aborted"]:
		_set_status("重建全部中断：场景切换（已重建 %d）" % res["done"])
		return
	await get_tree().process_frame
	var ok := get_editor_interface().save_scene()
	_set_status("重建 %d 个区域（跳过 %d，共 %d 丛，%dms），场景保存%s" % [
		res["done"], res["skipped"], res["clumps"], res["ms"], "成功" if ok else "失败"])


# ================= Clear selected =================

func _clear_selected_grass() -> void:
	for node in get_editor_interface().get_selection().get_selected_nodes():
		if node.get_script() == REGION_SCRIPT:
			node.call("clear_grass")
	_set_status("已清除选中区域草（重新生成即恢复）")


func _clear_selected_circles() -> void:
	for node in get_editor_interface().get_selection().get_selected_nodes():
		if node.get_script() == REGION_SCRIPT:
			var empty: Array[Vector3] = []
			var ur := get_undo_redo()
			ur.create_action("清除排除圆")
			ur.add_do_property(node, "exclusion_circles", empty)
			ur.add_undo_property(node, "exclusion_circles",
				(node.get("exclusion_circles") as Array).duplicate())
			ur.commit_action()
			_gizmo.refresh_region(node)
	_set_status("清除选中区域排除圆（Ctrl+Z）")


# ================= Read selected =================

func _read_selected() -> void:
	var target: Array = []
	for n in get_editor_interface().get_selection().get_selected_nodes():
		if n.get_script() == REGION_SCRIPT:
			target.append(n)
	if target.is_empty():
		_set_status("先选中至少一个草地区域")
		return
	var r: Node = target[0]
	var region_size: Vector3 = r.get("size")
	_readback = true
	_size_box.value = region_size.x
	_density_box.value = r.get("density")
	var lo: float = r.get("height_min")
	var hi: float = r.get("height_max")
	var mid := (lo + hi) * 0.5
	_height_box.value = mid
	_height_var_box.value = (0.0 if mid <= 0.0 else (hi - mid) / mid * 100.0)
	_tilt_box.value = r.get("tilt_max")
	_thin_box.value = (r.get("thin_variation") as float) * 100.0
	_source_box.select(int(r.get("surface_source")))
	var region_preset: GrassPreset = r.get("preset")
	_select_preset_path("" if region_preset == null else region_preset.resource_path)
	_degrid_box.button_pressed = bool(r.get("degrid_rotation"))
	_degrid_angle_box.value = r.get("degrid_angle")
	_slope_box.value = r.get("normal_slope_threshold")
	_height_window_box.value = r.get("height_window")
	_mask_box.value = r.get("collision_mask")
	_excluded_names_box.text = _names_to_text(r.get("excluded_mesh_names"))
	_face_limit_box.value = r.get("mesh_face_limit")
	_readback = false
	_set_status("已读取「%s」的参数%s" % [r.name, "（多选取第一个）" if target.size() > 1 else ""])


# ================= Apply parameter batches =================

func _apply_height(all: bool) -> void:
	var target := _target_regions(all)
	if target.is_empty():
		_set_status("没有目标区域")
		return
	var heights := _height_range()
	var ur := get_undo_redo()
	ur.create_action("草高度应用")
	for r in target:
		ur.add_do_property(r, "height_min", heights.x)
		ur.add_do_property(r, "height_max", heights.y)
		ur.add_undo_property(r, "height_min", r.get("height_min"))
		ur.add_undo_property(r, "height_max", r.get("height_max"))
	ur.commit_action()
	_after_apply(target, "草高 %.2f~%.2f" % [heights.x, heights.y])


func _apply_density(all: bool) -> void:
	var target := _target_regions(all)
	if target.is_empty():
		_set_status("没有目标区域")
		return
	var new_density: float = _density_box.value
	var ur := get_undo_redo()
	ur.create_action("密度应用")
	for r in target:
		ur.add_do_property(r, "density", new_density)
		ur.add_undo_property(r, "density", r.get("density"))
	ur.commit_action()
	_after_apply(target, "密度 %.1f" % new_density)


func _apply_posture(all: bool) -> void:
	var target := _target_regions(all)
	if target.is_empty():
		_set_status("没有目标区域")
		return
	var tilt: float = _tilt_box.value
	var thin: float = _thin_box.value * 0.01
	var ur := get_undo_redo()
	ur.create_action("姿态胖瘦应用")
	for r in target:
		ur.add_do_property(r, "tilt_max", tilt)
		ur.add_do_property(r, "thin_variation", thin)
		ur.add_undo_property(r, "tilt_max", r.get("tilt_max"))
		ur.add_undo_property(r, "thin_variation", r.get("thin_variation"))
	ur.commit_action()
	_after_apply(target, "倾斜 ≤%.1f°、胖瘦 ±%d%%" % [tilt, int(_thin_box.value)])


func _apply_source() -> void:
	var target := _target_regions(false)
	if target.is_empty():
		_set_status("没有选中的目标区域")
		return
	var ur := get_undo_redo()
	ur.create_action("表面来源应用")
	for r in target:
		ur.add_do_property(r, "surface_source", _source_box.selected)
		ur.add_undo_property(r, "surface_source", r.get("surface_source"))
	ur.commit_action()
	_after_apply(target, "表面来源档 %d" % _source_box.selected)


func _apply_preset() -> void:
	var target := _target_regions(false)
	if target.is_empty():
		_set_status("没有选中的目标区域")
		return
	var new_preset: GrassPreset = _selected_preset()
	var new_path := _selected_preset_path()
	var ur := get_undo_redo()
	ur.create_action("草种应用")
	for r in target:
		var old_preset_value: GrassPreset = r.get("preset")
		var old_preset: GrassPreset = old_preset_value if old_preset_value != null else BUILTIN_PRESET
		var old_lo: float = r.get("height_min")
		var old_hi: float = r.get("height_max")
		var converted := LAYOUT.convert_height(old_preset.avg_natural_ratio,
			new_preset.avg_natural_ratio, old_lo, old_hi)
		ur.add_do_property(r, "preset", new_preset if new_path != "" else null)
		ur.add_do_property(r, "height_min", converted.x)
		ur.add_do_property(r, "height_max", converted.y)
		ur.add_undo_property(r, "preset", old_preset_value)
		ur.add_undo_property(r, "height_min", old_lo)
		ur.add_undo_property(r, "height_max", old_hi)
	ur.commit_action()
	_after_apply(target, "草种「%s」（草高已按比例换算）" % new_preset.preset_name)


## Shared post-apply path: rebuild if enabled, then refresh gizmos
func _after_apply(target: Array, what: String) -> void:
	if _busy:
		return
	if _auto_rebuild_box.button_pressed:
		var res := await _frame_rebuild(target, what, true)
		_gizmo_refresh_all(target)
		_set_status("%s 已应用：重建 %d，跳过 %d%s" % [
			what, res["done"], res["skipped"], "，已中止" if res["aborted"] else ""])
	else:
		_gizmo_refresh_all(target)
		_set_status("%s 已应用到 %d 个区域，未重建（Ctrl+Z）" % [what, target.size()])


# ---- common helpers ----

func _target_regions(all: bool) -> Array:
	if all:
		return _all_regions(get_editor_interface().get_edited_scene_root())
	var out: Array = []
	for n in get_editor_interface().get_selection().get_selected_nodes():
		if n.get_script() == REGION_SCRIPT:
			out.append(n)
	return out


func _gizmo_refresh_all(regions: Array) -> void:
	for r in regions:
		if is_instance_valid(r):
			_gizmo.refresh_region(r)


# ================= Common confirm dialog =================

func _confirm_common(title_text: String, text: String, ok_cb: Callable,
		cancel_cb: Callable = Callable()) -> void:
	if _common_confirm == null:
		_common_confirm = ConfirmationDialog.new()
		get_editor_interface().get_base_control().add_child(_common_confirm)
	_common_confirm.title = title_text
	_common_confirm.dialog_text = text
	for c in _common_confirm.confirmed.get_connections():
		_common_confirm.confirmed.disconnect(c["callable"])
	for c in _common_confirm.canceled.get_connections():
		_common_confirm.canceled.disconnect(c["callable"])
	_common_confirm.confirmed.connect(func() -> void: ok_cb.call())
	if cancel_cb.is_valid():
		_common_confirm.canceled.connect(func() -> void: cancel_cb.call())
	_common_confirm.popup_centered()


# ================= Global shader param =================

var _session_param_added := false

func _ensure_global_shader_param() -> void:
	# RenderingServer has no "has parameter" query; guard the session with a member flag.
	if _session_param_added:
		return
	_session_param_added = true
	var key := "shader_globals/grass_player_pos"
	# If the project already defines it, the engine loaded it at startup — nothing to do.
	if ProjectSettings.has_setting(key):
		return
	# Session: add immediately so shaders work without a restart
	RenderingServer.global_shader_parameter_add(
		"grass_player_pos", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
	# Persist once; never removed when the plugin is disabled (avoid deleting user config)
	ProjectSettings.set_setting(key, {"type": TYPE_VECTOR3, "value": Vector3.ZERO})
	var err := ProjectSettings.save()
	if err != OK:
		push_warning("Grass Painter: project settings save failed (%d)" % err)


# ================= Region cache / traversal =================

func _all_regions(root: Node) -> Array:
	var out: Array = []
	if root != null and root.get_script() == REGION_SCRIPT:
		out.append(root)
	if root != null:
		for c in root.get_children():
			out.append_array(_all_regions(c))
	return out


func _refresh_region_cache() -> void:
	_region_cache = []
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	for r in _all_regions(scene_root):
		var region_size: Vector3 = r.get("size")
		_region_cache.append({"region": r,
			"half_x": region_size.x * 0.5, "half_z": region_size.z * 0.5})


## 0 = free; 1 = existing region; 2 = same-batch placeholder
func _cache_code(world_point: Vector3, margin: float) -> int:
	for e in _region_cache:
		if e.has("pending"):
			var p: Vector3 = e["pending"]
			if absf(p.x - world_point.x) <= float(e["half_x"]) - margin \
					and absf(p.z - world_point.z) <= float(e["half_z"]) - margin:
				return 2
			continue
		var region: Node3D = e["region"]
		if not is_instance_valid(region):
			continue
		var local: Vector3 = region.to_local(world_point)
		if absf(local.x) <= float(e["half_x"]) - margin \
				and absf(local.z) <= float(e["half_z"]) - margin:
			return 1
	return 0


func _find_region(root: Node, world_point: Vector3, margin: float) -> Node3D:
	if not _region_cache.is_empty():
		for e in _region_cache:
			if e.has("pending"):
				continue
			var region: Node3D = e["region"]
			if not is_instance_valid(region):
				continue
			var local: Vector3 = region.to_local(world_point)
			if absf(local.x) <= float(e["half_x"]) - margin \
					and absf(local.z) <= float(e["half_z"]) - margin:
				return region
		return null
	for r in _all_regions(root):
		var region_size: Vector3 = r.get("size")
		var local: Vector3 = r.to_local(world_point)
		if absf(local.x) <= region_size.x * 0.5 - margin \
				and absf(local.z) <= region_size.z * 0.5 - margin:
			return r
	return null


func _attach_owner(region: Node, scene_root: Node) -> void:
	if scene_root == null:
		return
	for c in region.get_children():
		if c.owner == null:
			c.owner = scene_root


func _scene_valid(scene_root: Node) -> bool:
	return is_instance_valid(scene_root) and scene_root.is_inside_tree() \
		and get_editor_interface().get_edited_scene_root() == scene_root


# ================= Temp preview =================

func _make_preview_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.no_depth_test = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _ensure_preview() -> MeshInstance3D:
	if is_instance_valid(_preview_mi):
		return _preview_mi
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return null
	var imm := ImmediateMesh.new()
	_preview_mi = MeshInstance3D.new()
	_preview_mi.mesh = imm
	_preview_mi.top_level = true
	_preview_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene_root.add_child(_preview_mi)
	return _preview_mi


func _close_preview() -> void:
	_pen_circles = []
	if is_instance_valid(_preview_mi):
		_preview_mi.queue_free()
	_preview_mi = null


func _imm() -> ImmediateMesh:
	var mi := _ensure_preview()
	if mi == null:
		return null
	return mi.mesh as ImmediateMesh


func _line(imm: ImmediateMesh, a: Vector3, b: Vector3, col: Color) -> void:
	imm.surface_set_color(col)
	imm.surface_add_vertex(a)
	imm.surface_add_vertex(b)


## Drag preview: batch = border + grid crosses; box erase = red border only
func _draw_drag_box(a: Vector3, b: Vector3, erase: bool = false) -> void:
	var imm := _imm()
	if imm == null:
		return
	imm.surface_clear()
	imm.surface_begin(Mesh.PRIMITIVE_LINES, _preview_mat)
	var y := (a.y + b.y) * 0.5 + 0.03
	var minx := minf(a.x, b.x)
	var maxx := maxf(a.x, b.x)
	var minz := minf(a.z, b.z)
	var maxz := maxf(a.z, b.z)
	var border := Color(0.95, 0.55, 0.5, 0.9) if erase else Color(0.75, 0.95, 0.85, 0.9)
	_line(imm, Vector3(minx, y, minz), Vector3(maxx, y, minz), border)
	_line(imm, Vector3(maxx, y, minz), Vector3(maxx, y, maxz), border)
	_line(imm, Vector3(maxx, y, maxz), Vector3(minx, y, maxz), border)
	_line(imm, Vector3(minx, y, maxz), Vector3(minx, y, minz), border)
	if not erase:
		var center := Vector2((a.x + b.x) * 0.5, (a.z + b.z) * 0.5)
		var half := Vector2(absf(a.x - b.x) * 0.5, absf(a.z - b.z) * 0.5)
		var points := LAYOUT.grid_points(center, half, _size_box.value)
		if points.size() <= PREVIEW_GRID_LIMIT:
			var t := maxf(0.12, _size_box.value * 0.06)
			var grid_col := Color(0.65, 0.85, 0.75, 0.55)
			for p in points:
				_line(imm, Vector3(p.x - t, y, p.y), Vector3(p.x + t, y, p.y), grid_col)
				_line(imm, Vector3(p.x, y, p.y - t), Vector3(p.x, y, p.y + t), grid_col)
	imm.surface_end()


## Pen preview: all pen circles (orange) + hover circle (light blue)
func _redraw_pen_circles() -> void:
	var imm := _imm()
	if imm == null:
		return
	imm.surface_clear()
	imm.surface_begin(Mesh.PRIMITIVE_LINES, _preview_mat)
	var col := Color(0.95, 0.6, 0.35, 0.85)
	for circle in _pen_circles:
		var c: Vector3 = (circle["point"] as Vector3) + Vector3(0.0, 0.03, 0.0)
		var r: float = circle["r"]
		var prev := c + Vector3(r, 0.0, 0.0)
		for i in range(1, CIRCLE_STEPS + 1):
			var ang := TAU * float(i) / CIRCLE_STEPS
			var cur := c + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
			_line(imm, prev, cur, col)
			prev = cur
	if _hover_point != null:
		var hc: Vector3 = (_hover_point["point"] as Vector3) + Vector3(0.0, 0.03, 0.0)
		var hr: float = _hover_point["r"]
		var hprev := hc + Vector3(hr, 0.0, 0.0)
		var hcol := Color(0.75, 0.85, 1.0, 0.6)
		for i in range(1, CIRCLE_STEPS + 1):
			var ang := TAU * float(i) / CIRCLE_STEPS
			var hcur := hc + Vector3(cos(ang) * hr, 0.0, sin(ang) * hr)
			_line(imm, hprev, hcur, hcol)
			hprev = hcur
	imm.surface_end()


# ================= Reset =================

func _reset_drag() -> void:
	_dragging = false
	_pen_active = false
	_pen_region = null
	_swallow = false
	_hover_point = null
	_index = null
	_close_preview()


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text
