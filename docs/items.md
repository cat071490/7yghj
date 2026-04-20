# Windrose Item Reference (for `wp.give`)

`wp.give` accepts full Unreal blueprint paths. Paths must:

- Start with `/`
- Include the duplicated class name (e.g. `BP_Flintlock.BP_Flintlock_C`)
- End with `_C`
- Be case-sensitive

Example:

```
wp.give HumanGenome /Game/Core/Items/Currency/BP_GoldCoin.BP_GoldCoin_C 100
wp.give Alice /Game/Core/Items/Weapons/Ranged/BP_Flintlock.BP_Flintlock_C
```

Quantity is optional (defaults to `1`) and only meaningful for stackable items. For non-stackable items (most weapons, armor), the server will either give one copy or fail depending on inventory capacity; requesting `qty > 1` will attempt repeated adds.

## How it works

`wp.give` calls `UWorld:SpawnActor` on the target player's world, placing the item actor at the player's feet. The game's own pickup logic then handles the rest. This sidesteps the inventory API entirely (the Windrose devs haven't exposed a server-side give method yet) and avoids the console-exec path that crashes Windrose dedicated servers.

For stackable items, the command spawns a single actor and sets a stack property (`StackCount`, `Count`, `Amount`, `Quantity`, `ItemCount`, or `StackSize` — whichever exists on the class) to the requested quantity. If no stack property exists, it falls back to spawning `qty` separate actors with small positional jitter so they don't clip into one point.

Max `qty` is 1000. The class path is resolved via `StaticFindObject`, so the blueprint must already be loaded — if you see "Blueprint class not found," the asset needs to be referenced somewhere in the game's loaded assets, or the path is wrong.

## Known blueprint paths

Source: [xmodhub — Windrose Item IDs & Spawn Codes](https://www.xmodhub.com/info/xmod-blog/windrose-item-ids-spawn-codes/). Verify against your server build before relying on any of these — third-party lists can go stale between patches.

### Currency

| Name | Blueprint path | Stackable |
|------|----------------|-----------|
| Gold Doubloons | `/Game/Core/Items/Currency/BP_GoldCoin.BP_GoldCoin_C` | yes |

### Resources

| Name | Blueprint path | Stackable |
|------|----------------|-----------|
| Refined Wood Plank | `/Game/Core/Items/Resources/BP_WoodPlank.BP_WoodPlank_C` | yes |
| Iron Ingot | `/Game/Core/Items/Resources/BP_IronIngot.BP_IronIngot_C` | yes |
| Heavy Sailcloth | `/Game/Core/Items/Resources/BP_Sailcloth.BP_Sailcloth_C` | yes |
| Gunpowder Keg | `/Game/Core/Items/Resources/BP_GunpowderKeg.BP_GunpowderKeg_C` | yes |

### Ammo

| Name | Blueprint path | Stackable |
|------|----------------|-----------|
| Standard Cannonball | `/Game/Core/Items/Ammo/BP_Cannonball.BP_Cannonball_C` | yes |
| Musket Ammo (Pouch) | `/Game/Core/Items/Ammo/BP_MusketBall.BP_MusketBall_C` | yes |
| Grape Shot (Ship) | `/Game/Core/Items/Ammo/BP_GrapeShot.BP_GrapeShot_C` | yes |
| Chain Shot (Ship) | `/Game/Core/Items/Ammo/BP_ChainShot.BP_ChainShot_C` | yes |

### Consumables

| Name | Blueprint path | Stackable |
|------|----------------|-----------|
| Major Healing Salve | `/Game/Core/Items/Consumables/BP_MajorSalve.BP_MajorSalve_C` | yes |
| Aged Rum Ration | `/Game/Core/Items/Consumables/BP_RumRation.BP_RumRation_C` | yes |
| Cooked Fish | `/Game/Core/Items/Consumables/BP_CookedFish.BP_CookedFish_C` | yes |
| Cure-All Antidote | `/Game/Core/Items/Consumables/BP_Antidote.BP_Antidote_C` | yes |

### Melee weapons

| Name | Blueprint path | Stackable |
|------|----------------|-----------|
| Iron Cutlass | `/Game/Core/Items/Weapons/Melee/BP_IronCutlass.BP_IronCutlass_C` | no |
| Captain's Rapier | `/Game/Core/Items/Weapons/Melee/BP_CaptainsRapier.BP_CaptainsRapier_C` | no |
| Boarding Axe | `/Game/Core/Items/Weapons/Melee/BP_BoardingAxe.BP_BoardingAxe_C` | no |
| Abyssal Trident (Legendary) | `/Game/Core/Items/Weapons/Melee/BP_AbyssalTrident.BP_AbyssalTrident_C` | no |

### Ranged weapons

| Name | Blueprint path | Stackable |
|------|----------------|-----------|
| Flintlock Pistol | `/Game/Core/Items/Weapons/Ranged/BP_Flintlock.BP_Flintlock_C` | no |
| Blunderbuss | `/Game/Core/Items/Weapons/Ranged/BP_Blunderbuss.BP_Blunderbuss_C` | no |
| Sniper Musket | `/Game/Core/Items/Weapons/Ranged/BP_SniperMusket.BP_SniperMusket_C` | no |

### Armor — head

| Name | Blueprint path | Stackable |
|------|----------------|-----------|
| Leather Tricorne Hat | `/Game/Core/Items/Armor/Head/BP_TricorneHat.BP_TricorneHat_C` | no |

### Armor — chest

| Name | Blueprint path | Stackable |
|------|----------------|-----------|
| Smuggler's Coat | `/Game/Core/Items/Armor/Chest/BP_SmugglerCoat.BP_SmugglerCoat_C` | no |
| Heavy Iron Cuirass | `/Game/Core/Items/Armor/Chest/BP_IronCuirass.BP_IronCuirass_C` | no |

### Armor — legs

| Name | Blueprint path | Stackable |
|------|----------------|-----------|
| Sea Captain's Boots | `/Game/Core/Items/Armor/Legs/BP_CaptainBoots.BP_CaptainBoots_C` | no |

### Traits / skills

Traits are a separate system. `wp.give` targets the inventory and will not grant traits. The upstream source notes a client-side `AddTrait <TraitID>` console command exists for client cheats but no server-side equivalent is wired here.

| Trait | Blueprint path |
|-------|----------------|
| Master Navigator (ship speed) | `/Game/Core/Traits/BP_Trait_MasterNavigator.BP_Trait_MasterNavigator_C` |
| Iron Lungs (underwater breathing) | `/Game/Core/Traits/BP_Trait_IronLungs.BP_Trait_IronLungs_C` |
| Gunslinger (fast reload) | `/Game/Core/Traits/BP_Trait_Gunslinger.BP_Trait_Gunslinger_C` |
| Ghost Blade (extra melee damage) | `/Game/Core/Traits/BP_Trait_GhostBlade.BP_Trait_GhostBlade_C` |
