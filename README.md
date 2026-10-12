# Drawing Hub

One script that auto-draws any image in Roblox drawing games. Paste a picture link, press Draw.

## Load it

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/octobertm6/Drawing-Hub/main/drawing_hub.lua"))()
```

Run it anywhere. A small window lists the games:

- **In one of the games already?** Its drawing tool opens by itself.
- **Somewhere else?** Press **Join game** on a card. It teleports you there and opens the tool when you arrive.

`RightCtrl` shows or hides the hub window.

## Games

| Game | What it does | Window key |
| --- | --- | --- |
| **Free Draw** | Draws the picture as parts on the big floor canvas | `RightShift` |
| **Spray Paint!** | Sprays the picture onto walls with the game's own spray can | `RightShift` |
| **Paint to Get Rich** | Paints the picture onto your easel (open your easel first) | `RightShift` |

### How to draw

1. Paste a direct link to an image (png, jpg, webp or gif).
2. Press **Preview** to see what it will look like.
3. Press **Draw** (Free Draw / Paint to Get Rich) or **Place** then **Paint!** (Spray Paint!).
4. **Stop** pauses. Pressing Draw again carries on where it stopped.

## Notes

- Some games (Free Draw) don't allow teleporting from other creators' games. If **Join** says so, open that game from the Roblox app and run the script there.
- Your executor needs `request`, `writefile`, `getcustomasset` and `queue_on_teleport` (most do).
- **Paint to Get Rich:** the server drops strokes sent faster than about 60 per second, so keep **Strokes/s** at 60 or lower or the picture gets holes.
