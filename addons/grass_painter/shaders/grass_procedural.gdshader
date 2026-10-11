shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled;

// Global interaction point: register it under [shader_globals] and write the player's world position each frame.
global uniform vec3 grass_player_pos;

group_uniforms g_color;
uniform vec3 root_color : source_color = vec3(0.115, 0.140, 0.085);
uniform vec3 tip_color : source_color = vec3(0.355, 0.405, 0.245);
uniform vec3 dry_color : source_color = vec3(0.52, 0.47, 0.27);
uniform vec3 straw_color : source_color = vec3(0.30, 0.265, 0.165);
uniform float hue_jitter : hint_range(0.0, 0.3) = 0.05;
uniform float root_ao : hint_range(0.0, 0.8) = 0.42;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.85;

group_uniforms g_wind;
uniform float wind_strength = 0.05;
uniform vec2 wind_dir = vec2(0.8, 0.6);
uniform float gust_freq = 0.6;
uniform float gust_low_freq = 0.15;
uniform float jitter_freq = 2.2;

group_uniforms g_interact;
uniform float bend_radius = 0.9;
uniform float bend_push = 0.5;

group_uniforms g_dist;
uniform float fade_start = 45.0;
uniform float fade_end = 55.0;
// Leaf detail (midrib / veins / mottling / dry band) is only computed within this distance; beyond it the whole detail block is skipped to save fragment ALU.
uniform float detail_dist : hint_range(5.0, 60.0) = 20.0;

varying float v_iseed;
varying float v_dry;
varying float v_kind;
varying float v_u;
varying float v_t;
varying float v_detail;
// Per-instance random values are computed once in the vertex stage and passed down (never re-hash iseed per fragment).
varying vec4 v_rand_a;  // hv value / hs saturation / hh hue / dry-tip start
varying vec3 v_rand_b;  // mid dry amount / dry band center / dry band width

// INSTANCE_CUSTOM: x=seed y=yaw/TAU z=dry-tip factor (0 or 0.45~1) w=kind (0 grass 1 dry stubble)
// Note: INSTANCE_CUSTOM is unavailable in the fragment stage; the needed components arrive via varyings.


float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(K.bg, K.wz), vec4(K.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, p.z), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}


