# Drawing Hub

One script for Roblox drawing and painting games: auto-draw any picture, paint any player's avatar, or blend in perfectly.

## Load it

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/octobertm6/Drawing-Hub/main/drawing_hub.lua"))()
```

Run it anywhere. A small window lists the games:

- **In one of the games already?** Its tool opens by itself.
- **Somewhere else?** Press **Join game** on a card. It teleports you there and opens the tool when you arrive.

`RightCtrl` shows or hides the hub window.

## Games

| Game | What it does | Window key |
| --- | --- | --- |
| **Free Draw** | Draws a picture as parts on the big floor canvas | `RightShift` |
| **Spray Paint!** | Sprays a picture, text or any player's avatar onto walls with the game's own spray can | `RightShift` |
| **Draw Me!** | Draws the player you're drawing (head or whole avatar) onto your canvas | `RightShift` |
| **Hide In Paintings** | Paints your figure to match the painting behind it, and shows where your opponent is hiding | `RightShift` |
| **WELDING Bricklayer** | Launches any player into the air with a brick, orbits pieces around you, deletes your loose pieces | `RightShift` |

### Free Draw / Spray Paint!

1. Paste a direct link to an image (png, jpg, webp or gif).
   In Spray Paint! you can also use the **Text** tab, or the **Avatar** tab: type a username or display name and it loads that player's avatar (full body, upper body or head).
2. Press **Preview** / **Load** to see what it will look like.
3. Press **Draw** (Free Draw) or **Place** then **Paint!** (Spray Paint!).
4. **Stop** pauses. Pressing Draw / Paint! again carries on where it stopped.

### Hide In Paintings

- **Blend In** (`B`): move into your spot, press it, then press the game's Submit. Your whole figure takes the exact colours of the painting behind it.
- **Undo blend**: puts your previous paint back.
- **Show opponent** (`V`): while you seek, your opponent's hidden figure gets a pulsing outline. Only you can see it.

### WELDING Bricklayer

- **Launch** (`L`): pick a player in the list (you're at the top) and press Launch. A brick (you) or steel plate (anyone else) slides under their feet, rises at **Speed** for **Rise time**, then drops into the void so they keep flying up.
- **Orbit** (`O`): pieces circle you and fling whoever they hit. It keeps spawning every item type (bricks, plates, boards, planks, beams, glass, windows) until the server won't spawn any more, and **Bring nearby loose parts** adds anyone's non-cemented pieces lying near you. Turning it off sends your pieces into the void and drops other people's.
- **Delete my loose pieces** (click twice): removes every loose piece of yours for everyone. Cemented pieces can only be broken with the game's hammer.

## Notes

- Some games (Free Draw) don't allow teleporting from other creators' games. If **Join** says so, open that game from the Roblox app and run the script there.
- Your executor needs `request`, `writefile`, `getcustomasset`, `getconnections` and `queue_on_teleport` (most do). The bricklayer orbit works best with `isnetworkowner`.
