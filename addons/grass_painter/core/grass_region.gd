@tool
@icon("res://addons/grass_painter/icon.svg")
class_name GrassRegion
extends Node3D
## Region-scattered GPU grass: jittered grid sampling, top-down raycast ground snapping,
## fills MultiMesh layers. Works with CSG / baked meshes / any StaticBody (collision mask),
## plus visible-mesh fallback for collider-only visual ground.
## Geometry/material come from a GrassPreset (procedural blades or external meshes).
## Player bending uses the global shader parameter grass_player_pos.

# ---- Layer / mesh constants ----
const MM_PREFIX := "GP_MM_"
const FAR_PREFIX := 100
const _PROC_SHADER := preload("res://addons/grass_painter/shaders/grass_procedural.gdshader")
const _SCAN_SHADER := preload("res://addons/grass_painter/shaders/grass_scan.gdshader")
const _LEAF_MESH := preload("res://addons/grass_painter/core/grass_leaf_mesh.gd")
const _MeshSurface := preload("res://addons/grass_painter/core/mesh_surface.gd")
const _FALLBACK_PRESET := preload("res://addons/grass_painter/presets/grass_default_procedural.tres")
const FIXED_SEEDS := [7011, 7027, 7039, 7043, 7057, 7069, 7079, 7087]
const BURY_DEPTH := 0.008
const DRY_TIP_RATIO := 0.18

# ---- Bake hooks (real renderer can rebuild & save; dummy renderer cannot bake buffers) ----
const BAKE_FLAG := "user://grass_painter/_bake.flag"
const BAKE_LOG := "user://grass_painter/_bake.log"

# ================= Exports =================

@export_group("Region")
## XZ = scattering range; raycast starts raycast_height above the node
@export var size: Vector3 = Vector3(4.0, 1.0, 4.0)
@export_range(0.2, 10.0, 0.1, "suffix:m") var raycast_height: float = 1.5
## Points whose y differs from this node by more than the window are skipped
@export_range(0.05, 10.0, 0.05, "suffix:m") var height_window: float = 0.5
@export_flags_3d_physics var collision_mask: int = 0xFFFFFFFF

enum SurfaceSource { COLLISION_ONLY, COLLISION_FIRST, HIGHEST, MESH_FIRST }

@export_group("Non-collider fallback")
@export var surface_source: SurfaceSource = SurfaceSource.COLLISION_FIRST
## Visible mesh whose name (with ancestors) contains one of these is skipped
@export var excluded_mesh_names: Array[String] = []
## Per-mesh triangle limit: heavier meshes skipped (avoid eating heavy props)
@export_range(0, 200000, 1000) var mesh_face_limit: int = 30000
## Collider whose own name starts with this prefix is skipped
@export var excluded_node_prefix: String = ""

@export_group("Grass")
## Grass preset; null = built-in procedural default
@export var preset: GrassPreset = null
@export_range(0.5, 60.0, 0.5, "suffix:per m2") var density: float = 10.0
@export var seed: int = 7
## Rotate the sampling grid by a seed-derived angle to break axis-aligned rows
@export var degrid_rotation: bool = true
@export_range(0.0, 90.0, 1.0, "suffix:deg") var degrid_angle: float = 45.0
@export_range(0.02, 3.0, 0.01, "suffix:m") var height_min: float = 0.12
@export_range(0.02, 3.0, 0.01, "suffix:m") var height_max: float = 0.20
@export_range(0.0, 30.0, 0.5, "suffix:deg") var tilt_max: float = 12.0
@export_range(0.0, 0.5, 0.01) var thin_variation: float = 0.25
@export_range(0.0, 1.0, 0.01) var normal_slope_threshold: float = 0.75
## Exclusion circles written by the painter: (center local x, z, radius)
@export var exclusion_circles: Array[Vector3] = []
## Rebuild on game start (clear old layers then build)
@export var rebuild_on_start: bool = false

@export_group("Actions")
@export var do_rebuild: bool:
	set(v):
		do_rebuild = false
		if v:
			build()
