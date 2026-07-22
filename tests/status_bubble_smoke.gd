extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	SaveManager.writes_enabled = false
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	GameState.reset_to_defaults(false)
	main.world.load_layout()

	var customer_label := Label3D.new()
	main.world.add_child(customer_label)
	customer_label.visible = true
	customer_label.text = "MENU"
	var customer_bubble := AgentStatusBubble.new()
	main.world.add_child(customer_bubble)
	customer_bubble.setup(customer_label, main.world, "customer")

	_set_zoom(main.world, 24.0)
	customer_bubble.update_bubble(0.1)
	_expect(not customer_bubble.is_icon_visible(), "status bubbles stay hidden at the default distant zoom")
	_set_zoom(main.world, 17.0)
	customer_bubble.update_bubble(0.1)
	_expect(customer_bubble.is_icon_visible() and customer_bubble.current_key == "ordering", "zooming close reveals the mapped customer state")
	var customer_icon := customer_bubble.get_node("BubbleIcon") as Sprite3D
	_expect(customer_icon.texture is AtlasTexture and (customer_icon.texture as AtlasTexture).region == Rect2(768, 192, 192, 192), "customer status selects a centered atlas cell")
	_expect(customer_icon.pixel_size <= 0.005, "the close-zoom bubble remains compact over the character")
	_set_zoom(main.world, 19.0)
	customer_bubble.update_bubble(0.1)
	_expect(customer_bubble.is_icon_visible(), "zoom hysteresis prevents threshold flicker")
	_set_zoom(main.world, 20.0)
	customer_bubble.update_bubble(0.1)
	_expect(not customer_bubble.is_icon_visible(), "status bubbles hide after crossing the distant threshold")

	_set_zoom(main.world, 17.0)
	customer_label.text = "CONTO"
	customer_bubble.update_bubble(0.1)
	_expect(customer_bubble.is_icon_visible() and customer_bubble.current_key == "bill", "a changed customer phase selects a new icon")
	customer_bubble.update_bubble(4.0)
	_expect(not customer_bubble.is_icon_visible(), "a state bubble expires instead of remaining permanently visible")
	customer_label.visible = false
	customer_bubble.update_bubble(0.1)
	customer_label.visible = true
	customer_bubble.update_bubble(0.1)
	_expect(customer_bubble.is_icon_visible(), "a later explicit state event can show the same icon again")
	customer_label.text = "TROPPA ATTESA"
	customer_bubble.update_bubble(0.1)
	_expect(customer_bubble.current_key == "angry", "an urgent mood replaces the routine state")
	customer_label.text = "MENU"
	customer_bubble.update_bubble(0.1)
	_expect(customer_bubble.current_key == "angry" and customer_bubble.get_child_count() == 1, "a lower-priority cue never stacks over an urgent bubble")
	customer_bubble.update_bubble(3.5)
	_expect(customer_bubble.current_key == "ordering" and customer_bubble.is_icon_visible(), "the pending routine cue appears after the urgent bubble expires")

	var staff_label := Label3D.new()
	main.world.add_child(staff_label)
	staff_label.visible = true
	staff_label.text = "LAVAGGIO"
	var staff_bubble := AgentStatusBubble.new()
	main.world.add_child(staff_bubble)
	staff_bubble.setup(staff_label, main.world, "staff")
	staff_bubble.update_bubble(0.1)
	_expect(staff_bubble.is_icon_visible() and staff_bubble.current_key == "wash", "staff work states use the dedicated action atlas")
	staff_label.text = "PULIZIA"
	staff_bubble.update_bubble(0.1)
	_expect(staff_bubble.current_key == "clean", "maintenance states select a specific cleaning bubble")

	for path: String in [AgentStatusBubble.CUSTOMER_ATLAS, AgentStatusBubble.STAFF_ATLAS]:
		var texture := load(path) as Texture2D
		var image := texture.get_image() if texture != null else null
		_expect(image != null and image.detect_alpha() and image.get_pixel(0, 0).a == 0.0, "%s is a real transparent atlas" % path.get_file())

	var result := "STATUS BUBBLES: %s | checks=%d failures=%d\n%s" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size(), "\n".join(failures)]
	print(result)
	var file := FileAccess.open("res://tests/status-bubble-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _set_zoom(world: RestaurantWorld, value: float) -> void:
	world.camera_rig.zoom = value
	world.camera_rig.camera.size = value


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
