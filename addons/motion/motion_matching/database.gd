class_name MotionDatabase
extends Resource
## Offline, pre-IK Guard poses in model space (+Z forward, +X anatomical left).
## Row: feet positions 6, feet velocities 6, root velocity XZ 2,
##      future root offsets XZ at .2/.4/.6 seconds 6, contacts 2.

const WIDTH := 22
const HORIZONS := [0.2, 0.4, 0.6]
const WEIGHTS := [0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.8, 0.8, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 0.25, 0.25]

@export var clips := PackedStringArray()
@export var lengths := PackedFloat32Array()
@export var crouched := PackedByteArray()
@export var speeds := PackedFloat32Array()
@export var starts := PackedInt32Array()
@export var counts := PackedInt32Array()
@export var features := PackedFloat32Array()
@export var inverse_std := PackedFloat32Array()

func nearest(query: PackedFloat32Array, crouch: bool, nominal_speed: float, current: int, time: float, allow_idle: bool = true, maximum_speed: float = INF) -> Dictionary:
	var best_clip := -1
	var best_row := -1
	var best_cost := INF
	# Continuation competes with every database frame, but a jump must win by a margin.
	if current >= 0 and bool(crouched[current]) == crouch and (allow_idle or speeds[current] > 0.0) and speeds[current] <= maximum_speed:
		best_clip = current
		best_row = starts[current] + roundi(fposmod(time, lengths[current]) / lengths[current] * counts[current]) % counts[current]
		best_cost = _cost(query, best_row, current, nominal_speed)
	for clip in clips.size():
		if bool(crouched[clip]) != crouch or (not allow_idle and speeds[clip] <= 0.0) or speeds[clip] > maximum_speed:
			continue
		for row in range(starts[clip], starts[clip] + counts[clip]):
			var cost := _cost(query, row, clip, nominal_speed)
			if current >= 0:
				cost = cost * 1.12 + 0.25
			if cost < best_cost:
				best_clip = clip
				best_row = row
				best_cost = cost
	return {"clip": best_clip, "time": float(best_row - starts[best_clip]) / counts[best_clip] * lengths[best_clip], "cost": best_cost}

func _cost(query: PackedFloat32Array, row: int, clip: int, nominal_speed: float) -> float:
	var rate := clampf(nominal_speed / speeds[clip], 0.5, 2.0) if speeds[clip] > 0.0 else 1.0
	# A gait preference, not a direction-to-clip switch. Side/back walking may be sped up
	# when sprinting because the bundled data has no authored side/back running clips.
	# A factor-two retime costs eight normalized units: otherwise pose continuity can
	# trap a sprint in a 2x Walk forever when a newly imported Run has a different pose.
	var cost := 8.0 * pow(log(speeds[clip] / nominal_speed) / log(2.0), 2.0) if speeds[clip] > 0.0 else 0.0
	for column in WIDTH:
		var value := features[row * WIDTH + column]
		if column >= 6 and column < 20:
			value *= rate
		var difference := (query[column] - value) * inverse_std[column]
		cost += difference * difference * WEIGHTS[column]
	return cost