@export var do_clear: bool:
	set(v):
		do_clear = false
		if v:
			clear_grass()

# ================= Preset access =================

## Effective preset: own preset if assigned, otherwise the built-in procedural default.
func get_preset() -> GrassPreset:
	return preset if preset != null else _FALLBACK_PRESET


# ================= Runtime/debug data =================

## Last generated instance data, in scatter order (dummy renderer makes MultiMesh
## set/get no-op, so instance-level assertions must read these, not the MultiMesh).
var last_transforms: Array[Transform3D] = []
var last_custom: Array[Color] = []
var last_variants: Array[int] = []
## Sample points that were served by the visible-mesh fallback (diagnostics)
var last_fallback_hits: int = 0

## Visual mesh index used during build(); reset per build
var _index = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if FileAccess.file_exists(BAKE_FLAG):
		_runtime_bake.call_deferred()
	elif rebuild_on_start:
		_runtime_rebuild.call_deferred()


func _runtime_rebuild() -> void:
	clear_grass()
	await get_tree().process_frame   # queue_free applies at frame end
	build()


func _runtime_bake() -> void:
	# Triggered only by BAKE_FLAG: rebuild in a real-rendered game and pack the scene
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	clear_grass()
	await get_tree().process_frame
	build()
	await get_tree().process_frame
	var ok := true
	var msg := ""
	var total := 0
	for child in get_children():
		var mmi := child as MultiMeshInstance3D
		if mmi == null or mmi.multimesh == null:
			continue
		var cnt := mmi.multimesh.instance_count
		if cnt > 0 and mmi.multimesh.get_instance_transform(0) == Transform3D.IDENTITY:
			ok = false
			msg = "layer %s buffer empty (dummy renderer?)" % child.name
			break
		total += cnt
	if ok and total <= 0:
		ok = false
		msg = "zero instances"
	var scene_path := ""
	if ok:
		rebuild_on_start = false
		var scene_root := get_tree().current_scene
		for child in get_children():
			if child is MultiMeshInstance3D and String(child.name).begins_with(MM_PREFIX):
				child.owner = scene_root
		scene_path = scene_root.scene_file_path
		var packed := PackedScene.new()
		var err := packed.pack(scene_root)
		if err == OK:
			err = ResourceSaver.save(packed, scene_path)
		if err != OK:
			ok = false
			msg = "pack/save error %d (%s)" % [err, scene_path]
	DirAccess.make_dir_recursive_absolute("user://grass_painter")
	var f := FileAccess.open(BAKE_LOG, FileAccess.WRITE)
	if f != null:
		f.store_string(("PASS runtime bake: %d clumps -> %s" % [total, scene_path]) if ok else ("FAIL " + msg))
		f.close()
	var d := DirAccess.open("user://grass_painter")
	if d != null:
		d.remove("_bake.flag")
	get_tree().quit(0 if ok else 1)


# ================= Build =================

