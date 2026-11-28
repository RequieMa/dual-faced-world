shader_type spatial;
// 程序化火焰体积 raymarch：3D 纹理里 x=温度、y=烟尘、z=燃料。
// 黑体色由 CPU 生成的 LUT 采样；渲染只做加法混合，不写深度。
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler3D fire_tex : filter_linear, repeat_disable;
uniform sampler2D blackbody_lut : source_color, filter_linear, repeat_disable;
uniform vec3 box_min = vec3(-10.0, 0.0, -22.0);
uniform vec3 box_max = vec3(-2.0, 2.45, -14.0);
uniform float intensity = 1.0;
uniform float density_scale = 0.55;
uniform float emission_scale = 1.35;

void fragment() {
	vec3 world_frag = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 ray_origin = CAMERA_POSITION_WORLD;
	vec3 ray_dir = normalize(world_frag - ray_origin);
	vec3 inv_dir = 1.0 / ray_dir;
	vec3 t0 = (box_min - ray_origin) * inv_dir;
	vec3 t1 = (box_max - ray_origin) * inv_dir;
	vec3 t_min = min(t0, t1);
	vec3 t_max = max(t0, t1);
	float enter = max(max(t_min.x, t_min.y), t_min.z);
	float exit = min(min(t_max.x, t_max.y), t_max.z);
	enter = max(enter, 0.0);
	if (exit <= enter) {
		discard;
	}

	const int STEPS = 28;
	float step_size = (exit - enter) / float(STEPS);
	vec3 accum = vec3(0.0);
	float transmittance = 1.0;
	vec3 box_size = box_max - box_min;
	for (int i = 0; i < STEPS; i++) {
		vec3 p = ray_origin + ray_dir * (enter + (float(i) + 0.5) * step_size);
		vec3 uvw = (p - box_min) / box_size;
		vec4 field = texture(fire_tex, uvw);
		float heat = clamp(field.r, 0.0, 1.0);
		float soot = clamp(field.g, 0.0, 1.0);
		float fuel = clamp(field.b, 0.0, 1.0);
		float density = (soot * 0.9 + fuel * 0.16) * density_scale * intensity;
		// 用廉价的世界空间扰动把均匀的源区打散成火舌/烟团，避免出现一个发光的方盒。
		float tongue = 0.5 + 0.5 * sin(p.x * 8.0 + p.z * 6.0 + TIME * 4.0)
			* sin(p.y * 11.0 - TIME * 3.0 + p.x * 3.0);
		density *= mix(0.28, 1.0, tongue);
		if (density > 0.001) {
			vec3 blackbody = texture(blackbody_lut, vec2(heat, 0.5)).rgb;
			float flicker = 0.88 + 0.12 * sin(TIME * 7.0 + p.y * 8.0 + p.x * 3.0);
			float alpha = density * step_size * emission_scale * flicker;
			accum += blackbody * alpha * transmittance;
			transmittance *= exp(-density * step_size * 1.8);
		}
	}
	ALBEDO = accum;
	ALPHA = clamp(length(accum) * 2.0, 0.0, 1.0);
}
