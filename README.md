# Drawing Hub

One script for Roblox drawing and painting games: auto-draw any picture, paint any player's avatar, or blend in perfectly.

## Load it

Everything at once (the hub picks the right tool for the game you're in):

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/octobertm6/Drawing-Hub/main/drawing_hub.lua"))()
```

Run it anywhere. A small window lists the games:

- **In one of the games already?** Its tool opens by itself.
- **Somewhere else?** Press **Join game** on a card. It teleports you there and opens the tool when you arrive.

`RightCtrl` shows or hides the hub window.

Or load just one game's script. Each game has its own file in [`scripts/`](scripts), and its loadstring is listed under that game below.

## What's in the repo

| File | What it is |
| --- | --- |
| `drawing_hub.lua` | The hub with every script below built in |
| `scripts/free_draw.lua` | Free Draw |
| `scripts/spray_paint.lua` | Spray Paint! |
| `scripts/draw_me.lua` | Draw Me! |
| `scripts/hide_in_paintings.lua` | Hide In Paintings |
| `scripts/welding_bricklayer.lua` | WELDING Bricklayer |
| `scripts/chameleon.lua` | Chameleon! |

## Games

| Game | What it does | Window key |
| --- | --- | --- |
| **Free Draw** | Draws a picture as parts on the big floor canvas | `RightShift` |
| **Spray Paint!** | Sprays a picture, text or any player's avatar onto walls with the game's own spray can | `RightShift` |
| **Draw Me!** | Draws the player you're drawing (head or whole avatar) onto your canvas | `RightShift` |
| **Hide In Paintings** | Paints your figure to match the painting behind it, and shows where your opponent is hiding | `RightShift` |
| **WELDING Bricklayer** | Launches any player into the air with a brick, orbits pieces around you, deletes your loose pieces | `RightShift` |
| **Chameleon!** | Paints your character as an exact copy of the wall behind you; as seeker, highlights enemies through walls and rapid-fires the shotgun | `K` |

### Free Draw / Spray Paint!

Free Draw on its own:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/octobertm6/Drawing-Hub/main/scripts/free_draw.lua"))()
```

Spray Paint! on its own:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/octobertm6/Drawing-Hub/main/scripts/spray_paint.lua"))()
```

1. Paste a direct link to an image (png, jpg, webp or gif).
   In Spray Paint! you can also use the **Text** tab, or the **Avatar** tab: type a username or display name and it loads that player's avatar (full body, upper body or head).
2. Press **Preview** / **Load** to see what it will look like.
3. Press **Draw** (Free Draw) or **Place** then **Paint!** (Spray Paint!).
4. **Stop** pauses. Pressing Draw / Paint! again carries on where it stopped.

### Draw Me!

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/octobertm6/Drawing-Hub/main/scripts/draw_me.lua"))()
```

Draws the player you've been given (just the head, or the whole avatar) onto your canvas, then you submit as normal.

### Hide In Paintings

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/octobertm6/Drawing-Hub/main/scripts/hide_in_paintings.lua"))()
```

- **Blend In** (`B`): move into your spot, press it, then press the game's Submit. Your whole figure takes the exact colours of the painting behind it.
- **Undo blend**: puts your previous paint back.
- **Show opponent** (`V`): while you seek, your opponent's hidden figure gets a pulsing outline. Only you can see it.

### WELDING Bricklayer

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/octobertm6/Drawing-Hub/main/scripts/welding_bricklayer.lua"))()
```

- **Launch** (`L`): pick a player in the list (you're at the top) and press Launch. A brick (you) or steel plate (anyone else) slides under their feet, rises at **Speed** for **Rise time**, then drops into the void so they keep flying up.
- **Orbit** (`O`): pieces circle you and fling whoever they hit. It keeps spawning every item type (bricks, plates, boards, planks, beams, glass, windows) until the server won't spawn any more, and **Bring nearby loose parts** adds anyone's non-cemented pieces lying near you. Turning it off sends your pieces into the void and drops other people's.
- **Delete my loose pieces** (click twice): removes every loose piece of yours for everyone. Cemented pieces can only be broken with the game's hammer.

### Chameleon!

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/octobertm6/Drawing-Hub/main/scripts/chameleon.lua"))()
```

- **Camouflage me** (`C`): back up against a wall and press it. Every spot on your body is painted with the exact wall pixel behind it (wallpaper patterns, custom materials, decals, textures), through the game's own painter, so everyone sees it. **Detail** sets how fine the dots are (128 default; 192–256 is sharper but slower), **Brightness %** evens out lighting.
- **Show enemies** (`G`): outlines every enemy through walls (hiders when you seek, seekers when you hide).
- **Rapid fire**: hold click to keep the shotgun firing at the fastest rate the server accepts (**Shot delay**, about 0.6 s). The window counts shots the server accepted.
- **Shoot through walls**: shots start up to 18 studs closer to the enemy nearest your crosshair (**Aim radius**). The server limits how far a shot may start from you, so it only reaches enemies close by.
- The game's own hider keys are `V`, `F` (lock in place), `E`, `Q` and `R`. If you can't move, press `F` to unlock.

## Notes

- Some games (Free Draw) don't allow teleporting from other creators' games. If **Join** says so, open that game from the Roblox app and run the script there.
- Your executor needs `request`, `writefile`, `getcustomasset`, `getconnections` and `queue_on_teleport` (most do). The bricklayer orbit works best with `isnetworkowner`.