## external_index: shared MeshSurface index injected by the plugin; null = lazily self-built.
func build(external_index = null) -> void:
	if not is_inside_tree():
		push_error("GrassRegion \"%s\": build() outside the tree" % name)
		return
	var start_ms := Time.get_ticks_msec()
	var layers := _get_or_create_layers()
	var p := get_preset()
	var nv := p.variant_count()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var space := get_world_3d().direct_space_state
	# Physics query reused for the whole build; from/to overwritten in the loop
	var ray_q := PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3.DOWN, collision_mask)
	var cell := 1.0 / sqrt(maxf(density, 0.001))
	# Grid geometry: the rotated path traverses a square of the diagonal half-extent (clips
	# the rectangle); the plain path uses x/z sizes directly
	var grid_angle := 0.0
	var grid_cos := 1.0
	var grid_sin := 0.0
	var rotating := degrid_rotation and degrid_angle > 0.0
	var half_x := size.x * 0.5
	var half_z := size.z * 0.5
	var nx := 0
	var nz := 0
	if rotating:
		var ang_rng := RandomNumberGenerator.new()
		ang_rng.seed = _angle_seed(seed)
		grid_angle = deg_to_rad(ang_rng.randf_range(0.0, degrid_angle))
		grid_cos = cos(grid_angle)
		grid_sin = sin(grid_angle)
		var cover := sqrt(size.x * size.x + size.z * size.z) * 0.5
		nx = maxi(1, int(ceil(cover * 2.0 / cell)))
		nz = nx
		half_x = cover
		half_z = cover
	else:
		nx = maxi(1, int(ceil(size.x / cell)))
		nz = maxi(1, int(ceil(size.z / cell)))
	var inv := global_transform.affine_inverse()
	_index = external_index
	last_fallback_hits = 0
	# Per-variant buckets (near variants only; far layers share the bucket)
	var tfs: Array[Transform3D] = []
	var cus: Array[Color] = []
	var variants: Array[int] = []
	var per_tf: Array[Array] = []
	var per_cu: Array[Array] = []
	for vi in nv:
		per_tf.append([])
		per_cu.append([])
	for i in nx:
		for j in nz:
			var lx: float
			var lz: float
			if rotating:
				# Jittered point in the cover square; both axes consume one randf
				var gx := (float(i) + rng.randf()) * cell - half_x
				var gz := (float(j) + rng.randf()) * cell - half_z
				# Rotate into local frame, clip points outside the rectangle
				lx = gx * grid_cos - gz * grid_sin
				lz = gx * grid_sin + gz * grid_cos
				if lx < -size.x * 0.5 or lx > size.x * 0.5 or lz < -size.z * 0.5 or lz > size.z * 0.5:
					continue
			else:
				lx = clampf((float(i) + rng.randf()) * cell - size.x * 0.5, -size.x * 0.5, size.x * 0.5)
				lz = clampf((float(j) + rng.randf()) * cell - size.z * 0.5, -size.z * 0.5, size.z * 0.5)
			# Scatter box is local XZ (follows node rotation); transform to world
			var from := global_transform * Vector3(lx, raycast_height, lz)
			var bottom_y := from.y - (raycast_height + 2.0)
			ray_q.from = from
			ray_q.to = Vector3(from.x, bottom_y, from.z)
			var hit := space.intersect_ray(ray_q)
			var land := Vector3.ZERO
			var normal := Vector3.UP
			var used_fallback := false
			var physics_hit := not hit.is_empty()
			var mesh_hit := false
			var mesh_point := Vector3.ZERO
			var mesh_normal := Vector3.UP
			# COLLISION_FIRST: query mesh only on physics miss; HIGHEST: both; MESH_FIRST: mesh wins
			if physics_hit or surface_source != SurfaceSource.COLLISION_ONLY:
				if (not physics_hit) or surface_source == SurfaceSource.HIGHEST \
						or surface_source == SurfaceSource.MESH_FIRST:
					_ensure_mesh_index()
					if _index != null:
						var m: Dictionary = _index.hit_down(from.x, from.z, from.y, bottom_y)
						if not m.is_empty():
							mesh_hit = true
							mesh_point = m["position"]
							mesh_normal = m["normal"]
			if surface_source == SurfaceSource.MESH_FIRST and mesh_hit:
				land = mesh_point
				normal = mesh_normal
				used_fallback = true
			elif physics_hit and mesh_hit and surface_source == SurfaceSource.HIGHEST \
					and mesh_point.y > hit.position.y:
				land = mesh_point
				normal = mesh_normal
				used_fallback = true
			elif physics_hit:
				land = hit.position
				normal = hit.normal
			elif mesh_hit:
				land = mesh_point
				normal = mesh_normal
				used_fallback = true
			else:
				continue
			if normal.y < normal_slope_threshold:
				continue
			# Fallback exclusion was applied at index-build time (name with ancestors);
			# physics path checks the collider prefix
			if not used_fallback and not hit.is_empty() and _hit_excluded(hit.collider):
				continue
			if hit_exclusion_circles(lx, lz):
				continue
			if absf((land - global_position).y) > height_window:
				continue
			if used_fallback:
				last_fallback_hits += 1
			var yaw := rng.randf() * TAU
			var h := rng.randf_range(height_min, height_max)
			var variant: int = rng.randi_range(0, nv - 1)
			# Dry/stubble variants (preset personality "dry") get kind=1: straw tint,
			# barely any wind; they never also roll the green-leaf dry-tip dice
			var kind := 1 if p.variant_dry(variant) else 0
			var dry := 0.0
			if kind == 0 and rng.randf() < DRY_TIP_RATIO:
				dry = rng.randf_range(0.45, 1.0)
			# Personalized posture: random tilt around a random horizontal axis; thin is
			# independent of height. World order R_y(yaw)·R_tilt·S
			var thin := 1.0 + rng.randf_range(-thin_variation, thin_variation)
			var basis := Basis(Vector3.UP, yaw)
			if tilt_max > 0.0:
				var tilt := deg_to_rad(rng.randf() * tilt_max)
				var tdir := rng.randf() * TAU
				basis = basis * Basis(Vector3(cos(tdir), 0.0, sin(tdir)), tilt)
			# Local scale (right-multiply): non-uniform scale must not amplify tilt
			basis = basis * Basis.from_scale(Vector3(thin * h, h, thin * h))
			var world_tf := Transform3D(basis, land - normal * BURY_DEPTH)
			var local_tf := inv * world_tf
			# Custom: x seed / y orientation / z dry tip / w kind (0 = grass, 1 = dry stubble)
			var cu := Color(rng.randf(), yaw / TAU, dry, float(kind))
			tfs.append(local_tf)
			cus.append(cu)
			variants.append(variant)
			per_tf[variant].append(local_tf)
			per_cu[variant].append(cu)
	# Batch write (O(n)): build arrays, set count then buffer once
	var aabb := cull_aabb()
	for k in layers.size():
		var far_layer: bool = k >= nv
		var vi: int = k - nv if far_layer else k
		var bucket_tf: Array = per_tf[vi]
		var bucket_cu: Array = per_cu[vi]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = _variant_mesh(p, vi, far_layer)
		var buf := _pack_instance_buffer(bucket_tf, bucket_cu)
		_set_layer_buffer(mm, bucket_tf.size(), buf, aabb)
		layers[k].multimesh = mm
	# Debug copies of the instance data (probes / editor diagnostics); skipped in
	# release runs — they mirror the MultiMesh buffers and would sit in memory forever
	# (each stripped-baking region rebuilds at start and never reads them).
	if Engine.is_editor_hint() or OS.is_debug_build():
		last_transforms = tfs
		last_custom = cus
		last_variants = variants
	else:
		last_transforms = []
		last_custom = []
		last_variants = []
	if tfs.is_empty():
		var fallback_text := ""
		if surface_source != SurfaceSource.COLLISION_ONLY:
			if _index == null:
				fallback_text = "; mesh fallback not enabled or scene root missing"
			elif _index.added_faces <= 0:
				fallback_text = "; fallback indexed 0 faces (check exclusion names/visibility/face limit)"
			else:
				fallback_text = "; fallback indexed %d faces (skipped %d meshes)" % [_index.added_faces, _index.skipped_meshes]
		print_verbose("GrassRegion: 0 clumps — surface(%d), mask(%d), height window(%.2f)%s" % [
			surface_source, collision_mask, height_window, fallback_text])
	else:
		var elapsed := Time.get_ticks_msec() - start_ms
		print_verbose("GrassRegion: %d clumps (seed %d, density %.1f, fallback %d, %dms)" % [
			tfs.size(), seed, density, last_fallback_hits, elapsed])
		if elapsed > 500:
			print("GrassRegion: \"%s\" took %dms (>500ms; lower density/shrink region)" % [name, elapsed])


