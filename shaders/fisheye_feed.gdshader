shader_type canvas_item;
// 监控画面的桶形/鱼眼畸变 + 老电视 CRT 暗纹：只作用于画面纹理，
// 不影响监控 UI 的按钮和文字。
// 用“源 UV 向中心收缩”的方式得到向外鼓起的效果，避免四角被裁成黑块。

uniform float strength = 0.10;
uniform float zoom = 1.0;
uniform float scanline_density = 180.0;
uniform float scanline_strength = 0.22;
uniform float noise_strength = 0.035;
uniform float vignette_strength = 0.38;
uniform float jitter_strength = 0.0008;

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r2 = dot(p, p);
	vec2 warped = p * (1.0 - strength * r2) / zoom;
	vec2 uv = warped * 0.5 + 0.5;

	// 轻微的水平抖动，让画面像老式 CRT/监控而不是干净的数字画面。
	float line = floor(UV.y * 270.0);
	float jitter = (fract(sin(TIME * 2.3 + line * 12.9898) * 43758.5453) - 0.5) * jitter_strength;
	uv.x += jitter;

	vec3 color = texture(TEXTURE, clamp(uv, vec2(0.0), vec2(1.0))).rgb;

	// 扫描暗纹：越靠近亮线越暗，形成老电视的横向条纹。
	float scan = 0.5 + 0.5 * sin(uv.y * scanline_density * 3.14159265);
	color *= 1.0 - scanline_strength * smoothstep(0.2, 1.0, scan);

	// 动态颗粒。
	float grain = fract(sin(dot(uv * vec2(1280.0, 720.0) + TIME * vec2(17.0, 29.0),
		vec2(12.9898, 78.233))) * 43758.5453);
	color += (grain - 0.5) * noise_strength;

	// 边缘压暗。
	float vignette = smoothstep(1.35, 0.45, length(p));
	color *= mix(1.0 - vignette_strength, 1.0, vignette);

	COLOR = vec4(color, 1.0);
}
