extends Node
## Non-interactive test driver: synthetic Input actions -> per-character scripted commands.
## Windows stay unfocusable. F/Esc capture is reserved for explicit --interactive-input runs.
var enabled := false
var characters: Array[MotionCharacter] = []

func _init() -> void:
	process_physics_priority = -100

func bind(character: MotionCharacter) -> void:
	characters.append(character)
	if enabled: _send(character)

func set_enabled(value: bool) -> void:
	enabled = value
	for character in characters:
		if not is_instance_valid(character): continue
		if enabled:
			_send(character)
		else:
			character.clear_external_input()

func _physics_process(_delta: float) -> void:
	if enabled:
		for character in characters:
			if is_instance_valid(character): _send(character)

func _send(character: MotionCharacter) -> void:
	character.set_external_input(Input.get_vector("move_left", "move_right", "move_forward", "move_back"), Input.is_action_pressed("sprint"), Input.is_action_pressed("crouch"), Input.is_action_pressed("jump"))
