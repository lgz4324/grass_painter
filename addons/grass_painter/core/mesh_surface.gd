@tool
extends RefCounted
## Triangle index of visible meshes (non-collider ground support for the Grass Painter).
##
## Two uses, both serving the same problem: visual ground meshes without physics colliders
## cannot be hit by physics rays, so regions could neither be picked nor grow grass there:
##   1) GrassRegion surface_source COLLISION_FIRST/HIGHEST/MESH_FIRST: use the visible
##      surface as a fallback when the physics ray misses;
##   2) Editor viewport picking: place regions directly on collider-free ground.
##
## Conventions (verified on Godot 4.6):
##  - Vertices transformed to world space via global_transform; Mesh faces via Mesh.get_faces()
##  - CSGShape3D.get_meshes() returns a flat [Transform3D, Mesh, ...] array
##  - Skeleton subtrees (Skeleton3D / BoneAttachment3D / PhysicalBone3D) are skipped: skinned
##    static triangles are not trustworthy and most heavy meshes live there anyway
##  - A node whose name (or ancestor name) matches an excluded name is skipped
##  - Meshes over the face limit are skipped (avoid eating heavy props)
##  - XZ bucketing + "big triangle" list: a floor made of 2 huge faces would blow memory if
##    inserted per bucket; triangles spanning too many buckets go to the shared big list
##  - Normals flipped to the +Y side (back-facing floors also count; slope semantics hold)
## Pure logic, no editor dependency; testable headless.

const DEFAULT_EXCLUDE_NAMES: Array[String] = []
const DEFAULT_FACE_LIMIT := 30000
const BUCKET_SIZE_MIN := 0.5
const BUCKET_SIZE_MAX := 1.0   # keep buckets coarse-grained enough for big cluster ranges
const SPAN_LIMIT := 16
const BUCKET_COUNT_TARGET := 128
const FACE_CACHE_LIMIT := 64   # cap RID face cache for long editor sessions

var bucket_origin := Vector2.ZERO
var bucket_size := 1.0
var added_meshes := 0
var added_faces := 0
var skipped_meshes := 0
var skipped_faces := 0
var big_triangle_count := 0
var bounds := AABB()

var _buckets: Dictionary = {}
# Compact storage for big triangles:
# _big_triangles = contiguous triangle indices; _big_tri_floats holds 4 floats per big
# triangle (xmin,xmax,zmin,zmax), indexed by slot*4
var _big_triangles := PackedInt32Array()
var _big_tri_floats := PackedFloat32Array()
var _vertices := PackedVector3Array()   # 3 vertices per triangle, world space
var _normals := PackedVector3Array()    # 1 normal per triangle

# World-space triangle session caches. Key = [ObjectID, RID, 12 floats of Transform3D]
# (the ObjectID disambiguates RID reuse after a mesh resource is freed; the value holds
# a strong mesh reference, which also keeps the RID alive while cached). Value =
# [verts, normals] / [verts, normals]. Avoids repeated get_faces copies and per-vertex
# matrix multiplies when many regions rescan the same ground.
static var _world_cache: Dictionary = {}
const WORLD_CACHE_LIMIT := 96


# ---------- Build index ----------

## Index visible meshes under root inside the world-space aabb.
##   const MeshSurface = preload("res://addons/grass_painter/core/mesh_surface.gd")
##   var index = MeshSurface.new()
##   index.build(scene_root, aabb)
func build(root: Node, aabb: AABB, exclude_names: Array = DEFAULT_EXCLUDE_NAMES,
		skip_skeletons: bool = true, face_limit: int = DEFAULT_FACE_LIMIT) -> void:
	# Reset so the instance can be rebuilt without stacking stale data
	bucket_origin = Vector2.ZERO
	bucket_size = 1.0
	added_meshes = 0
	added_faces = 0
	skipped_meshes = 0
	skipped_faces = 0
	big_triangle_count = 0
	_buckets = {}
	_big_triangles = PackedInt32Array()
	_vertices = PackedVector3Array()
	_normals = PackedVector3Array()
	bounds = aabb
	bucket_origin = Vector2(aabb.position.x, aabb.position.z)
	# Buckets are a sparse dictionary (empty buckets cost nothing); the divisor only decides
	# bucket size, clamped to [0.5, 1.0] m for fast point queries
	bucket_size = clampf(maxf(aabb.size.x, aabb.size.z) / float(BUCKET_COUNT_TARGET),
		BUCKET_SIZE_MIN, BUCKET_SIZE_MAX)
	for e in collect(root, exclude_names, skip_skeletons):
		if not aabb.intersects(e["aabb"] as AABB):
			continue
		var mesh: Mesh = e["mesh"]
		if mesh == null:
			continue
		var faces: PackedVector3Array = _get_face_array(mesh)
		var face_count := faces.size() / 3
		if face_count <= 0:
			continue
		if face_limit > 0 and face_count > face_limit:
			skipped_meshes += 1
			skipped_faces += face_count
			continue
		added_meshes += 1
		added_faces += face_count
		var world: Array = _get_world_triangles(mesh, e["transform"] as Transform3D, faces)
		_add_in_bounds(world[0], world[1], aabb)
	_bucketize()


