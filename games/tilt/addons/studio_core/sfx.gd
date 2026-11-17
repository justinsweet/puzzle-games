extends Node
## Sound effects, music and vibration, shared by every game. Registered as the autoload `Sfx`.
##
##   Sfx.play("plunk")        plays res://assets/sfx/plunk.ogg (or .wav / .mp3) if it exists
##   Sfx.music("world1")      loops res://assets/music/world1.ogg if it exists
##   Sfx.vibrate(40)          short buzz on phones
## Missing files are skipped silently, so games can call these before the sounds exist.
## Respects the Sound / Music / Vibration switches saved in Progress.

const EXTENSIONS := ["ogg", "wav", "mp3"]
const VOICES := 6

var _cache := {}
var _players: Array = []
var _next := 0
var _music_player: AudioStreamPlayer
var _music_name := ""


func _ready() -> void:
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	_music_player = AudioStreamPlayer.new()
	_music_player.volume_db = -8.0
	add_child(_music_player)


func _find(folder: String, name: String) -> AudioStream:
	var key := folder + name
	if not _cache.has(key):
		_cache[key] = null
		for ext in EXTENSIONS:
			var path := "res://assets/%s/%s.%s" % [folder, name, ext]
			if ResourceLoader.exists(path):
				_cache[key] = load(path)
				break
	return _cache[key]


func play(name: String, pitch_variation: float = 0.06) -> void:
	if not Progress.get_setting("sound"):
		return
	var stream := _find("sfx", name)
	if stream == null:
		return
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % VOICES
	p.stream = stream
	p.pitch_scale = 1.0 + randf_range(-pitch_variation, pitch_variation)
	p.play()


func music(name: String) -> void:
	if name == _music_name and _music_player.playing:
		return
	_music_name = name
	var stream := _find("music", name)
	if stream == null or not Progress.get_setting("music"):
		_music_player.stop()
		return
	if stream is AudioStreamOggVorbis or stream is AudioStreamMP3:
		stream.loop = true
	_music_player.stream = stream
	_music_player.play()


func refresh_music() -> void:
	var name := _music_name
	_music_name = ""
	music(name)


func vibrate(ms: int = 30) -> void:
	if Progress.get_setting("vibration"):
		Input.vibrate_handheld(ms)
