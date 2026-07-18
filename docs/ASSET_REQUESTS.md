# Casual expansion asset audit

This file records the visual asset decision for each casual-expansion system.
Existing project art is preferred; generated art is used only for true gaps.

## Reused project art

- Ingredient, preparation, recipe, navigation, lock, currency, reputation,
  rarity, speed, playback, priority, rotation and zoom icons.
- Customer/staff bubble atlases for conversation, waiting, payment, service,
  cleaning, order changes and generic warnings.
- Existing restaurant, city, nature, cleaning, character and equipment models.
- The Restaurant Bits extractor hood model for the ventilation attachment.

## Generated UI gaps

The following standalone icons were generated from
`assets/ui/ingredient_icons_transparent.png` as the style reference and are
stored under `assets/ui/generated/casual_system/`:

- day/night: sun, moon, rush;
- ambience/maintenance: beauty, dirt, mouse, insect;
- logistics: delivery truck, ambient storage, refrigerated storage;
- staff/profile: chef, waiter, handyman, avatar;
- construction: extractor hood;
- quality defects: small portion, undercooked, overcooked, burned and poor
  plating.

The retained source, processing notes and transparent atlas are documented in
`assets/ui/generated_sources/README.md`.

## Open external asset requests

None. Lightweight pest visuals may be built from procedural primitives as
allowed by the implementation brief, so no additional user-supplied model pack
is currently required.
