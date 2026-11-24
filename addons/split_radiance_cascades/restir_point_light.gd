@tool
class_name ReSTIRPointLight3D
extends Node3D
## Point emitter sampled by ReSTIR DI (diffuse + GGX specular) and the SRC hit shader (diffuse only).
## It has no RenderingServer light, so Forward+ never adds its direct term twice.
@export_color_no_alpha var color := Color.WHITE
@export_range(0.0, 128.0, 0.05, "or_greater") var energy := 4.0
@export_range(0.01, 128.0, 0.05, "or_greater", "suffix:m") var radius := 8.0
@export_range(0.0, 8.0, 0.05, "or_greater") var indirect_energy := 1.0
