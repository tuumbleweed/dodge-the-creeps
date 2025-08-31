// 2D shader for ColorRect (or any CanvasItem)
// We draw: (1) a simple vertical gradient, then (2) procedural rising bubbles on top.
shader_type canvas_item;


// ========================= COLOR (GRADIENT) =========================
// "uniform" = editable in the Inspector on your ShaderMaterial.
// ": source_color" = Inspector shows a color picker.

// Lighter (top) color
uniform vec4 shallow_color : source_color = vec4(0.15, 0.70, 0.85, 1.0);
// Darker (bottom) color
uniform vec4 deep_color    : source_color = vec4(0.03, 0.20, 0.35, 1.0);


// ========================= BUBBLE CONTROLS =========================
// Visual tint of the bubbles (usually white). We'll blend this over the gradient.
uniform vec4  bubble_color   : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// How strongly to blend bubbles over the background (0..1). We also scale by coverage.
uniform float bubble_alpha   = 0.25;

// Motion/shape of bubbles
uniform float bubble_speed   = 0.1;   // vertical rise speed (UV units per second)
uniform float bubble_soft    = 0.02;  // rim softness for anti-aliased edges
uniform float bubble_min_r   = 0.012;  // smallest radius (in UV units)
uniform float bubble_max_r   = 0.065;  // largest  radius (in UV units)

// How many columns to distribute bubbles across, and how many layers/passes.
// Keep these modest; loops are statically unrolled in many drivers.
uniform int   bubble_cols    = 10;     // don’t exceed ~64
uniform int   bubble_layers  = 3;      // 1–3 recommended

// Keep bubbles inside their column so neighbors don’t overlap:
uniform bool  bubble_stay_in_cell = true;
uniform float bubble_margin    = 0.006; // min gap to cell walls
uniform float bubble_drift_amp = 0.007; // tiny sideways drift; smaller = fewer overlaps

// A master seed to reshuffle the whole procedural layout deterministically.
uniform float master_seed = 11.0;


// ========================= RANDOM HELPERS =========================
// Base tiny hashes (deterministic, textureless).
float hash11(float n) { return fract(sin(n) * 43758.5453123); }
float hash21(vec2 p)  { return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453123); }

// Seeded wrappers so changing master_seed actually changes all randomness.
// (We offset the inputs by scaled + nonlinearly-mixed master_seed.)
float seeded_hash11(float n) {
	return hash11(n + master_seed * 13.371 + sin(master_seed * 0.77) * 19.91);
}
float seeded_hash21(vec2 p) {
	return hash21(p + vec2(master_seed * 1.233, master_seed * 3.071)
	                 + vec2(sin(master_seed * 0.41), cos(master_seed * 0.29)) * 5.0);
}

// Signed distance to a circle centered at (0,0) with radius r.
// < 0 inside, > 0 outside, 0 on the rim.
float sd_circle(vec2 p, float r) {
	return length(p) - r;
}


// ========================= BUBBLES =========================
// Returns accumulated bubble coverage (0..1) at a pixel UV.
// We:
//   - split the screen into vertical columns,
//   - for each column (and a few layers) we spawn one bubble at a time,
//   - bubbles rise from just below the bottom (1+R) to just above the top (-R),
//   - we softly add their alpha so overlaps don't get too opaque.
float bubbles(vec2 uv) {
	float accum = 0.0;

	// Column width in UV space (0..1).
	float cols   = float(bubble_cols);
	float cell_w = 1.0 / max(cols, 1.0);

	// Loop caps (keep small; many GPUs unroll these).
	const int MAX_LAYERS = 3;
	const int MAX_COLS   = 64;

	// Max radius that still fits inside a column with a margin.
	float max_radius_in_cell = max(0.0, 0.5 * cell_w - bubble_margin);

	for (int layer = 0; layer < MAX_LAYERS; layer++) {
		if (layer >= bubble_layers) { break; }

		// Per-layer time offset so layers don't sync exactly.
		float t_layer = TIME * bubble_speed + float(layer) * 0.37;

		for (int ci = 0; ci < MAX_COLS; ci++) {
			if (ci >= bubble_cols) { break; }

			float col_i = float(ci);

			// ---- Random seeds for this (column, layer) pair ----
			float seed = seeded_hash21(vec2(col_i + 13.0 * float(layer),
			                                91.7 + float(layer) * 17.1));

			// Random radius in [bubble_min_r, bubble_max_r]
			float size_rnd = seeded_hash11(seed * 7.91);
			float radius   = mix(bubble_min_r, bubble_max_r, size_rnd);
			if (bubble_stay_in_cell) {
				radius = min(radius, max_radius_in_cell); // ensure it fits inside the cell
			}

			// Column center X (middle of the cell)
			float cell_center = (col_i + 0.5) * cell_w;

			// Random horizontal jitter within the column.
			float jitter_rnd   = seeded_hash11(seed * 3.17); // 0..1
			float jitter_sign  = (jitter_rnd - 0.5) * 2.0;   // -1..1
			float jitter_limit = 0.5 * cell_w;               // half cell width
			if (bubble_stay_in_cell) {
				jitter_limit = max(0.0, (0.5 * cell_w) - radius - bubble_margin);
			}
			float x_center = cell_center + jitter_sign * jitter_limit * 0.6; // 60% of allowance

			// Tiny sideways drift. If staying in cell, clamp drift so we don't cross the wall.
			float drift = sin(TIME * 0.9 + seed * 6.0) * bubble_drift_amp;
			if (bubble_stay_in_cell) {
				float left_allow  = (cell_center - (radius + bubble_margin)) - x_center;
				float right_allow = (cell_center + (radius + bubble_margin)) - x_center;
				drift = clamp(drift, left_allow, right_allow);
			}
			x_center += drift;

			// ---- Vertical motion: FULL enter & FULL exit ----
			// We animate a phase s ∈ [0,1), then map to a path from (1+R) down to (-R).
			// That ensures bubbles fully appear from below and fully leave above before looping.
			float phase_col   = fract(col_i * 0.6180339887);             // column decorrelation
			float phase_layer = float(layer) * 0.33;                      // layer decorrelation
			float phase_seed  = seeded_hash11(seed * 5.33);
			float phase       = fract(phase_seed + phase_col * 0.7 + phase_layer);

			float s = fract(t_layer + phase);                             // 0..1 increasing
			float travel = 1.0 + 2.0 * radius;                            // visible span + offscreen caps
			float y_pos  = (1.0 + radius) - s * travel;                   // 1+R → ... → -R

			// ---- Shape & soft alpha ----
			float d = sd_circle(uv - vec2(x_center, y_pos), radius);
			float a = 1.0 - smoothstep(0.0, bubble_soft, d);              // soft rim

			// Accumulate softly so overlaps don’t blow out opacity.
			accum += a * 0.6;
		}
	}

	return clamp(accum, 0.0, 1.0);
}


// ========================= MAIN =========================
void fragment() {
	// UV.x: 0 (left) → 1 (right), UV.y: 0 (top) → 1 (bottom)
	vec2 uv = UV;

	// ---- (1) Simple vertical gradient ----
	// mask = 0 → shallow_color (top), mask = 1 → deep_color (bottom)
	float mask = clamp(uv.y, 0.0, 1.0);
	vec3  col  = mix(shallow_color.rgb, deep_color.rgb, mask);

	// ---- (2) Bubbles composited on top ----
	float bub = bubbles(uv);

	// Soft “over” blend (keeps background colors intact). Try additive for sparkle.
	col = mix(col, bubble_color.rgb, bubble_alpha * bub);

	// Output final color (opaque)
	COLOR = vec4(col, 1.0);
}
