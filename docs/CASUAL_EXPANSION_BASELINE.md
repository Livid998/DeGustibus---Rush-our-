# Casual Systems Expansion - Baseline

Data baseline: 17 luglio 2026

- Branch di lavoro: `codex/casual-systems-expansion`
- Commit di partenza: `7e96bc7 Improve pizza visual presentation and consistency`
- Motore: Godot `4.7.stable.official.5b4e0cb0f`
- Renderer da preservare: Mobile / Web GL Compatibility
- Worktree iniziale: pulito
- Versione salvataggio iniziale: `GameState.SAVE_VERSION = 9`

## Test baseline

| Scena | Risultato |
| --- | --- |
| `tests/test_runner.tscn` | 366 controlli, 0 fallimenti |
| `tests/asset_load_check.tscn` | 103 path unici, 0 fallimenti |
| `tests/service_smoke.tscn` | PASS, 1 cliente servito |
| `tests/customer_flow_smoke.tscn` | PASS, 12 clienti serviti, coda 0, attivi 0 |
| `tests/maintenance_smoke.tscn` | PASS, 15 controlli |
| `tests/agent_stress.tscn` | PASS, 10 serviti, clearance minima +0,098 |
| `tests/navigation_adversarial.tscn` | PASS, 21 controlli |
| `tests/customer_exit_flow.tscn` | PASS, 6 controlli |
| `tests/dish_visual_consistency.tscn` | PASS, 69 controlli |
| `tests/status_bubble-smoke.tscn` | PASS, 12 controlli |
| `tests/ui_glyph_audit.tscn` | PASS, 65 controlli |

Questa baseline deve restare verde durante ogni milestone. I nuovi test si aggiungono senza rimuovere o indebolire quelli esistenti.

## Chiarimento vincolante al punto 19

La macchina del gelato:

- mantiene la scala e le dimensioni visive correnti;
- diventa un attachment `surface` che richiede un supporto `worktop`;
- segue le stesse regole di appoggio dei forni;
- non viene ridimensionata né nei nuovi layout né durante la migrazione dei salvataggi v9.