void vertex() {
	float t = clamp(UV.y, 0.0, 1.0);
	float bend_w = pow(t, 1.5);
	vec3 root_w = MODEL_MATRIX[3].xyz;
	float iseed = INSTANCE_CUSTOM.x;
	float dryv = INSTANCE_CUSTOM.z;
	float kind = INSTANCE_CUSTOM.w;
	float yaw = INSTANCE_CUSTOM.y * 6.2831853;
	float phase = hash21(vec2(iseed * 19.19, 4.7));
	// Instance scale = length of the matrix's first column (the blade is authored 1 m tall; instances land at ~0.12-0.22 m).
	// Instances carry non-uniform tilt/width scale, so k is an approximation used only to reverse-map wind/bend displacement - its error is far below the sway amplitude.
	float k = max(0.001, length(MODEL_MATRIX[0].xyz));

	vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float cam_d = length(CAMERA_POSITION_WORLD - wpos);

	// —— Per-instance constants computed once here, passed down via varyings ——
	vec4 rand_a;
	rand_a.x = hash21(vec2(iseed * 91.7, 3.1));                   // value ±10%
	rand_a.y = hash21(vec2(iseed * 47.3, 9.2));                   // saturation ±10%
	rand_a.z = hash21(vec2(iseed * 23.5, 17.7));                  // hue ±5%
	rand_a.w = mix(0.58, 0.82, hash21(vec2(iseed * 7.7, 5.0)));   // dry-tip start point
	vec3 rand_b;
	rand_b.x = dryv * step(0.55, hash21(vec2(iseed * 3.3, 8.8))); // mid dry (~1/3 of dry-tip carriers)
	rand_b.y = mix(0.35, 0.68, hash21(vec2(iseed * 5.1, 2.2)));   // dry band center
	rand_b.z = mix(0.05, 0.12, hash21(vec2(iseed * 9.9, 6.6)));   // dry band width

	// Wind: slow gusts (large scale) + field wave + high-frequency tip jitter; per-instance amplitude 0.55-1.35; dry stubble barely moves
	vec2 wdir = normalize(wind_dir);
	float wind_scale = mix(0.55 + 0.8 * phase, 0.12, kind);
	float gust_low = sin(TIME * gust_low_freq + wpos.x * 0.025 + wpos.z * 0.02 + phase * 2.1);
	float gust = sin(TIME * gust_freq + wpos.x * 0.08 + wpos.z * 0.06 + phase);
	float jit = sin(TIME * jitter_freq + wpos.x * 0.35 + wpos.z * 0.22 + phase * 3.1);
	float sway = (gust_low * 0.5 + gust * 0.5 + jit * 0.35 * pow(t, 2.2))
			* wind_strength * wind_scale * bend_w;
	sway *= mix(1.0, 0.35, smoothstep(30.0, fade_start, cam_d));

	// Player bending (stateless: recovers with distance; dry stubble bends as well)
	vec2 to_root = root_w.xz - grass_player_pos.xz;
	float d = length(to_root);
	// Reversed smoothstep edges (e0>e1) are undefined in the spec; use a forward edge and invert
	float bend_amt = 1.0 - smoothstep(bend_radius * 0.4, bend_radius, d);
	vec2 wpush = vec2(0.0);
	float drop = 0.0;
	if (bend_amt > 0.001) {
		vec2 dir = to_root / max(d, 0.001);
		float push = bend_amt * bend_push * bend_w * (1.0 - 0.6 * bend_amt);
		wpush = dir * push;
		drop = push * 0.7;
	}

	// World displacement -> instance local: local ≈ R(-yaw)·world / k (instance = yaw + tilt + non-uniform scale; good enough for tilt <= 30°)
	float c = cos(yaw);
	float s = sin(yaw);
	float inv_k = 1.0 / k;
	vec2 ldir = vec2(c * wdir.x - s * wdir.y, s * wdir.x + c * wdir.y) * (sway * inv_k);
	vec2 lpush = vec2(0.0);
	float ldrop = 0.0;
	if (bend_amt > 0.001) {
		vec2 wl = vec2(c * wpush.x - s * wpush.y, s * wpush.x + c * wpush.y);
		lpush = wl * inv_k;
		ldrop = drop * inv_k;
	}

	VERTEX += vec3(ldir.x + lpush.x, -ldrop, ldir.y + lpush.y);
	// Analytic blade normals keep their faceting through the twist; a small up-bias prevents pitch-black backfaces
	NORMAL = mix(NORMAL, vec3(0.0, 1.0, 0.0), mix(0.18, 0.32, kind));

	// Far-distance vertex shrink replaces dither+discard (keeps the depth prepass; the blade root sits at the local origin, so shrinking sinks it into the ground)
	float fade = 1.0 - smoothstep(fade_start, fade_end, cam_d);
	VERTEX *= fade;

	v_iseed = iseed;
	v_dry = dryv;
	v_kind = kind;
	v_u = UV.x;
	v_t = t;
	v_detail = 1.0 - smoothstep(detail_dist * 0.8, detail_dist, cam_d);
	v_rand_a = rand_a;
	v_rand_b = rand_b;
}