## Collect usable meshes: [{mesh, transform, aabb(world), name}].
## One tree traversal + AABBs only (no face reading); heavy work is done on demand.
static func collect(root: Node, exclude_names: Array = DEFAULT_EXCLUDE_NAMES,
		skip_skeletons: bool = true) -> Array:
	var out: Array = []
	_collect(root, exclude_names, skip_skeletons, out)
	return out


static func _collect(node: Node, exclude_names: Array, skip_skeletons: bool, out: Array) -> void:
	if _is_excluded(node, exclude_names, skip_skeletons):
		return
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if _is_visible(mi):
			_add_entry(out, mi.mesh, mi.global_transform, mi.name)
	elif node is CSGShape3D:
		var csg := node as CSGShape3D
		if _is_visible(csg):
			var pairs := csg.get_meshes()
			var k := 0
			while k + 1 < pairs.size():
				if pairs[k] is Transform3D and pairs[k + 1] is Mesh:
					_add_entry(out, pairs[k + 1], csg.global_transform * (pairs[k] as Transform3D), csg.name)
				k += 2
	for c in node.get_children():
		_collect(c, exclude_names, skip_skeletons, out)


static func _add_entry(out: Array, mesh: Mesh, transform: Transform3D, node_name: String) -> void:
	if mesh == null:
		return
	out.append({
		"mesh": mesh,
		"transform": transform,
		"aabb": transform * mesh.get_aabb(),
		"name": node_name,
	})


## Visibility: own visible flag, plus is_visible_in_tree when inside the tree (hidden parents)
static func _is_visible(gi: GeometryInstance3D) -> bool:
	if not gi.visible:
		return false
	if gi.is_inside_tree() and not gi.is_visible_in_tree():
		return false
	return true


## Skip the whole subtree when the node (or an ancestor) matches exclusion / is a skeleton /
## is a GrassRegion itself (its MultiMesh children must never be indexed)
static func _is_excluded(node: Node, exclude_names: Array, skip_skeletons: bool) -> bool:
	var p: Node = node
	while p != null:
		if skip_skeletons and (p is Skeleton3D or p is BoneAttachment3D or p is PhysicalBone3D):
			return true
		if _name_matches(p.name, exclude_names):
			return true
		var script: Script = p.get_script()
		if script != null and String(script.resource_path).ends_with("grass_region.gd"):
			return true
		p = p.get_parent()
	return false


static func _name_matches(node_name: String, exclude_names: Array) -> bool:
	if exclude_names == null:
		return false
	for ex in exclude_names:
		var s := String(ex)
		if s != "" and node_name.contains(s):
			return true
	return false


# ---------- Static caches ----------

# Local triangle soup session cache, keyed by ObjectID (RID alone can be reused by the
# rendering server after the mesh resource is freed). Values hold a strong mesh reference.
static var _static_face_cache: Dictionary = {}


## Mesh RID -> local triangle soup (static session cache)
static func _get_face_array(mesh: Mesh) -> PackedVector3Array:
	var id := mesh.get_instance_id()
	var cached: Variant = _static_face_cache.get(id)
	if cached is Dictionary:
		var faces: PackedVector3Array = cached["faces"]
		# An empty result may mean the mesh truly has no faces (kept, avoids re-copying)
		# or that get_faces() failed once — the mesh reference lets us distinguish nothing
		# further; either way it is stable per mesh resource.
		return faces
	if _static_face_cache.size() >= FACE_CACHE_LIMIT:
		_static_face_cache.clear()
	var faces := mesh.get_faces()
	_static_face_cache[id] = {"mesh": mesh, "faces": faces}
	return faces


## [ObjectID, RID, Transform3D] -> [world verts, normals] (static session cache).
## Auto-invalidates when the node moves/scales; degenerate normals stored as NaN.
static func _get_world_triangles(mesh: Mesh, transform: Transform3D,
		faces: PackedVector3Array) -> Array:
	var key := [mesh.get_instance_id(), mesh.get_rid(),
		transform.basis.x.x, transform.basis.x.y, transform.basis.x.z,
		transform.basis.y.x, transform.basis.y.y, transform.basis.y.z,
		transform.basis.z.x, transform.basis.z.y, transform.basis.z.z,
		transform.origin.x, transform.origin.y, transform.origin.z]
	var cached: Variant = _world_cache.get(key)
	if cached is Array:
		return cached
	if _world_cache.size() >= WORLD_CACHE_LIMIT:
		_world_cache.clear()
	var verts := PackedVector3Array()
	verts.resize(faces.size())
	var norms := PackedVector3Array()
	var k := 0
	var n := faces.size()
	while k + 2 < n:
		var a := transform * faces[k]
		var b := transform * faces[k + 1]
		var c := transform * faces[k + 2]
		verts[k] = a
		verts[k + 1] = b
		verts[k + 2] = c
		var f := (b - a).cross(c - a)
		if f.length_squared() >= 0.000000000001:
			norms.append(f.normalized())
		else:
			norms.append(Vector3(NAN, NAN, NAN))
		k += 3
	var entry := [verts, norms]
	_world_cache[key] = entry
	return entry


## Accept world-space triangles within the XZ bounds; flip back-face normals to +Y.
func _add_in_bounds(verts: PackedVector3Array, norms: PackedVector3Array, aabb: AABB) -> void:
	var k := 0
	var n := verts.size()
	while k + 2 < n:
		var a := verts[k]
		var b := verts[k + 1]
		var c := verts[k + 2]
		if not (aabb.position.x - 0.5 > maxf(a.x, maxf(b.x, c.x))
				or aabb.end.x + 0.5 < minf(a.x, minf(b.x, c.x))
				or aabb.position.z - 0.5 > maxf(a.z, maxf(b.z, c.z))
				or aabb.end.z + 0.5 < minf(a.z, minf(b.z, c.z))):
			var f: Vector3 = norms[k / 3]
			if not is_nan(f.x):
				if f.y < 0.0:
					f = -f
				_vertices.append(a)
				_vertices.append(b)
				_vertices.append(c)
				_normals.append(f)
		k += 3


func _bucketize() -> void:
	for t in _normals.size():
		var a := _vertices[t * 3]
		var b := _vertices[t * 3 + 1]
		var c := _vertices[t * 3 + 2]
		var i0 := int(floor((minf(a.x, minf(b.x, c.x)) - bucket_origin.x) / bucket_size))
		var i1 := int(floor((maxf(a.x, maxf(b.x, c.x)) - bucket_origin.x) / bucket_size))
		var j0 := int(floor((minf(a.z, minf(b.z, c.z)) - bucket_origin.y) / bucket_size))
		var j1 := int(floor((maxf(a.z, maxf(b.z, c.z)) - bucket_origin.y) / bucket_size))
		if (i1 - i0 + 1) * (j1 - j0 + 1) > SPAN_LIMIT:
			_big_triangles.append(t)
			big_triangle_count += 1
			_big_tri_floats.append(minf(a.x, minf(b.x, c.x)))
			_big_tri_floats.append(maxf(a.x, maxf(b.x, c.x)))
			_big_tri_floats.append(minf(a.z, minf(b.z, c.z)))
			_big_tri_floats.append(maxf(a.z, maxf(b.z, c.z)))
			continue
		for i in range(i0, i1 + 1):
			for j in range(j0, j1 + 1):
				var key := Vector2i(i, j)
				var column: PackedInt32Array = _buckets[key] if _buckets.has(key) else PackedInt32Array()
				column.append(t)
				_buckets[key] = column


# ---------- Queries ----------

## Highest visible surface inside the vertical column (x,z) x [bottom_y, top_y].
## Returns {position, normal} or empty. Points outside the built AABB return empty
## (the index has no triangles there; without the guard bucket indices underflow to
## far-away cells that appear to hit).
func hit_down(x: float, z: float, top_y: float, bottom_y: float) -> Dictionary:
	if x < bounds.position.x or x > bounds.end.x \
			or z < bounds.position.z or z > bounds.end.z:
		return {}
	var i := int(floor((x - bucket_origin.x) / bucket_size))
	var j := int(floor((z - bucket_origin.y) / bucket_size))
	var key := Vector2i(i, j)
	var best_y := -INF
	var result: Dictionary = {}
	if _buckets.has(key):
		var column: PackedInt32Array = _buckets[key]
		for t in column:
			var r := _test_column(t, x, z, top_y, bottom_y)
			if not r.is_empty() and (r["position"] as Vector3).y > best_y:
				best_y = (r["position"] as Vector3).y
				result = r
	for slot in _big_triangles.size():
		var t: int = _big_triangles[slot]
		var base := slot * 4
		if x < _big_tri_floats[base] or x > _big_tri_floats[base + 1] \
				or z < _big_tri_floats[base + 2] or z > _big_tri_floats[base + 3]:
			continue
		var r3 := _test_column(t, x, z, top_y, bottom_y)
		if not r3.is_empty() and (r3["position"] as Vector3).y > best_y:
			best_y = (r3["position"] as Vector3).y
			result = r3
	return result


## Intersect one triangle with the vertical line (x,z); barycentric in the XZ plane
func _test_column(t: int, x: float, z: float, top_y: float, bottom_y: float) -> Dictionary:
	var a := _vertices[t * 3]
	var b := _vertices[t * 3 + 1]
	var c := _vertices[t * 3 + 2]
	var det := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(det) < 0.000000001:
		return {}   # vertical face: XZ projection degenerates to a line
	var u := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / det
	var v := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / det
	var w := 1.0 - u - v
	if u < -0.000001 or v < -0.000001 or w < -0.000001:
		return {}
	var y := u * a.y + v * b.y + w * c.y
	if y > top_y or y < bottom_y:
		return {}
	return {"position": Vector3(x, y, z), "normal": _normals[t]}


## Collect bucket columns crossed by the ray via XZ grid DDA (old fixed stepping missed
## buckets beyond ~64 m).
func _buckets_along_ray(from: Vector3, direction: Vector3, max_dist: float) -> Array:
	var columns: Array = []
	var seen := {}
	var i := int(floor((from.x - bucket_origin.x) / bucket_size))
	var j := int(floor((from.z - bucket_origin.y) / bucket_size))
	var sx: int = 1 if direction.x > 0.0 else -1
	var sz: int = 1 if direction.z > 0.0 else -1
	var t_max_x := INF
	var t_max_z := INF
	var t_delta_x := INF
	var t_delta_z := INF
	if absf(direction.x) > 0.00000001:
		var edge_x := bucket_origin.x + float(i + (1 if direction.x > 0.0 else 0)) * bucket_size
		t_max_x = (edge_x - from.x) / direction.x
		t_delta_x = absf(bucket_size / direction.x)
	if absf(direction.z) > 0.00000001:
		var edge_z := bucket_origin.y + float(j + (1 if direction.z > 0.0 else 0)) * bucket_size
		t_max_z = (edge_z - from.z) / direction.z
		t_delta_z = absf(bucket_size / direction.z)
	var t := 0.0
	var steps := 0
	while t <= max_dist and steps < 512:
		var key := Vector2i(i, j)
		if not seen.has(key) and _buckets.has(key):
			seen[key] = true
			columns.append(_buckets[key])
		if t_max_x < t_max_z:
			t = t_max_x
			if t > max_dist:
				break
			i += sx
			t_max_x += t_delta_x
		else:
			t = t_max_z
			if t > max_dist:
				break
			j += sz
			t_max_z += t_delta_z
		steps += 1
	return columns


## Ray pick against the built index (buckets + big triangles + vertices), no recollect.
func ray_pick_direction(from: Vector3, direction: Vector3, max_dist: float) -> Dictionary:
	var result: Dictionary = {}
	var nearest := max_dist
	var columns: Array = _buckets_along_ray(from, direction, max_dist)
	for column in columns:
		for t in column:
			var r := _test_triangle(t, from, direction, nearest)
			if not r.is_empty():
				nearest = (r["position"] as Vector3).distance_to(from)
				result = r
	for slot in _big_triangles.size():
		var t2: int = _big_triangles[slot]
		var base := slot * 4
		if not _ray_2d_in_rect(from.x, from.z, direction.x, direction.z,
				_big_tri_floats[base], _big_tri_floats[base + 1],
				_big_tri_floats[base + 2], _big_tri_floats[base + 3], nearest):
			continue
		var r2 := _test_triangle(t2, from, direction, nearest)
		if not r2.is_empty():
			nearest = (r2["position"] as Vector3).distance_to(from)
			result = r2
	return result


