# Limitazioni note

- La distribuzione mobile è una PWA, non un binario iOS/Android firmato. Su iOS
  l’installazione va eseguita da Safari con `Aggiungi alla schermata Home`.
- Salvataggi, profilo e impostazioni sono locali all’origin del browser. Non
  esistono ancora account, cloud save o sincronizzazione fra dispositivi.
- Il mercato usa intenzionalmente `MockMarketProvider`: offerte, qualità e
  scadenze sono simulate offline e non esiste un backend remoto.
- Il creator avatar seleziona preset GLTF completi; non espone slider finti per
  capelli o volto perché i modelli sorgente non sono modulari.
- Topi e insetti usano visual procedurali leggeri per non aumentare memoria e
  draw call della PWA; non sono modelli animati dedicati.
- Le azioni specialistiche prive di una clip nel character pack riusano
  `PickUp`, `Walk_Carry` o la migliore animazione compatibile.
- La qualità `Massima · PC` non è consigliata su iPad. Il profilo automatico
  riduce risoluzione 3D e ombre e il safe mode recupera una sola volta da
  `webglcontextlost`, ma non può compensare altre schede 3D che esauriscono la
  memoria del dispositivo.
- Non è presente una libreria musicale completa; il feedback audio resta
  procedurale e locale.
