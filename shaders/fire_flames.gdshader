shader_type spatial;
// 火焰火舌层：交叉垂直面片上的程序化 FBM，颜色来自黑体 LUT。
// 3D 燃烧场负责强度/扩张/威胁判定；这一层负责稳定的火舌轮廓和透明边缘。
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D blackbody_lut : source_color, filter_linear, repeat_disable;
uniform float intensity = 1.0;
uniform float seed = 0.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	// 让面片始终面向当前摄像机；VIEW_MATRIX 是每个摄像机各自的。
	vec3 sx = INV_VIEW_MATRIX[0].xyz * length(MODEL_MATRIX[0].xyz);
	vec3 sy = INV_VIEW_MATRIX[1].xyz * length(MODEL_MATRIX[1].xyz);
	vec3 sz = INV_VIEW_MATRIX[2].xyz * length(MODEL_MATRIX[2].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(sx, 0.0), vec4(sy, 0.0),
		vec4(sz, 0.0), MODEL_MATRIX[3]);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.55;
	for (int i = 0; i < 4; i++) {
		value += value_noise(p) * amplitude;
		p = p * 2.03 + vec2(11.7, 5.3);
		amplitude *= 0.5;
	}
	return value;
}

float flame_noise(vec2 p) {
	// 低频剖开火舌，高频做边缘卷曲。
	return fbm(p) * 0.75 + fbm(p * 2.7 + vec2(4.1, 9.3)) * 0.35;
}

void fragment() {
	vec2 uv = UV;
	float t = TIME * 0.9 + seed;
	float n1 = flame_noise(vec2(uv.x * 2.4 + t * 0.24, uv.y * 2.1 - t * 0.95));
	float n2 = flame_noise(vec2(uv.x * 6.0 - t * 0.45, uv.y * 4.4 - t * 1.9));
	float sway = sin(uv.y * 5.5 + t * 1.7) * 0.13 * (1.0 - uv.y);
	float x = abs(uv.x - 0.5 + sway);
	// 火焰底部宽、顶部收尖，再用双层噪声撕出火舌。
	float taper = (1.0 - uv.y) * 0.38;
	float body = smoothstep(0.58, 0.02, x + taper + (n1 - 0.5) * 0.52);
	float tongue = smoothstep(0.48, 0.78, n2 + (1.0 - uv.y) * 0.18);
	float height_fade = smoothstep(0.0, 0.10, 1.0 - uv.y) * (1.0 - smoothstep(0.70, 1.0, uv.y));
	float alpha = body * tongue * height_fade * 0.78 * intensity;
	if (alpha <= 0.002) {
		discard;
	}
	float heat = clamp(0.22 + (1.0 - uv.y) * 0.50 + n1 * 0.24, 0.0, 1.0);
	vec3 color = texture(blackbody_lut, vec2(heat, 0.75)).rgb;
	// 火焰根部的一小段蓝色化学发光。
	float blue = exp(-uv.y * 7.0) * (1.0 - tongue) * 0.28;
	ALBEDO = color * 2.0 + vec3(0.04, 0.20, 1.0) * blue;
	ALPHA = clamp(alpha, 0.0, 0.82);
}
