# Asset manifest

## Audit della sorgente

Sorgente ricevuta: `C:\Users\Livis\Desktop\modelli 3d.zip`, 316.160.927 byte.

L'archivio contiene una cartella con 25 elementi: 20 ZIP, 2 RAR, 1 Unity package, 1 file Blender e la directory radice. Sono stati enumerati tutti i contenuti e sono stati estratti gli archivi utilizzabili. Il corpus di audit comprende circa 18.761 file, tra cui 4.005 PNG, 2.781 FBX, 1.394 OBJ, 1.207 GLB e 973 GLTF.

Pacchetti presenti:

- Bakery Asset Pack; Cooking Assets; Food Mega Pack Free; Low Poly Food Pack/Foods.
- KayKit Furniture Bits e Restaurant Bits (Extra e Source).
- Kenney Food Kit, Input Prompts e UI Pack.
- NewLuaStudios Food Pack FBX e Unity package; Stylized Sandwich.
- Tiny Treats Baked Goods, Bakery Interior, Charming Kitchen, House Plants e Pleasant Picnic.
- Quaternius character pack, Cleaning Day Essentials e Grill.
- Un file `food.blend` e una conversione GLB di Restaurant Bits.

Le estrazioni di `FoodMegaPack_Free.zip` e `LowPolyFoodPack.zip` contengono alcuni percorsi oltre i limiti storici di Windows. La conversione `Restaurant Bits.undefined-glb.zip` contiene inoltre collisioni di nomi che differiscono solo per maiuscole/minuscole. Questi casi sono stati registrati ma non usati: la demo usa i pacchetti GLTF originali completi e le relative texture/binari.

## Sottoinsieme inserito nel progetto

La cartella `assets/` contiene 332 file sorgente/import descriptor complessivi, organizzati così:

| Cartella | File | Uso |
| --- | ---: | --- |
| `characters/` | 20 | 10 personaggi GLTF e relativi binari |
| `environment/` | 56 | pavimenti, pareti, porta, tavoli, sedie e arredi |
| `equipment/` | 73 | postazioni cucina e relativi binari/texture |
| `food/` | 126 | ingredienti, preparazioni, piatti e texture |
| `decor/` | 22 | piante e decorazioni |
| `ui/` | 28 | texture Kenney, quattro sorgenti illustrate fornite dall’utente, atlanti trasparenti derivati e import descriptor |
| `licenses/` | 7 | copie locali delle licenze originali |

I numeri includono `.import`, `.bin` e texture necessarie a rendere i GLTF autosufficienti. La cache `.godot/` è esclusa dal repository.

## Provenienza per categoria

- Personaggi: Quaternius, modelli `Chef_*` e `Casual*`.
- Sala e cucina: KayKit Restaurant Bits e Furniture Bits.
- Postazioni e cibo: KayKit Restaurant Bits, Tiny Treats Bakery Interior e Kenney Food Kit.
- Piante: Tiny Treats House Plants.
- Componenti UI: Kenney UI Pack.
- Icone Album/Menu/pass: tavole raster 1254×1254 fornite direttamente dall’utente, conservate in `assets/ui/ingredient_icons.png` e `assets/ui/recipe_icons.png`.
- Navigazione e lucchetto: sorgenti conservate in `assets/ui/navigation_icons_source.png` e `assets/ui/lock_icon_source.png`.
- Il runtime usa le versioni RGBA derivate `ingredient_icons_transparent.png`, `recipe_icons_transparent.png`, `navigation_icons.png` e `lock_icon.png`. Il ritaglio, la rimozione del fondo e la centratura sono riproducibili tramite `tools/extract_icon_atlases.py` e non usano generazione grafica.

Il personaggio chef contiene 17 clip rilevate: Death, Defeat, Idle, Jump, PickUp, Punch, RecieveHit, Roll, Run, Run_Carry, Shoot_OneHanded, SitDown, StandUp, SwordSlash, Victory, Walk e Walk_Carry. Il resolver usa nomi case-insensitive e ripiega su `Idle` quando una clip non esiste.

## Regole di import

I percorsi usati dai cataloghi sono sempre `res://assets/...`. Per ogni GLTF esterno sono stati copiati anche il relativo `.bin` e le texture condivise. Un test dedicato carica tutti i path dichiarati nei JSON; la scena principale è stata reimportata e avviata con renderer Mobile senza errori.