## MultiMesh cull AABB (local space): based on real reach of height/tilt/wind bending.
func cull_aabb() -> AABB:
	var horizontal := height_max * 0.9 + 0.08
	var top := height_max * 1.2 + 0.15
	return AABB(
		Vector3(size.x * -0.5 - horizontal, -0.05, size.z * -0.5 - horizontal),
		Vector3(size.x + horizontal * 2.0, top + 0.05, size.z + horizontal * 2.0))


## Independent seed for the grid angle (decoupled from the main rng stream)
static func _angle_seed(s: int) -> int:
	var x := int(s)
	x = (x ^ 61) ^ (x >> 16)
	x = x + (x << 3)
	x = x ^ (x >> 4)
	x = x * 0x27D4EB2D
	x = x ^ (x >> 15)
	return x


# ================= Buffer packing =================

## Pack one layer's instances into a MultiMesh buffer (16 floats per instance:
## Transform3D as 3 rows of 4 + Color 4).
## Layout verified against the engine with a real renderer (set_buffer -> get_instance_transform
## round-trip): each row is [basis_row.xyz, origin_component], i.e.
##   [b.x.x, b.y.x, b.z.x, o.x][b.x.y, b.y.y, b.z.y, o.y][b.x.z, b.y.z, b.z.z, o.z]
## A column-contiguous writing order silently scrambles every instance: the engine reads
## b.y.x as position x, which is 0 for pure yaw rotations and collapses all grass onto x=0.
static func _pack_instance_buffer(tfs: Array, cus: Array) -> PackedFloat32Array:
	var n := tfs.size()
	var buf := PackedFloat32Array()
	buf.resize(n * 16)
	var i := 0
	for k in n:
		var t: Transform3D = tfs[k]
		var c: Color = cus[k]
		var b: Basis = t.basis
		var o: Vector3 = t.origin
		buf[i] = b.x.x
		buf[i + 1] = b.y.x
		buf[i + 2] = b.z.x
		buf[i + 3] = o.x
		buf[i + 4] = b.x.y
		buf[i + 5] = b.y.y
		buf[i + 6] = b.z.y
		buf[i + 7] = o.y
		buf[i + 8] = b.x.z
		buf[i + 9] = b.y.z
		buf[i + 10] = b.z.z
		buf[i + 11] = o.z
		buf[i + 12] = c.r
		buf[i + 13] = c.g
		buf[i + 14] = c.b
		buf[i + 15] = c.a
		i += 16
	return buf


