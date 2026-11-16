extends Node
## Studio ads manager (shared by every game).
##
## Games only ever call these functions:
##   Ads.on_level_complete(level_number)   -> may show an interstitial
##   Ads.show_rewarded(on_reward)          -> plays a rewarded ad, then calls on_reward
##
## Right now this is a PLACEHOLDER that shows a fake "TEST AD" screen so we can
## build and feel the ad flow. Later, the real AdMob plugin gets wired in here
## (using Google's test ad IDs during development) and no game code changes.

const FIRST_INTERSTITIAL_LEVEL := 8   # no interstitials before this level
const INTERSTITIAL_EVERY := 3         # then every N levels
const MIN_SECONDS_BETWEEN := 90.0     # and never more often than this

var ads_removed := false              # set true after a "Remove Ads" purchase
var _last_interstitial_time := -1000.0


func on_level_complete(level_number: int, done: Callable = Callable()) -> void:
	if _should_show_interstitial(level_number):
		_last_interstitial_time = Time.get_ticks_msec() / 1000.0
		_show_fake_ad("TEST AD\n(interstitial)", 1.5, done)
	elif done.is_valid():
		done.call()


func show_rewarded(on_reward: Callable) -> void:
	# Rewarded ads still show after "Remove Ads": players choose to watch them.
	_show_fake_ad("TEST AD\n(rewarded: +1 hint)", 2.0, on_reward)


func _should_show_interstitial(level_number: int) -> bool:
	if ads_removed or level_number < FIRST_INTERSTITIAL_LEVEL:
		return false
	if level_number % INTERSTITIAL_EVERY != 0:
		return false
	var now := Time.get_ticks_msec() / 1000.0
	return now - _last_interstitial_time >= MIN_SECONDS_BETWEEN


func _show_fake_ad(text: String, seconds: float, done: Callable) -> void:
	print("[Ads] ", text.replace("\n", " "))
	var layer := CanvasLayer.new()
	layer.layer = 100
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.9)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 44)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_child(label)
	layer.add_child(bg)
	get_tree().root.add_child(layer)
	await get_tree().create_timer(seconds).timeout
	layer.queue_free()
	if done.is_valid():
		done.call()
