@tool
extends EditorNode3DGizmoPlugin
## Draws the region border (green-white) and exclusion circles (orange) for selected
## GrassRegion nodes. In Godot 4.6 add_lines takes a Material (color is per material),
## so two materials are registered. Property changes via UndoRedo do not reliably
## trigger a redraw; the plugin calls refresh_region() after every operation.

const MAT_BORDER := "gp_border"
const MAT_CIRCLE := "gp_circle"


func _init() -> void:
	add_material(MAT_BORDER, _make_line_material(Color(0.75, 0.95, 0.85, 0.9)))
	add_material(MAT_CIRCLE, _make_line_material(Color(0.95, 0.6, 0.35, 0.9)))


func _make_line_material(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	return m


var _gizmo_map: Dictionary = {}   # node -> EditorNode3DGizmo (for active redraw)


func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is GrassRegion


func _get_gizmo_name() -> String:
	return "GrassRegion"


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	var r := gizmo.get_node_3d() as GrassRegion
	if r == null:
		return
	_gizmo_map[r] = gizmo   # keep for refresh_region
	# Drop keys of freed nodes (plain Del in the scene dock bypasses forget_region)
	for k in _gizmo_map.keys():
		if not is_instance_valid(k):
			_gizmo_map.erase(k)
	var s: Vector3 = r.size
	var hx := s.x * 0.5
	var hz := s.z * 0.5

	# --- border lines ---
	var border_verts := PackedVector3Array()
	var corners := [
		r.global_transform * Vector3(-hx, 0.0, -hz),
		r.global_transform * Vector3(hx, 0.0, -hz),
		r.global_transform * Vector3(hx, 0.0, hz),
		r.global_transform * Vector3(-hx, 0.0, hz)]
	for i in 4:
		border_verts.append(corners[i])
		border_verts.append(corners[(i + 1) % 4])
	gizmo.add_lines(border_verts, get_material(MAT_BORDER))

	# --- exclusion circle lines ---
	var circle_verts := PackedVector3Array()
	for c in r.exclusion_circles:
		var cc := r.global_transform * Vector3(c.x, 0.03, c.y)
		var steps := 32
		for i in steps:
			var a0 := TAU * float(i) / steps
			var a1 := TAU * float(i + 1) / steps
			circle_verts.append(cc + Vector3(cos(a0) * c.z, 0.0, sin(a0) * c.z))
			circle_verts.append(cc + Vector3(cos(a1) * c.z, 0.0, sin(a1) * c.z))
	gizmo.add_lines(circle_verts, get_material(MAT_CIRCLE))


## Force the gizmo of a region to redraw (called by the plugin after changes)
func refresh_region(r: Node3D) -> void:
	if _gizmo_map.has(r):
		(_gizmo_map[r] as EditorNode3DGizmo).redraw()


## Remove a stale node (deleted node / plugin exit)
func forget_region(r: Node3D) -> void:
	_gizmo_map.erase(r)