## Write one layer: count first, then buffer once; 0-instance layers set count only.
static func _set_layer_buffer(mm: MultiMesh, n: int, buf: PackedFloat32Array, aabb: AABB) -> void:
	mm.instance_count = n
	if n > 0:
		mm.set_buffer(buf)
	mm.custom_aabb = aabb


# ================= Per-variant meshes =================

static var _proc_mesh_cache: Dictionary = {}

## Procedural variant mesh: fixed seed per variant (mesh is region-independent; the
## variation comes from instance yaw/tilt/thin/custom), cached per [preset, vi].
static func _procedural_mesh(p: GrassPreset, vi: int) -> Mesh:
	var cache_key := [p, vi]
	if _proc_mesh_cache.has(cache_key):
		return _proc_mesh_cache[cache_key]
	var fixed_seed: int = FIXED_SEEDS[vi % FIXED_SEEDS.size()]
	var personality: Dictionary = p.personalities[vi]
	var out: Mesh = _LEAF_MESH.build_variant_mesh(personality, fixed_seed)
	_proc_mesh_cache[cache_key] = out
	return out


static var _asset_mesh_cache: Dictionary = {}

## External asset -> Mesh. PackedScene: merge all MeshInstance children (bottom-align
## and center at zero, height NOT normalized); Mesh: used as-is. Cached per resource.
static func _asset_to_mesh(res: Resource) -> Mesh:
	if res == null:
		return null
	var key: int = res.get_instance_id()
	if _asset_mesh_cache.has(key):
		return _asset_mesh_cache[key]
	if res is Mesh:
		_asset_mesh_cache[key] = res
		return res
	var out: Mesh = null
	if res is PackedScene:
		var inst: Node3D = res.instantiate()
		var verts := PackedVector3Array()
		var norms := PackedVector3Array()
		var uvs := PackedVector2Array()
		var indices := PackedInt32Array()
		var stack: Array = [[inst, Transform3D.IDENTITY]]
		while not stack.is_empty():
			var item: Array = stack.pop_back()
			var cur: Node = item[0]
			var accumulated: Transform3D = item[1]
			if cur is MeshInstance3D:
				var mi := cur as MeshInstance3D
				if mi.mesh != null:
					var xf: Transform3D = accumulated * mi.transform
					var base := verts.size()
					for si in mi.mesh.get_surface_count():
						var arr := mi.mesh.surface_get_arrays(si)
						if arr == null or arr[Mesh.ARRAY_VERTEX] == null:
							continue
						var v0: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
						var n0: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
						var u0: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
						var i0: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
						for k in v0.size():
							verts.append(xf * v0[k])
							norms.append((xf.basis.inverse().transposed() * n0[k]).normalized() if k < n0.size() else Vector3.UP)
							uvs.append(u0[k] if k < u0.size() else Vector2.ZERO)
						if i0.is_empty():
							for k in range(0, v0.size(), 3):
								indices.append_array([base + k, base + k + 1, base + k + 2])
						else:
							for k in i0.size():
								indices.append(base + i0[k])
			for c in cur.get_children():
				stack.append([c, accumulated * (c as Node3D).transform if c is Node3D else accumulated])
		inst.free()
		if verts.size() >= 3:
			var lo := verts[0]
			var hi := verts[0]
			for v in verts:
				lo = lo.min(v)
				hi = hi.max(v)
			var shift := Vector3(-(lo.x + hi.x) * 0.5, -lo.y, -(lo.z + hi.z) * 0.5)
			for i in verts.size():
				verts[i] += shift
			var natural_h := maxf(hi.y - lo.y, 0.001)
			var new_mesh := ArrayMesh.new()
			var arrays: Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = verts
			arrays[Mesh.ARRAY_NORMAL] = norms
			arrays[Mesh.ARRAY_TEX_UV] = uvs
			arrays[Mesh.ARRAY_INDEX] = indices
			new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			new_mesh.custom_aabb = AABB(Vector3(-1.5, -0.2, -1.5), Vector3(3.0, natural_h + 0.4, 3.0))
			out = new_mesh
	_asset_mesh_cache[key] = out
	return out


