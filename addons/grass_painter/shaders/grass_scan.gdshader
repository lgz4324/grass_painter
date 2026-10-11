shader_type spatial;
// depth_prepass_alpha: alpha-clipped grass also writes depth in the opaque depth prepass (Godot 4.3+;
// the same discard threshold runs there), so dense grass and far LOD-card overdraw is not paid in full.
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled, depth_prepass_alpha;

// Scanned-grass material: photo textures + wind sway + player bending + distance shrink.
// World displacement is reverse-mapped into instance-local space: local ≈ R(-yaw)·world / k.
// INSTANCE_CUSTOM: x=seed y=yaw/TAU z=dry-tip factor (color tweak only here) w=kind (0 grass 1 dry stubble)

global uniform vec3 grass_player_pos;

group_uniforms g_texture;
uniform sampler2D base_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_disable;
uniform sampler2D translucency_tex : filter_linear_mipmap, repeat_disable;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.7;
uniform float backlight_gain : hint_range(0.0, 2.0) = 0.85;

group_uniforms g_grade;
// Grading: photo colors -> desaturated, darker, cooler. Saturation/value/hue knobs + dry tint mix.
uniform float saturation : hint_range(0.0, 2.0) = 0.72;
uniform float value_mul : hint_range(0.0, 2.0) = 0.82;
uniform float hue_shift : hint_range(-0.5, 0.5) = -0.015;
uniform float dry_mix : hint_range(0.0, 1.0) = 0.18;
uniform vec3 dry_tint : source_color = vec3(0.52, 0.47, 0.27);
uniform float per_instance_jitter : hint_range(0.0, 0.5) = 0.10;

group_uniforms g_wind;
uniform float wind_strength = 0.11;
uniform vec2 wind_dir = vec2(0.8, 0.6);
uniform float gust_freq = 0.6;
uniform float gust_low_freq = 0.15;
uniform float jitter_freq = 2.2;

group_uniforms g_interact;
uniform float bend_radius = 0.9;
uniform float bend_push = 0.5;

group_uniforms g_dist;
uniform float fade_start = 38.0;
uniform float fade_end = 48.0;

varying float v_iseed;
varying float v_dry;
varying float v_kind;
varying float v_t;        // Blade-length weight: UV.y runs along the blade (0 root -> 1 tip)
varying vec2 v_uv;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
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
	float kind = INSTANCE_CUSTOM.w;
	float yaw = INSTANCE_CUSTOM.y * 6.2831853;
	float phase = hash21(vec2(iseed * 19.19, 4.7));
	float k = max(0.001, length(MODEL_MATRIX[0].xyz));

	vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float cam_d = length(CAMERA_POSITION_WORLD - wpos);

	// Wind: slow gusts + field wave + high-frequency tip jitter
	vec2 wdir = normalize(wind_dir);
	float wind_scale = mix(0.55 + 0.8 * phase, 0.12, kind);
	float gust_low = sin(TIME * gust_low_freq + wpos.x * 0.05 + wpos.z * 0.04 + phase * 2.1);
	float gust = sin(TIME * gust_freq + wpos.x * 0.08 + wpos.z * 0.06 + phase);
	float jit = sin(TIME * jitter_freq + wpos.x * 0.35 + wpos.z * 0.22 + phase * 3.1);
	float sway = (gust_low * 0.85 + gust * 0.5 + jit * 0.35 * pow(t, 2.2))
			* wind_strength * wind_scale * bend_w;
	sway *= mix(1.0, 0.35, smoothstep(30.0, fade_start, cam_d));

	// Player bending (stateless recovery)
	vec2 to_root = root_w.xz - grass_player_pos.xz;
	float d = length(to_root);
	float bend_amt = 1.0 - smoothstep(bend_radius * 0.4, bend_radius, d);
	vec2 wpush = vec2(0.0);
	float drop = 0.0;
	if (bend_amt > 0.001) {
		vec2 dir = to_root / max(d, 0.001);
		float push = bend_amt * bend_push * bend_w * (1.0 - 0.6 * bend_amt);
		wpush = dir * push;
		drop = push * 0.7;
	}

	// World displacement -> instance local: local ≈ R(-yaw)·world / k
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
	NORMAL = mix(NORMAL, vec3(0.0, 1.0, 0.0), 0.25);

	// Distance shrink (root at the local origin, so shrinking sinks the blade into the ground; keeps the depth prepass)
	float fade = 1.0 - smoothstep(fade_start, fade_end, cam_d);
	VERTEX *= fade;

	v_iseed = iseed;
	v_dry = INSTANCE_CUSTOM.z;
	v_kind = kind;
	v_t = t;
	v_uv = UV;
}


void fragment() {
	vec4 tex = texture(base_tex, v_uv);
	float alpha = tex.a;
	if (alpha < 0.35) {
		discard;
	}
	vec3 col = tex.rgb;

	// Grading: hue shift + saturation/value compression + per-instance jitter + dry tint (custom.z injected at scatter time)
	vec3 hsv = rgb2hsv(col);
	hsv.x = fract(hsv.x + hue_shift + (v_iseed - 0.5) * 0.02);
	hsv.y = clamp(hsv.y * saturation * (1.0 + (v_iseed - 0.5) * per_instance_jitter), 0.0, 1.0);
	hsv.z = clamp(hsv.z * value_mul * (1.0 + (hash21(vec2(v_iseed * 91.7, 3.1)) - 0.5) * per_instance_jitter), 0.0, 1.0);
	col = hsv2rgb(hsv);
	col = mix(col, dry_tint * (0.85 + 0.3 * v_iseed), clamp(v_dry * dry_mix, 0.0, 0.85));

	// Root darkening: scanned clumps include soil (y_min<0), so t<0.25 is darkened to sink into the ground
	float ao = mix(0.58, 1.0, smoothstep(0.0, 0.25, v_t));
	col *= ao;

	ALBEDO = col;
	ROUGHNESS = 0.9;
	NORMAL_MAP = texture(normal_tex, v_uv).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
	BACKLIGHT = vec3(texture(translucency_tex, v_uv).r * backlight_gain);
}
