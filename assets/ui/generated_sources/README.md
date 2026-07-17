# Casual systems UI icons

`casual_system_icons_chroma.png` is the retained source sheet generated on
2026-07-17 with the built-in ChatGPT image generator.

Style reference:

- `res://assets/ui/ingredient_icons_transparent.png`

Generation constraints:

- 5 columns × 4 rows, in the semantic order exposed by `GameIcons`;
- low-poly cartoon rendering with a thick near-black outline;
- flat `#ff00ff` chroma-key background;
- no text, watermark, cell border, or icon overlap.

Runtime processing:

1. Chroma key removed with the imagegen skill's `remove_chroma_key.py`
   (`--auto-key border --soft-matte --despill`).
2. Connected components were assigned to their intended grid cell, normalized
   to a centered 256 × 256 transparent canvas, and exported individually under
   `res://assets/ui/generated/casual_system/`.
3. `casual_system_icons_runtime.png` is a transparent 5 × 4 atlas assembled
   from those normalized icons. The larger
   `casual_system_icons.png` is the background-removed source-resolution sheet.

The source is retained so the runtime crops can be regenerated without
repeating image generation.
