shader_type spatial;
// 钢笔画风：纸白底色 + 反向外扩描边。全部程序生成，不依赖任何贴图。
//
// StyleController 用同一个 shader 生成两份材质：
// - 底色 pass（outline_pass = false）：铺纸白底；
// - 描边 pass（outline_pass = true，挂在底色材质的 next_pass 上）：
//   沿法线外扩顶点、丢弃正面，只在轮廓外缘留下一条墨线。
// 这样单文件即可同时得到「填充」与「描边」两层，不需要额外网格或后处理。
render_mode unshaded, cull_disabled;

uniform bool outline_pass = false;
uniform float outline_width : hint_range(0.0, 0.25) = 0.035;
uniform vec4 outline_color : source_color = vec4(0.06, 0.06, 0.08, 1.0);
uniform vec4 paper_color : source_color = vec4(0.93, 0.90, 0.83, 1.0);

void vertex() {
	if (outline_pass) {
		VERTEX += normalize(NORMAL) * outline_width;
	}
}

void fragment() {
	if (outline_pass) {
		// 只保留外扩网格的背面，形成真正的轮廓线。
		if (FRONT_FACING) {
			discard;
		}
		ALBEDO = outline_color.rgb;
	} else {
		// 底色只画正面，避免 cull_disabled 把内壁也画出来。
		if (!FRONT_FACING) {
			discard;
		}
		ALBEDO = paper_color.rgb;
	}
}
