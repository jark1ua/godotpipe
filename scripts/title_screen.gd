extends Control
# ============================================================================
# title_screen.gd  (GDScript)
# ----------------------------------------------------------------------------
# The title is now a brief splash with no body text. Its only job: wait for any
# key or click, then hand off to the main menu. Changing scenes in Godot is a
# single call — there is no manual teardown of the previous scene.
# ============================================================================

func _unhandled_input(event: InputEvent) -> void:
	var advance := (event is InputEventKey and event.is_pressed()) \
		or (event is InputEventMouseButton and event.is_pressed())
	if advance:
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