## Mesh for one variant (near/far)
func _variant_mesh(p: GrassPreset, vi: int, far: bool) -> Mesh:
	if p.is_procedural:
		return _procedural_mesh(p, vi)
	return _asset_to_mesh(p.source_asset(vi, far))


# ================= Layers =================

func _get_or_create_layers() -> Array[MultiMeshInstance3D]:
	var p := get_preset()
	var nv := p.variant_count()
	var use_far := p.has_far_lod()
	var total := nv + (nv if use_far else 0)
	var layers: Array[MultiMeshInstance3D] = []
	# Remove layers left over from a previous preset (variant count shrunk / far LOD
	# dropped): they keep rendering stale grass with the old preset's mesh and ranges.
	for child in get_children():
		if child is MultiMeshInstance3D and String(child.name).begins_with(MM_PREFIX):
			var id := int(String(child.name).trim_prefix(MM_PREFIX))
			if id >= total:
				child.queue_free()
	for k in total:
		var far := k >= nv
		var vi := k - nv if far else k
		var node_id := FAR_PREFIX + vi if far else vi
		var n := get_node_or_null(NodePath(MM_PREFIX + str(node_id))) as MultiMeshInstance3D
		if n == null:
			n = MultiMeshInstance3D.new()
			n.name = MM_PREFIX + str(node_id)
			add_child(n)
			if Engine.is_editor_hint() and get_tree().edited_scene_root != null:
				n.owner = get_tree().edited_scene_root
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var range_d: float = p.lod_switch_distance
		if use_far:
			if far:
				n.visibility_range_begin = range_d
				n.visibility_range_begin_margin = 2.0
				n.visibility_range_end = 0.0
			else:
				n.visibility_range_end = range_d
				n.visibility_range_end_margin = 2.0
				n.visibility_range_begin = 0.0
		else:
			n.visibility_range_begin = 0.0
			n.visibility_range_end = 0.0
		n.material_override = _shared_material(p)
		layers.append(n)
	return layers


