shader_type canvas_item;
// 监控画面的桶形/鱼眼畸变：只作用于画面纹理，不影响监控 UI 的按钮和文字。
// 用“源 UV 向中心收缩”的方式得到向外鼓起的效果，避免四角被裁成黑块。

uniform float strength = 0.10;
uniform float zoom = 1.0;

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r2 = dot(p, p);
	vec2 warped = p * (1.0 - strength * r2) / zoom;
	vec2 uv = warped * 0.5 + 0.5;
	COLOR = vec4(texture(TEXTURE, clamp(uv, vec2(0.0), vec2(1.0))).rgb, 1.0);
}
