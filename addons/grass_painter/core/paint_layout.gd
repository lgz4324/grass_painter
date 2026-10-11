@tool
extends RefCounted
## Pure layout logic (no editor dependency, headless testable): grid placement, circle
## matching, height conversion between presets and the region merge plan.
## The circle semantics must match GrassRegion.hit_exclusion_circles (≤ radius squared);
## hit_circle is the independent implementation, used to cross-check.


## Fill the rectangle center±half_extents with grid points spaced exactly `step` apart.
## Spacing is constant (= step), so adjacent regions never overlap; the count is rounded
## up and the whole grid is centered on the rectangle, letting edge cells stick out by at
## most half a step. Points are (x, z) Vector2.
static func grid_points(center: Vector2, half_extents: Vector2, step: float) -> Array[Vector2]:
	var pts: Array[Vector2] = []
	if step <= 0.0 or half_extents.x <= 0.0 or half_extents.y <= 0.0:
		return pts
	var nx := maxi(1, int(ceil(half_extents.x * 2.0 / step)))
	var nz := maxi(1, int(ceil(half_extents.y * 2.0 / step)))
	var start_x := center.x - (float(nx) - 1.0) * 0.5 * step
	var start_z := center.y - (float(nz) - 1.0) * 0.5 * step
	for i in nx:
		for j in nz:
			pts.append(Vector2(start_x + float(i) * step, start_z + float(j) * step))
	return pts


## Whether (x, z) is inside any circle; each entry holds (center_x, center_z, radius).
## Must match GrassRegion.hit_exclusion_circles (≤ radius squared).
static func hit_circle(circles: Array, x: float, z: float) -> bool:
	for c in circles:
		var v: Vector3 = c
		var dx := x - v.x
		var dz := z - v.y
		if dx * dx + dz * dz <= v.z * v.z:
			return true
	return false


## Convert a height range between two presets while preserving the *visual* height.
## Visual height = h × ratio, so h_new = h × old_ratio / new_ratio.
static func convert_height(old_ratio: float, new_ratio: float, lo: float, hi: float) -> Vector2:
	return Vector2(lo * old_ratio / new_ratio, hi * old_ratio / new_ratio)


## Plan for merging several GrassRegion nodes into one big region.
## Returns {ok, error, center: Vector3, size: Vector3, exclusion_circles: Array[Vector3],
## seed: int, old_regions: Array}.
## Requires: all regions inside the tree, identity basis, same preset kind, same
## density/surface_source/height range and same node world y; otherwise returns an error.
static func merge_plan(regions: Array) -> Dictionary:
	if regions.size() < 2:
		return {"ok": false, "error": "Select at least 2 regions"}
	var minx: float = INF
	var maxx := -INF
	var minz: float = INF
	var maxz := -INF
	var base_region: Node3D = regions[0]
	var base_preset_path: String = base_region.get_preset().resource_path
	for r in regions:
		if not (is_instance_valid(r) and r.is_inside_tree()):
			return {"ok": false, "error": "A region is invalid or outside the tree"}
		if not r.global_transform.basis.is_equal_approx(Basis()):
			return {"ok": false, "error": "\"%s\" has rotation/scale — reset it first" % r.name}
		if r.get_preset().resource_path != base_preset_path:
			return {"ok": false, "error": "\"%s\" uses a different grass preset — unify first" % r.name}
		for k in ["density", "surface_source", "height_min", "height_max"]:
			if r.get(k) != base_region.get(k):
				return {"ok": false, "error": "\"%s\" differs in %s — apply to unify first" % [r.name, k]}
		# World node y must match: the new region y takes that value; a mismatch would make
		# the height window reject every point (zero grass)
		if absf(r.global_position.y - base_region.global_position.y) > 0.01:
			return {"ok": false, "error": "\"%s\" node y(%.2f) differs (%.2f)" % [
				r.name, r.global_position.y, base_region.global_position.y]}
	var node_y: float = base_region.global_position.y
	for r in regions:
		var s: Vector3 = r.size
		var p: Vector3 = r.global_position
		minx = minf(minx, p.x - s.x * 0.5)
		maxx = maxf(maxx, p.x + s.x * 0.5)
		minz = minf(minz, p.z - s.z * 0.5)
		maxz = maxf(maxz, p.z + s.z * 0.5)
	var center := Vector3((minx + maxx) * 0.5, node_y, (minz + maxz) * 0.5)
	var region_size := Vector3(maxx - minx, 1.0, maxz - minz)
	var merged_circles: Array[Vector3] = []
	for r in regions:
		for c in r.exclusion_circles:
			var world: Vector3 = r.global_transform * Vector3(c.x, 0.0, c.y)
			merged_circles.append(Vector3(world.x - center.x, 0.0, world.z - center.z))
	var seed_base := int(absf(center.x * 7.31 + center.z * 13.7))
	var new_seed := 1 + absi((seed_base * 2654435761) ^ (regions.size() * 40503)) % 99991
	return {"ok": true, "error": "", "center": center, "size": region_size,
		"exclusion_circles": merged_circles, "seed": new_seed, "old_regions": regions}
