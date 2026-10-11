class_name GrassLeafMesh
extends RefCounted
## Procedural grass-clump mesh generator (no texture; removes the old white-edge texture
## problem). Nominal blade height is 1.0 m (per blade 0.60~1.08 random); instances scale
## (about 0.12~0.22) to the real height.
## Thin blades, 6 segments, V cross section (3 verts/ring), twist along the blade, random
## posture/height, serrated edges and split tips.
## Deterministic for a given seed.

const SEGMENTS := 6
const NOMINAL_MAX_WIDTH := 0.025
const CLUMP_CORE_RADIUS := 0.03
const CLUMP_SCATTER_RADIUS := 0.09
const RING_VERTS := 3   # left edge / ridge / right edge
const RANDOM_BLADE_COUNT := 0
const DRY_SEGMENTS := 4
const DRY_RING_VERTS := 2   # flat strip: left / right edge


## Entry used by GrassRegion: build the mesh for one preset personality dictionary.
## personality = {"blades": Vector2i, "spread": float, "width": float, "dry": bool(optional)}
static func build_variant_mesh(personality: Dictionary, seed_value: int) -> ArrayMesh:
	if personality.get("dry", false):
		return build_dry_stems(seed_value)
	var blades: Vector2i = personality["blades"]
	return build_clump(seed_value, RANDOM_BLADE_COUNT, blades.x, blades.y,
		personality["spread"], personality["width"])


## blade_count=0 → random in [blade_min, blade_max] (variant layers give different ranges
## for inter-layer "personality"); explicit n stays deterministic. spread_factor scales the
## clump footprint; width_factor scales blade width.
static func build_clump(seed_value: int, blade_count: int = RANDOM_BLADE_COUNT,
		blade_min: int = 8, blade_max: int = 13,
		spread_factor: float = 1.0, width_factor: float = 1.0) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var n := blade_count
	if n == RANDOM_BLADE_COUNT:
		n = rng.randi_range(blade_min, blade_max)
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for b in n:
		_build_single_blade(rng, pos, nor, uv, idx, spread_factor, width_factor)
	var arrays := _pack_arrays(pos, nor, uv, idx)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Dry clump: 3~6 thin flat strips, nearly upright, slanted tips. Nominal height 1.0
