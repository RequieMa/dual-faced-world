shader_type canvas_item;
// 第一人称镜头桶形畸变：只作用于 3D 画面，HUD 在更高 CanvasLayer 上不受影响。
// 屏幕边缘向外弯，中心保持清晰；强度很小，避免影响点击/阅读。

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float strength = 0.045;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 p = uv - vec2(0.5);
	float r2 = dot(p, p);
	vec2 warped = uv + p * (strength * r2);
	vec3 color = texture(screen_texture, clamp(warped, vec2(0.0), vec2(1.0))).rgb;
	COLOR = vec4(color, 1.0);
}
