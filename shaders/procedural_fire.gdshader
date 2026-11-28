shader_type spatial;
// 程序化体积火：参考 procedural-fire 的 volume pass，用 3D FBM 构造火舌，
// 黑体 LUT 出颜色，soot 决定吸收/发光，蓝色根部单独加。
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D blackbody_lut : source_color, filter_linear, repeat_disable;
uniform vec3 box_min = vec3(-15.0, 0.0, -27.0);
uniform vec3 box_max = vec3(-2.0, 2.6, -13.0);
uniform vec3 source_pos = vec3(-8.5, 0.18, -20.0);
uniform float fire_radius = 1.0;
uniform float fire_height = 2.2;
uniform float intensity = 1.0;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float vnoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash31(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash31(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float fbm3(vec3 p) {
	float value = 0.0;
	float amp = 0.55;
	for (int i = 0; i < 4; i++) {
		value += vnoise3(p) * amp;
		p = p * 2.03 + vec3(17.0, 9.2, 13.7);
		amp *= 0.5;
	}
	return value;
}

void fragment() {
	vec3 world_frag = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 ray_origin = CAMERA_POSITION_WORLD;
	vec3 ray_dir = normalize(world_frag - ray_origin);
	vec3 inv_dir = 1.0 / ray_dir;
	vec3 t0 = (box_min - ray_origin) * inv_dir;
	vec3 t1 = (box_max - ray_origin) * inv_dir;
	vec3 t_min = min(t0, t1);
	vec3 t_max = max(t0, t1);
	float enter = max(max(t_min.x, t_min.y), t_min.z);
	float exit = min(min(t_max.x, t_max.y), t_max.z);
	enter = max(enter, 0.0);
	if (exit <= enter) {
		discard;
	}

	const int STEPS = 40;
	float step_size = (exit - enter) / float(STEPS);
	vec3 box_size = box_max - box_min;
	vec3 accum = vec3(0.0);
	float transmittance = 1.0;

	for (int i = 0; i < STEPS; i++) {
		vec3 p = ray_origin + ray_dir * (enter + (float(i) + 0.5) * step_size);
		vec3 uvw = (p - box_min) / box_size;
		float h = clamp((p.y - source_pos.y) / max(fire_height, 0.01), 0.0, 1.0);
		vec2 rel = p.xz - source_pos.xz;
		float sway = sin(h * 8.0 + TIME * 2.0 + p.z * 1.1) * 0.20 * (1.0 - h) * fire_radius;
		rel.x += sway;
		float width = fire_radius * (0.18 + 0.82 * (1.0 - h));
		float r = length(rel);
		float n1 = fbm3(vec3(rel.x * 2.7, p.y * 1.5 - TIME * 2.1, rel.y * 2.7));
		float n2 = fbm3(vec3(rel.x * 6.0 + 4.0, p.y * 3.2 - TIME * 3.2, rel.y * 6.0));
		float shape = 1.0 - smoothstep(width * 0.10, width,
			r + (n1 - 0.5) * width * 0.80);
		float tongue = smoothstep(0.30, 0.72, n2 + (1.0 - h) * 0.22);
		float vertical = smoothstep(0.0, 0.04, h) * (1.0 - smoothstep(0.60, 1.0, h));
		float density = shape * tongue * vertical * intensity * 0.85;
		float edge = min(min(uvw.x, 1.0 - uvw.x), min(uvw.z, 1.0 - uvw.z));
		density *= smoothstep(0.0, 0.12, edge);
		if (density <= 0.002) {
			continue;
		}

		float heat = clamp(0.16 + density * 0.62 + n2 * 0.18 - h * 0.10, 0.0, 1.0);
		vec3 color = texture(blackbody_lut, vec2(heat, 0.75)).rgb;
		float blue = exp(-h * 6.0) * (1.0 - smoothstep(0.03, 0.16, density)) * 0.35;
		vec3 emission = color * density * 1.6 + vec3(0.04, 0.22, 1.0) * blue;
		float sigma = density * 2.1 + 0.01;
		float alpha = 1.0 - exp(-sigma * step_size);
		accum += emission * alpha * transmittance;
		transmittance *= 1.0 - alpha;
		if (transmittance < 0.02) {
			break;
		}
	}

	ALBEDO = accum;
	ALPHA = clamp(length(accum) * 2.0, 0.0, 1.0);
}