static func build_dry_stems(seed_value: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var n := rng.randi_range(3, 6)
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for b in n:
		var ang := rng.randf() * TAU
		var root := Vector3(cos(ang) * rng.randf() * 0.05, 0.0, sin(ang) * rng.randf() * 0.05)
		var yaw := rng.randf() * TAU
		var lean_ang := yaw + rng.randf_range(-1.0, 1.0)
		var lean_dir := Vector3(cos(lean_ang), 0.0, sin(lean_ang))
		var bend := rng.randf_range(0.02, 0.16)
		var height := rng.randf_range(0.55, 1.0)
		var w := rng.randf_range(0.008, 0.015)
		var cut_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var cut := rng.randf_range(0.0, 0.12) * height   # slanted tip height difference
		var base := pos.size()
		for i in DRY_SEGMENTS + 1:
			var t := float(i) / float(DRY_SEGMENTS)
			var off := bend * t * t
			var center := root + Vector3(0.0, t * height, 0.0) + lean_dir * off
			var side := Vector3(cos(yaw), 0.0, sin(yaw))
			var face := Vector3(-side.z, 0.0, side.x)
			var ww := w * lerpf(1.0, 0.35, t)   # taper upward
			var yl := 0.0
			var yr := 0.0
			if i == DRY_SEGMENTS:
				yl = -cut
				yr = -cut if cut_sign < 0.0 else 0.0
			pos.append(center - side * (ww * 0.5) + Vector3(0.0, yl, 0.0))
			pos.append(center + side * (ww * 0.5) + Vector3(0.0, yr, 0.0))
			nor.append(face)
			nor.append(face)
			uv.append(Vector2(0.0, t))
			uv.append(Vector2(1.0, t))
		for i in DRY_SEGMENTS:
			var a := base + i * DRY_RING_VERTS
			var bb := a + DRY_RING_VERTS
			idx.append_array(PackedInt32Array([a, bb + 1, bb, a, a + 1, bb + 1]))
	var arrays := _pack_arrays(pos, nor, uv, idx)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _build_single_blade(rng: RandomNumberGenerator, pos: PackedVector3Array,
		nor: PackedVector3Array, uv: PackedVector2Array, idx: PackedInt32Array,
		spread_factor: float = 1.0, width_factor: float = 1.0) -> void:
	# Root: half clustered at the core (main blades), half scattered outward (side blades),
	# breaking radial stars; spread_factor scales the whole footprint
	var ang := rng.randf() * TAU
	var rad: float
	if rng.randf() < 0.5:
		rad = sqrt(rng.randf()) * CLUMP_CORE_RADIUS
	else:
		rad = CLUMP_CORE_RADIUS + sqrt(rng.randf()) * (CLUMP_SCATTER_RADIUS - CLUMP_CORE_RADIUS)
	rad *= spread_factor
	var root := Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	# Face direction (width rotates with twist along the blade)
	var yaw := rng.randf() * TAU
	var lean_ang := yaw + rng.randf_range(-1.4, 1.4)
	var lean_dir := Vector3(cos(lean_ang), 0.0, sin(lean_ang))
	# Posture: 20% half-flattened, 18% upright, rest normal arc; 30% with an S wave
	var posture := rng.randf()
	var bend: float
	if posture < 0.20:
		bend = rng.randf_range(0.45, 0.85)
	elif posture < 0.38:
		bend = rng.randf_range(0.02, 0.12)
	else:
		bend = rng.randf_range(0.12, 0.42)
	var s_wave := 0.0
	if rng.randf() < 0.30:
		s_wave = rng.randf_range(-0.10, 0.10)
	var height := rng.randf_range(0.60, 1.08)
	var w_max := NOMINAL_MAX_WIDTH * rng.randf_range(0.75, 1.2) * width_factor
	var twist := rng.randf_range(-1.5, 1.5) * PI   # ±270°
	var ridge_ratio := rng.randf_range(0.60, 0.85)
	# Serrated edges: irregular width jitter per ring (random phase, none at the root)
	var saw_amp := rng.randf_range(0.06, 0.16)
	var saw_phase := rng.randf() * 10.0
	# Split tip: height difference between ridge and edges (broken three-tooth tip)
	var tip_split_l := rng.randf_range(0.0, 0.05) * height
	var tip_split_r := rng.randf_range(0.0, 0.05) * height
	var base := pos.size()
	for i in SEGMENTS + 1:
		var t := float(i) / float(SEGMENTS)
		# Center axis: quadratic bend + optional S wave (times t² so the root slope is zero)
		var off := bend * t * t + s_wave * t * t * sin(t * PI * 1.5)
		var center := root + Vector3(0.0, t * height, 0.0) + lean_dir * off
		# Width profile: narrow base → widest around t≈0.35 → tapering above → thin tip
		var wb: float
		if t < 0.35:
			wb = lerpf(0.30, 1.0, smoothstep(0.0, 0.35, t))
		else:
			wb = lerpf(1.0, 0.06, smoothstep(0.35, 1.0, t))
		# Serrations appear after t=0.35, getting finer toward the tip
		var saw := 0.0
		if t > 0.35:
			var ph := t * 26.0 + saw_phase
			saw = saw_amp * (fmod(ph, 1.0) - 0.5) * 2.0 * smoothstep(0.35, 0.7, t)
		var w := maxf(w_max * wb * (1.0 + saw), w_max * 0.05)
		# Twist along the blade: width direction and face normal rotate with t
		var yaw_t := yaw + twist * t
		var side := Vector3(cos(yaw_t), 0.0, sin(yaw_t))
		var face := Vector3(-side.z, 0.0, side.x)
		var ridge := w * ridge_ratio
		# Analytical folded-face normals: left/right slopes face apart (flipping with twist),
		# ridge faces the convex side. Fall back to face when the tip degenerates to a needle.
		var n_left := face
		var n_right := face
		if w > 0.0001:
			var nl := face * (w * 0.5) - side * ridge
			var nr := face * (w * 0.5) + side * ridge
			if nl.length_squared() > 0.00000001:
				n_left = nl.normalized()
			if nr.length_squared() > 0.00000001:
				n_right = nr.normalized()
		var dy_l := 0.0
		var dy_r := 0.0
		if i == SEGMENTS:
			dy_l = -tip_split_l
			dy_r = -tip_split_r
		pos.append(center - side * (w * 0.5) + Vector3(0.0, dy_l, 0.0))
		pos.append(center + face * ridge)
		pos.append(center + side * (w * 0.5) + Vector3(0.0, dy_r, 0.0))
		nor.append(n_left)
		nor.append(face)
		nor.append(n_right)
		uv.append(Vector2(0.0, t))
		uv.append(Vector2(0.5, t))
		uv.append(Vector2(1.0, t))
	# 4 triangles per segment (winding toward the convex V face)
	for i in SEGMENTS:
		var a := base + i * RING_VERTS
		var b := a + RING_VERTS
		idx.append_array(PackedInt32Array([
			a, b + 1, b, a, a + 1, b + 1,
			a + 1, b + 2, b + 1, a + 1, a + 2, b + 2,
		]))


static func _pack_arrays(pos: PackedVector3Array, nor: PackedVector3Array,
		uv: PackedVector2Array, idx: PackedInt32Array) -> Array:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays
