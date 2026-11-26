shader_type spatial;
// 二次元描边：反面外扩（inverted hull），作为 toon 材质的 next_pass。
// 宽度在模型局部空间里设置，avatar_loader 会按归一化比例换算成约 1cm。

render_mode unshaded, cull_front, shadows_disabled;

uniform vec4 outline_color : source_color = vec4(0.02, 0.025, 0.035, 1.0);
uniform float outline_width = 0.01;

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
