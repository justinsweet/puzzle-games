# studio_core

Shared code for all our games. Edit it HERE, then run `tools/sync_shared.sh`
to copy it into each game's `addons/studio_core/` folder.

| File | What it does | How a game uses it |
| --- | --- | --- |
| `ads_manager.gd` | Interstitial and rewarded ads (placeholder test ads for now; AdMob later) | Autoload `Ads` |
| `progress.gd` | Saves stars per level, hint count, "unlock all" testing switch | Autoload `Progress` |
| `level_select.gd` | Start screen: mascot, title, Play button, worlds and level grid with stars | `preload(...).new()` then `setup(...)` |
| `fx.gd` | Confetti burst, pop animation, star shapes | `preload("res://addons/studio_core/fx.gd")` |
| `mascot_view.gd` | The mascot during play: idle bob, cheers on a win, thinks on a hint, dozes off when idle | `preload(...).new()`, `load_poses("res://assets/")`, `react("cheering")` |
