shader_type spatial;
// 铅笔画风：纸白底 + 石墨排线 + 高频颗粒噪点。全部程序生成，不依赖任何贴图。
// 用 unshaded + 固定光向模拟「素描明暗」，再叠两层噪声与排线做出潦草的手绘感。
render_mode unshaded, cull_back;

uniform vec4 sketch_paper_color : source_color = vec4(0.92, 0.90, 0.84, 1.0);
uniform vec4 graphite_color : source_color = vec4(0.16, 0.16, 0.18, 1.0);
uniform float grain_strength : hint_range(0.0, 1.0) = 0.55;
uniform float grain_scale : hint_range(2.0, 200.0) = 55.0;
uniform float stroke_strength : hint_range(0.0, 1.0) = 0.5;
uniform float stroke_scale : hint_range(2.0, 80.0) = 26.0;
uniform float shade_strength : hint_range(0.0, 1.0) = 1.0;

varying vec3 world_pos;
varying vec3 world_normal;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// 固定光向，避免依赖场景灯光；只用明暗决定石墨密度。
	vec3 light_dir = normalize(vec3(0.35, 0.8, 0.45));
	float shade = clamp(dot(normalize(world_normal), light_dir), 0.0, 1.0);
	shade = mix(1.0, shade, shade_strength);

	vec2 grain_uv = vec2(world_pos.x + world_pos.y, world_pos.z + world_pos.y);
	float grain = value_noise(grain_uv * grain_scale);
	float scratch = value_noise(grain_uv * grain_scale * 3.7 + vec2(13.0, 7.0));

	// 两组不同角度的排线，模拟铅笔来回涂抹的笔触。
	float coord = (world_pos.x + world_pos.y * 0.6 + world_pos.z * 0.3) * stroke_scale;
	float strokes = max(smoothstep(0.55, 0.95, sin(coord)),
		smoothstep(0.6, 0.95, sin(coord * 1.7 + 2.1))) * stroke_strength;
	strokes *= 0.35 + 0.65 * (1.0 - shade);

	float density = (1.0 - shade) * 0.55 + strokes * 0.55;
	density += (grain - 0.5) * grain_strength;
	density += (scratch - 0.5) * grain_strength * 0.45;
	density = clamp(density, 0.0, 1.0);
	ALBEDO = mix(sketch_paper_color.rgb, graphite_color.rgb, density);
}
