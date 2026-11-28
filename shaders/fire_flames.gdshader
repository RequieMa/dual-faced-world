shader_type spatial;
// 火焰火舌层：交叉垂直面片上的程序化 FBM，颜色来自黑色体 LUT。
// 3D 燃烧场负责强度/扩张/威胁判定；这层负责让高位摄像头看到稳定的火舌轮廓。
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

void fragment() {
	vec2 uv = UV;
	float t = TIME * 0.9 + seed;
	float n = fbm(vec2(uv.x * 4.0 + t * 0.35, uv.y * 3.0 - t * 1.05));
	float sway = sin(uv.y * 5.0 + t * 2.2) * 0.14 * (1.0 - uv.y);
	float x = abs(uv.x - 0.5 + sway);
	float body = smoothstep(0.62, 0.04, x + (1.0 - uv.y) * 0.22 - n * 0.28);
	float height_fade = smoothstep(0.0, 0.2, 1.0 - uv.y);
	float alpha = body * height_fade * 0.95 * intensity;
	if (alpha <= 0.002) {
		discard;
	}
	float heat = clamp(1.0 - uv.y * 0.8 + n * 0.28, 0.0, 1.0);
	vec3 color = texture(blackbody_lut, vec2(heat, 0.5)).rgb;
	ALBEDO = color;
	ALPHA = clamp(alpha, 0.0, 0.95);
}
