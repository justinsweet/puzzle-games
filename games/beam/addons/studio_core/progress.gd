extends Node
## Saved player progress for one game: stars per level, hint count, settings.
## Stored in user://progress.json (each game has its own user:// folder).
## Registered in each game as the autoload `Progress`.

const PATH := "user://progress.json"
const STARTING_HINTS := 3

var _data := {"stars": {}, "hints": STARTING_HINTS, "unlock_all": false,
	"settings": {"sound": true, "music": true, "vibration": true}}


func _ready() -> void:
	if FileAccess.file_exists(PATH):
		var saved = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if saved is Dictionary:
			_data.merge(saved, true)


func save() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_data))


func stars(level: int) -> int:
	return int(_data["stars"].get(str(level), 0))


## Keeps the best result for a level.
func record_stars(level: int, value: int) -> void:
	if value > stars(level):
		_data["stars"][str(level)] = value
		save()


func total_stars() -> int:
	var total := 0
	for k in _data["stars"]:
		total += int(_data["stars"][k])
	return total


func is_unlocked(level: int) -> bool:
	return level == 0 or bool(_data["unlock_all"]) or stars(level - 1) > 0


## First level not yet beaten (where "Play" should start).
func next_unplayed(level_count: int) -> int:
	for i in level_count:
		if stars(i) == 0:
			return i
	return 0


var hints: int:
	get:
		return int(_data["hints"])
	set(value):
		_data["hints"] = max(0, value)
		save()


var unlock_all: bool:
	get:
		return bool(_data["unlock_all"])
	set(value):
		_data["unlock_all"] = value
		save()


## Sound, music and vibration switches (true = on).
func get_setting(name: String) -> bool:
	return bool(_data["settings"].get(name, true))


func set_setting(name: String, value: bool) -> void:
	_data["settings"][name] = value
	save()


## Clears stars, hints and the testing switch; keeps sound/music/vibration settings.
func reset() -> void:
	var settings: Dictionary = _data["settings"]
	_data = {"stars": {}, "hints": STARTING_HINTS, "unlock_all": false, "settings": settings}
	save()
