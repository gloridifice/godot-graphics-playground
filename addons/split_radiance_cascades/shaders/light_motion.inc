// Motion changes confidence, not the scene lighting. Skip all lamp reads at rest.
shared float motion_loss;
float light_motion_loss(uint key, int c) {
	if (p.display.y == 0.0) return 0.0;
	int tag = tag_of(key);
	float cell = spacing(tag,c);
	vec3 center = (vec3(cell_of(key))+0.5)*cell;
	float total = 0.0, moving = 0.0, peak = 0.0;
	for (int i=0; i<p.options.w; ++i) {
		vec4 light = lights[i].position_range, energy = lights[i].bounce;
		float power = dot(energy.rgb,vec3(.2126,.7152,.0722));
		if (light.w > 0.0) {
			float d = distance(center,light.xyz);
			float inner = 1.25*light.w + 0.8661*cell;
			float outer = inner + min(interval_end(tag,c),light.w) + 0.25*light.w;
			float reach = 1.0-smoothstep(inner,outer,d);
			// Approximate the light's share of diffuse transport, not shadow visibility.
			power *= reach / pow(max(1.0,d),lights[i].direct_falloff.w);
			float travel = energy.w;
			float rate = reach*min(0.16,1.5*travel*travel);
			peak = max(peak,rate);
			moving += power*rate;
		}
		total += power;
	}
	// Keep a strong response to significant lamps without discarding the static
	// gallery lighting just because a very weak lamp moved through its footprint.
	return min(peak, moving / max(0.08*total,1e-7));
}
float relight_weight(float old_count, float count) {
	if (motion_loss <= 0.0) return old_count;
	float keep = 1.0-motion_loss;
	float weight = old_count*keep;
	return count > 0.0 ? min(weight,max(1.0,count)*keep/motion_loss) : weight;
}
