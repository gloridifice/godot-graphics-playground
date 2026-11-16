extends RefCounted
## A short support-local Hermite trajectory. Both position and velocity join the lock.
## With destination = start + velocity * duration/2, horizontal motion is uniform braking.
var start := Transform3D.IDENTITY
var destination := Transform3D.IDENTITY
var initial_velocity := Vector3.ZERO
var duration := 0.12
var elapsed := 0.0

func begin(from: Transform3D, velocity: Vector3, to: Transform3D, seconds: float) -> void:
	start = from
	initial_velocity = velocity
	destination = to
	duration = maxf(seconds, 0.001)
	elapsed = 0.0

func advance(delta: float) -> void:
	elapsed = minf(elapsed + delta, duration)

func sample() -> Transform3D:
	var u := clampf(elapsed / duration, 0.0, 1.0)
	var u2 := u * u
	var u3 := u2 * u
	var position := start.origin * (2.0 * u3 - 3.0 * u2 + 1.0) + initial_velocity * duration * (u3 - 2.0 * u2 + u) + destination.origin * (-2.0 * u3 + 3.0 * u2)
	return Transform3D(start.basis.slerp(destination.basis, smoothstep(0.0, 1.0, u)), position)

func velocity() -> Vector3:
	var u := clampf(elapsed / duration, 0.0, 1.0)
	return (start.origin * (6.0 * u * u - 6.0 * u) + initial_velocity * duration * (3.0 * u * u - 4.0 * u + 1.0) + destination.origin * (-6.0 * u * u + 6.0 * u)) / duration

func finished() -> bool:
	return elapsed >= duration
