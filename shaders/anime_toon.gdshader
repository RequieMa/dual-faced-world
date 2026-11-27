shader_type spatial;
// 轻量二次元 Toon 材质：贴图 × 色，阈值阴影 + 简单边缘光。
// 参考 my-npr 的 diffuse ramp / shadow color 思路，但用 Godot spatial light() 重写，
// 不依赖 Three.js/WebGPU。

render_mode depth_prepass_alpha, cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool has_texture = true;
uniform bool use_alpha = true;
uniform vec3 shadow_tint : source_color = vec3(0.62, 0.68, 0.82);
uniform float shadow_threshold = 0.0;
uniform float shadow_softness = 0.08;
uniform float rim_strength = 0.25;
uniform vec4 rim_color : source_color = vec4(0.85, 0.93, 1.0, 1.0);

void fragment() {
	vec4 tex = has_texture ? texture(albedo_tex, UV) : vec4(1.0);
	vec4 base = tex * albedo_color;
	ALBEDO = base.rgb;
	ALPHA = use_alpha ? base.a : 1.0;
	ALPHA_SCISSOR_THRESHOLD = 0.42;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	METALLIC = 0.0;

	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.6) * rim_strength;
	EMISSION += rim_color.rgb * rim;
}

void light() {
	float ndl = dot(normalize(NORMAL), normalize(LIGHT));
	float lit = smoothstep(-shadow_softness, shadow_softness, ndl - shadow_threshold);
	vec3 shadow = ALBEDO * shadow_tint;
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * mix(shadow, ALBEDO, lit) / PI;
}
