# Workspace Colors

A workspace can carry one color from a fixed palette, so windows are easy to tell apart at a glance. The color belongs to the workspace, not to a window: a saved workspace stores it in its `workspace.json`, and every window reads the same value. An ephemeral workspace keeps its color in memory until it is saved. To mark a window, the color appears only on the workspace sticker in Agent mode: in the strip above the sidebar or, while the sidebar is hidden, in the titlebar. Other modes and the window title do not show it. Manage Workspaces and the dots in the workspace picker also show the color, including for workspaces that no window has open. See [Where it shows](#where-it-shows).

## Saved contract

- File: the workspace's `workspace.json` (owner: `WorkspaceModel`, `Sources/RepoPrompt/Features/Workspaces/WorkspaceModel.swift`).
- Key: top-level `color`. The value is one of the ids in the table below.
- None: the key is absent. The app never writes an empty string or `null`.
- Ephemeral workspaces: the color is not written while the workspace is ephemeral, so other windows and external readers do not see it.
- Readers must treat an unknown id as None. The app itself keeps an unknown id on re-save, so a value written by a newer build survives.
- The app trims and lowercases the value when it reads the file.
- Builds from before this feature ignore the key and drop it the next time they save that workspace.
- The value is an id, not a hex color, so the palette can be retuned without migrating files.

## Palette

The order below is the menu order. Light values are for light appearances and dark values for dark appearances; the app renders these exact sRGB values (`WorkspaceColor`, `Sources/RepoPrompt/Features/Workspaces/WorkspaceColor.swift`).

| id | Display name | Light hex | Dark hex |
|---|---|---|---|
| `red` | Red | `#B83A3A` | `#E06C6C` |
| `orange` | Orange | `#C8612C` | `#E38C5A` |
| `yellow` | Amber | `#AE7D16` | `#DCB750` |
| `lime` | Lime | `#708D28` | `#A6C564` |
| `green` | Green | `#2C7D46` | `#62B678` |
| `teal` | Teal | `#177A7A` | `#49B5B0` |
| `aqua` | Sky | `#2582B8` | `#63BCE8` |
| `blue` | Blue | `#305FBD` | `#6893E6` |
| `indigo` | Indigo | `#4343A2` | `#6F76CC` |
| `violet` | Violet | `#6E49B8` | `#A485E4` |
| `magenta` | Plum | `#983A84` | `#D076BA` |
| `pink` | Rose | `#C74A6E` | `#E8839E` |
| `brown` | Brown | `#8A6246` | `#BA9476` |
| `grey` | Gray | `#70757D` | `#9A9FA8` |

For compatibility with existing readers, the saved ids stay the same: `yellow`, `aqua`, `magenta`, `pink`, and `grey` are shown as Amber, Sky, Plum, Rose, and Gray.

## Where it shows

- The workspace sticker, a 20 pt rounded square filled with the color. It sits in the strip above the Agent sidebar: on macOS 26 and later at the strip's trailing edge, on earlier macOS as the last button, after New Session. While the sidebar is hidden, it moves to the titlebar beside the window's close, minimize and zoom buttons, after the sidebar toggle and New Session. With None it shows a dashed outline. The System workspace has no sticker.
- An 8 pt dot before workspace names in the workspace picker. With None, there is no dot. The window title shows no color.
- A 16 pt sticker at the start of each Manage Workspaces row. Consolidated recovery copies show the dot instead, and only when a color is set.

To set a color, click the sticker and choose a swatch. The color applies at once and the picker stays open. In Manage Workspaces, click a row's sticker, or right-click the row and choose from the `Workspace Color` section. The System workspace and consolidated recovery copies cannot be colored.

## Not exposed over MCP

MCP tools do not report or change the color. Adding it to `manage_workspaces` or `bind_context` results would change the MCP contract and needs its own approval.
