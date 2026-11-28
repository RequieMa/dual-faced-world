shader_type spatial;
// 软边圆形焦痕，避免扩大的火焰底下出现一个黑色方块。
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 scorch_color : source_color = vec4(0.035, 0.018, 0.012, 1.0);

void fragment() {
	vec2 uv = UV - vec2(0.5);
	float radius = length(uv) * 2.0;
	float alpha = (1.0 - smoothstep(0.18, 1.0, radius)) * 0.82;
	ALBEDO = scorch_color.rgb;
	ALPHA = alpha;
}
