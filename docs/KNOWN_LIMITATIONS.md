# Limitazioni note

- La consegna è un vertical slice desktop/mobile-ready, non un’app Android/iOS firmata. Preset, SDK, firma e profiling su dispositivi fisici restano attività di pubblicazione.
- Il mercato usa intenzionalmente `MockMarketProvider`: offerte, qualità e scadenze sono simulate localmente e non esiste un backend remoto.
- Ogni gruppo cliente usa un unico agente di navigazione, pazienza, budget e profilo. I membri hanno però modelli, sedie e ordini individuali; in corridoi molto stretti possono ancora verificarsi sovrapposizioni transitorie tra agenti diversi perché non è presente avoidance dinamico agent-agent.
- Le animazioni disponibili vengono usate realmente tramite resolver case-insensitive; le azioni specialistiche prive di clip dedicata riutilizzano `PickUp` o la migliore animazione compatibile.
- L’audio è un feedback procedurale interno e non include musica o una libreria completa di effetti esterni.
- Le statistiche descrivono la sessione corrente. La voce spreco è predisposta, ma non esiste ancora un sistema completo di deterioramento o pietanze bruciate, quindi nella demo ordinaria resta a zero.
- Il numero di clienti è limitato per il vertical slice; non è ancora presente un object pool generalizzato per sessioni molto lunghe.
