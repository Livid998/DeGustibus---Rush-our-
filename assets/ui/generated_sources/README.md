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

Exact generation request retained for provenance:

> Use `assets/ui/ingredient_icons.png` as the binding visual reference. Create
> one coherent 5×4 sprite sheet containing, left-to-right and top-to-bottom:
> sun, moon, rush-hour burst, room beauty, dirt, mouse, insect, delivery truck,
> ambient-storage crate, refrigerated storage, chef, waiter, handyman,
> profile/avatar, extractor hood, small portion, undercooked, overcooked,
> burned food, and poor plating. Match the same soft low-poly 3D illustration,
> rounded forms, very thick charcoal outline, simplified faceted shading, warm
> top light, small highlights and saturated non-neon palette. Center and fully
> contain every subject with 12–15% margin. No text, emoji, watermark, square
> border, cell overlap or photorealism. Use a uniform `#ff00ff` chroma-key
> background so every icon can be exported as transparent RGBA.

Runtime processing:

1. Chroma key removed with the imagegen skill's `remove_chroma_key.py`
   (`--auto-key border --soft-matte --despill`).
2. Connected components were assigned to their intended grid cell, normalized
   to a centered 256 × 256 transparent canvas, and exported individually under
   `res://assets/ui/generated/casual_system/`.
3. `casual_system_icons_runtime.png` is a transparent 5 × 4 atlas assembled
   from those normalized icons. The larger
   `casual_system_icons.png` is the background-removed source-resolution sheet.

The original batch sheet is the authoritative source rather than twenty
duplicated source files: it preserves the exact generated pixels and their
shared visual context. The individually named transparent exports are the
stable runtime/source crops and can be regenerated deterministically from this
sheet without repeating image generation.