void fragment() {
	float t = v_t;
	float u = v_u;
	float iseed = v_iseed;
	float dry = v_dry;
	float kind = v_kind;

	// —— Dry stubble layer: dark brown throughout, only length-wise color variation, no green gradient ——
	vec3 col;
	float rough;
	float backlight;
	if (kind > 0.5) {
		col = straw_color;
		float sh = hash21(vec2(iseed * 31.7, floor(t * 14.0)));
		col *= 0.82 + 0.22 * sh;
		float sao = mix(1.0 - root_ao, 1.0, smoothstep(0.0, 0.45, t));
		col *= sao;
		rough = 0.95;
		backlight = 0.05;
	} else {
		// Per-instance value/saturation/hue jitter (computed in the vertex stage)
		float hv = v_rand_a.x;
		float hs = v_rand_a.y;
		float hh = v_rand_a.z;
		float dry_start = v_rand_a.w;

		col = mix(root_color, tip_color, t);
		vec3 hsv = rgb2hsv(col);
		hsv.x = fract(hsv.x + (hh - 0.5) * 2.0 * hue_jitter);
		hsv.y = clamp(hsv.y * (1.0 + (hs - 0.5) * 0.20), 0.0, 1.0);
		hsv.z = clamp(hsv.z * (1.0 + (hv - 0.5) * 0.20), 0.0, 1.0);
		col = hsv2rgb(hsv);

		// Dry color 1: dry tip (start point jittered per instance)
		float dry_amt = dry * smoothstep(dry_start, dry_start + 0.2, t);

		// —— Leaf detail (gated by detail_strength; skipped entirely beyond detail_dist) ——
		if (v_detail > 0.003) {
			float ds = detail_strength * v_detail;
			// Midrib highlight: a narrow bright line at u≈0.5 along the blade, strongest mid-length
			float midrib = 1.0 - smoothstep(0.0, 0.045, abs(u - 0.5));
			midrib *= sin(clamp(t / 0.12, 0.0, 1.0)) * (1.0 - smoothstep(0.75, 1.0, t));
			col *= 1.0 + 0.10 * ds * midrib;
			// Edge darkening: a thin recessed band on each side of the blade
			float edge = smoothstep(0.0, 0.10, u) * smoothstep(1.0, 0.90, u);
			col *= 1.0 - 0.16 * ds * (1.0 - edge);
			// Lengthwise parallel veins: faint dark threads, stronger near the root, weaker at the tip
			float veins = sin(u * 90.0 + iseed * 13.0) * 0.5 + 0.5;
			veins = smoothstep(0.75, 1.0, veins);
			col *= 1.0 - 0.05 * ds * veins * (1.0 - t * 0.6);
			// Two-scale mottling: low-frequency faded blotches + high-frequency speckle
			vec2 nuv = vec2(u * 2.2, t * 7.5) + vec2(iseed * 7.7, iseed * 3.3);
			float blotch = vnoise(nuv * 3.0) - 0.5;
			float speck = hash21(vec2(floor(u * 26.0) + iseed * 11.0, floor(t * 60.0) + iseed * 5.0)) - 0.5;
			col *= 1.0 + ds * (0.16 * blotch + 0.08 * speck);
			// Dry color 2: a mid-blade dry band on some instances (fades out with distance)
			float mid_dry = v_rand_b.x;
			float band_c = v_rand_b.y;
			float band_w = v_rand_b.z;
			dry_amt = max(dry_amt, mid_dry * (1.0 - smoothstep(band_w, band_w + 0.06, abs(t - band_c)))
					* smoothstep(0.15, 0.3, t) * v_detail);
		}

		vec3 dry_tint = dry_color * (0.85 + 0.3 * hv);
		col = mix(col, dry_tint, clamp(dry_amt, 0.0, 1.0) * 0.92);

		// Root darkening (fake contact AO) so grass reads as planted in the ground
		float ao = mix(1.0 - root_ao, 1.0, smoothstep(0.0, 0.30, t));
		col *= ao;
		rough = 0.9;
		// Thinner tips transmit more light; roots stay opaque
		backlight = mix(0.08, 0.25, t);
	}

	ALBEDO = col;
	ROUGHNESS = rough;
	BACKLIGHT = vec3(backlight);
}
