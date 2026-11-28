shader_type spatial;
// 程序化体积火：真正的 raymarch，用 3D FBM 扰动 + 黑体 LUT 做火焰。
// 参考 procedural-fire 的 volume pass：温度/烟尘发射、吸收、黑体色、蓝色基部。
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D blackbody_lut : source_color, filter_linear, repeat_disable;
uniform vec3 box_min = vec3(-15.0, 0.0, -27.0);
uniform vec3 box_max = vec3(-2.0, 2.6, -13.0);
uniform vec3 source_pos = vec3(-8.5, 0.18, -20.0);
uniform float fire_radius = 1.0;
uniform float fire_height = 2.8;
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

	const int STEPS = 34;
	float step_size = (exit - enter) / float(STEPS);
	vec3 box_size = box_max - box_min;
	vec3 accum = vec3(0.0);
	float transmittance = 1.0;

	for (int i = 0; i < STEPS; i++) {
		vec3 p = ray_origin + ray_dir * (enter + (float(i) + 0.5) * step_size);
		vec3 uvw = (p - box_min) / box_size;
		float h = clamp((p.y - source_pos.y) / max(fire_height, 0.01), 0.0, 1.0);
		vec2 rel = p.xz - source_pos.xz;

		// 上升火舌的横向摆动 + 湍流。
		float sway = sin(h * 7.0 + TIME * 1.8 + p.z * 0.9) * 0.18 * (1.0 - h);
		rel.x += sway * (0.4 + h * 1.2);
		float r = length(rel);
		float widening = 0.70 + 0.30 * (1.0 - h);
		float radius = fire_radius * widening;
		float n = fbm3(vec3(rel.x * 2.1, p.y * 1.35 - TIME * 2.1, rel.y * 2.1));
		float n2 = fbm3(vec3(rel.x * 5.0 + 8.3, p.y * 3.3 - TIME * 3.5, rel.y * 5.0));
		float edge = 1.0 - smoothstep(radius * 0.10, radius, r + (n - 0.5) * radius * 0.8);
		float vertical = smoothstep(0.0, 0.04, h) * (1.0 - smoothstep(0.58, 1.0, h));
		// 高频噪声负责火舌的卷曲和分离；不要把所有源区都填成一团。
		float tongues = smoothstep(0.38, 0.70, n2 + (1.0 - h) * 0.30 + n * 0.18);
		float density = edge * vertical * tongues * intensity * 1.65;
		// 隐藏体积盒边界。
		float box_edge = min(min(uvw.x, 1.0 - uvw.x), min(uvw.z, 1.0 - uvw.z));
		density *= smoothstep(0.0, 0.10, box_edge);
		if (density <= 0.002) {
			continue;
		}

		float heat = clamp(0.18 + density * 0.82 + n2 * 0.18 - h * 0.12, 0.0, 1.0);
		vec3 soot_color = texture(blackbody_lut, vec2(heat, 0.75)).rgb;
		float blue = exp(-h * 5.0) * (1.0 - smoothstep(0.04, 0.22, density)) * 0.32;
		vec3 emission = soot_color * density * 2.3 + vec3(0.05, 0.22, 1.0) * blue;
		// 物理感：越浓的烟尘吸收越多，火舌边缘透明。
		float sigma = density * 1.9 + 0.012;
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