static var _shared_mats: Dictionary = {}   # preset -> ShaderMaterial, session scoped

static func _shared_material(p: GrassPreset) -> ShaderMaterial:
	if not _shared_mats.has(p):
		_shared_mats[p] = ShaderMaterial.new()
	# Refresh every call (idempotent): editing a preset's shader/textures in the
	# Inspector must take effect on rebuild without an editor restart.
	var m: ShaderMaterial = _shared_mats[p]
	m.shader = p.get_shader(_PROC_SHADER, _SCAN_SHADER)
	if not p.is_procedural and p.shader_kind == GrassPreset.ShaderKind.SCAN:
		m.set_shader_parameter("base_tex", p.albedo_texture)
		m.set_shader_parameter("normal_tex", p.normal_texture)
		m.set_shader_parameter("translucency_tex", p.trans_texture)
	return m


# ================= Visual mesh index =================

func _ensure_mesh_index() -> void:
	if _index != null:
		return
	var root := _mesh_root()
	if root == null:
		return
	_index = _MeshSurface.new()
	_index.build(root, _mesh_range(), _excluded_names(), true, mesh_face_limit)


func _mesh_root() -> Node:
	var t := get_tree()
	if t == null:
		return null
	if Engine.is_editor_hint() and t.edited_scene_root != null:
		return t.edited_scene_root
	if t.current_scene != null:
		return t.current_scene
	return t.root


## World AABB for the mesh index: region XZ plus the y band of raycast/height window
func _mesh_range() -> AABB:
	var local := AABB(
		Vector3(size.x * -0.5, -height_window - 2.0, size.z * -0.5),
		Vector3(size.x, raycast_height + height_window + 4.0, size.z))
	return global_transform * local


## Excluded names for visible meshes: node prefix + mesh names, deduped
func _excluded_names() -> Array:
	var out: Array = []
	if excluded_node_prefix != "":
		out.append(excluded_node_prefix)
	for n in excluded_mesh_names:
		if n != "" and not out.has(n):
			out.append(n)
	return out


# ================= Clear / exclusion helpers =================

func clear_grass() -> void:
	for child in get_children():
		var n := child as Node3D
		if n != null and String(n.name).begins_with(MM_PREFIX):
			n.queue_free()


func _hit_excluded(col: Object) -> bool:
	if excluded_node_prefix.is_empty():
		return false   # begins_with("") is always true and would kill all physics hits
	var node := col as Node
	while node != null:
		if String(node.name).begins_with(excluded_node_prefix):
			return true
		var parent := node.get_parent()
		node = null if parent is Window else parent
	return false


func hit_exclusion_circles(local_x: float, local_z: float) -> bool:
	for c in exclusion_circles:
		var dx := local_x - c.x
		var dz := local_z - c.y
		if dx * dx + dz * dz <= c.z * c.z:
			return true
	return false


## Painter call: add a circle (a circle within 0.5×max(radius) counts as duplicate).
func add_exclusion_circle(local_x: float, local_z: float, radius: float) -> bool:
	# Copy-on-write: never append in place — UndoRedo's do value is the same Array
	# instance the node currently references
	var table: Array[Vector3] = exclusion_circles.duplicate()
	for i in table.size():
		var dx := local_x - table[i].x
		var dz := local_z - table[i].y
		var neighbor := maxf(table[i].z, radius) * 0.5
		if dx * dx + dz * dz <= neighbor * neighbor:
			return false
	table.append(Vector3(local_x, local_z, radius))
	exclusion_circles = table
	return true


## Painter call: delete the first circle containing this point
func remove_exclusion_circle(local_x: float, local_z: float) -> bool:
	var table: Array[Vector3] = exclusion_circles.duplicate()
	for i in table.size():
		var dx := local_x - table[i].x
		var dz := local_z - table[i].y
		if dx * dx + dz <= table[i].z * table[i].z:
			table.remove_at(i)
			exclusion_circles = table
			return true
	return false