## Whether the XZ-plane ray segment intersects the rectangle within t in [0, t_limit]
## (coarse rejection for big-triangle ray picks).
static func _ray_2d_in_rect(ox: float, oz: float, dx: float, dz: float,
		minx: float, maxx: float, minz: float, maxz: float, t_limit: float) -> bool:
	var t0 := 0.0
	var t1 := t_limit
	if absf(dx) < 0.00000001:
		if ox < minx or ox > maxx:
			return false
	else:
		var ta := (minx - ox) / dx
		var tb := (maxx - ox) / dx
		if ta > tb:
			var swap := ta
			ta = tb
			tb = swap
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return false
	if absf(dz) < 0.00000001:
		if oz < minz or oz > maxz:
			return false
	else:
		var ta2 := (minz - oz) / dz
		var tb2 := (maxz - oz) / dz
		if ta2 > tb2:
			var swap2 := ta2
			ta2 = tb2
			tb2 = swap2
		t0 = maxf(t0, ta2)
		t1 = minf(t1, tb2)
		if t0 > t1:
			return false
	return t1 >= 0.0 and t0 <= t_limit


## One triangle vs arbitrary ray (Geometry3D, double-sided); {position, normal} or empty
func _test_triangle(t: int, from: Vector3, direction: Vector3, nearest: float) -> Dictionary:
	var a := _vertices[t * 3]
	var b := _vertices[t * 3 + 1]
	var c := _vertices[t * 3 + 2]
	var hit: Variant = Geometry3D.ray_intersects_triangle(from, direction, a, b, c)
	if not (hit is Vector3):
		return {}
	var dist := ((hit as Vector3) - from).length()
	if dist <= 0.0001 or dist >= nearest:
		return {}
	return {"position": hit, "normal": _normals[t]}


## Static ray pick (editor click fallback). Returns {position, normal, collider, mesh} or empty.
static func ray_pick(root: Node, from: Vector3, direction: Vector3, max_dist: float,
		exclude_names: Array = DEFAULT_EXCLUDE_NAMES, skip_skeletons: bool = true,
		face_limit: int = DEFAULT_FACE_LIMIT) -> Dictionary:
	var candidates: Array = []
	for e in collect(root, exclude_names, skip_skeletons):
		var t := _ray_entry_t(from, direction, e["aabb"] as AABB, max_dist)
		if t >= 0.0:
			candidates.append([t, e])
	candidates.sort_custom(func(a, b): return a[0] < b[0])
	var nearest := max_dist
	var result: Dictionary = {}
	for item in candidates:
		if item[0] > nearest:
			break   # later boxes are beyond the current hit
		var e: Dictionary = item[1]
		var mesh: Mesh = e["mesh"]
		var faces: PackedVector3Array = _get_face_array(mesh)
		var face_count := faces.size() / 3
		if face_limit > 0 and face_count > face_limit:
			continue
		var transform: Transform3D = e["transform"]
		var k := 0
		while k + 2 < faces.size():
			var a := transform * faces[k]
			var b := transform * faces[k + 1]
			var c := transform * faces[k + 2]
			var hit: Variant = Geometry3D.ray_intersects_triangle(from, direction, a, b, c)
			if hit is Vector3:
				var dist := ((hit as Vector3) - from).length()
				if dist > 0.0001 and dist < nearest:
					nearest = dist
					var n := (b - a).cross(c - a)
					n = n.normalized() if n.length_squared() > 0.000000000001 else Vector3.UP
					if n.y < 0.0:
						n = -n
					result = {"position": hit, "normal": n, "collider": null, "mesh": e["name"]}
			k += 3
	return result


## Entry parameter t of the ray with the AABB (<0 = miss); slab method
static func _ray_entry_t(from: Vector3, direction: Vector3, aabb: AABB, max_dist: float) -> float:
	var t0 := 0.0
	var t1 := max_dist
	for axis in 3:
		var d: float = direction[axis]
		var o: float = from[axis]
		var lo: float = aabb.position[axis]
		var hi: float = lo + aabb.size[axis]
		if absf(d) < 0.000000001:
			if o < lo or o > hi:
				return -1.0
		else:
			var ta := (lo - o) / d
			var tb := (hi - o) / d
			if ta > tb:
				var swap := ta
				ta = tb
				tb = swap
			t0 = maxf(t0, ta)
			t1 = minf(t1, tb)
			if t0 > t1:
				return -1.0
	return t0


## Diagnostics (editor status / probe assertions)
func get_stats() -> Dictionary:
	return {
		"added_meshes": added_meshes,
		"added_faces": added_faces,
		"skipped_meshes": skipped_meshes,
		"skipped_faces": skipped_faces,
		"big_triangles": big_triangle_count,
		"buckets": _buckets.size(),
	}
