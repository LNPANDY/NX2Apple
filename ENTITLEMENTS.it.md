Follows [ENTITLEMENTS.md](ENTITLEMENTS.md) as of v1.0.2

# Limite di memoria esteso (Increased Memory Limit)

L'app richiede il permesso `com.apple.developer.kernel.increased-memory-limit`. Lo script `build_ipa.sh` scrive direttamente
il file degli entitlement (`DM_ENTITLEMENTS=<plist>` permette di specificarne un altro, mentre un valore vuoto non ne imposta alcuno): all'interno della
firma segnaposto dell'IPA non firmato (vedi sotto) e, per un progetto Xcode preparato, nel file `Gen/DmIOS.entitlements`
tramite la voce `CODE_SIGN_ENTITLEMENTS` del suo `Gen/dm.xcconfig`.

## Perché è importante

iOS assegna a ogni app un budget massimo di memoria fisica per processo e la termina immediatamente (jetsam, SIGKILL, nessun crash
report) quando lo supera. Sugli iPhone attuali tale budget è di circa **3,3 GB** senza questo
entitlement e di **6–8 GB** quando è attivo, a seconda del dispositivo.

Valori misurati qui, entrambi su un iPhone con 12 GB di RAM:

| Gioco | Picco memoria residente | Margine residuo (headroom) | Risultato |
|---|---|---|---|
| Tears of the Kingdom | 3.342 MB | 33 MB | terminato all'ingresso nella mappa del mondo |
| Hades II | — | — | richiede un heap di 3,10 GB, proprio al limite del budget |

Abbassare la scala di rendering a 0.5 non ha cambiato il risultato con Tears of the Kingdom, segno che il limite riguarda
l'heap del gioco (guest) e non la GPU. L'unico modo per superarlo è disporre di un budget di memoria più elevato.

## Cosa serve affinché l'entitlement sia attivo

Sono necessarie due condizioni, entrambe obbligatorie:

1. **La firma deve includerlo.** Lo script `build_ipa.sh` produce un pacchetto non firmato (sarà lo strumento di sideloading a rifirmarlo), quindi ciò che
   conta è che il sideloader copi gli entitlement aggiuntivi presenti nell'IPA dentro la nuova firma
   anziché scartarli.
2. **L'App ID deve averlo abilitato.** Il profilo di provisioning generato da uno strumento di sideloading include solo
   gli entitlement per i quali quell'App ID è stato registrato presso Apple. Lo strumento deve quindi richiederlo ad Apple.

## Quali strumenti di sideloading lo mantengono

Dati riportati da [playport.dev](https://playport.dev/) (un altro progetto con la medesima esigenza):

| Strumento di sideloading | Mantiene l'entitlement |
|---|---|
| AltStore Classic 2.2 o successivo | Sì |
| Impactor (da computer) | Sì |
| Xcode con un Personal Team | Sì |
| SideStore 0.7.0 con ID Apple gratuito | Non per impostazione predefinita — vedi sotto |
| Sideloadly e altri | Verifica lo strumento. Sideloadly non lo abilita |

## SideStore con un ID Apple gratuito

L'entitlement viene associato all'App ID, quindi una volta impostato sopravvive ai rinnovi settimanali. Procedura una tantum:

1. Installa questa app tramite SideStore, in modo che il relativo App ID venga creato sui server Apple.
2. Installa tramite sideloading **GetMoreRam** ed effettua l'accesso con lo stesso ID Apple utilizzato da SideStore.
3. In GetMoreRam apri **App IDs**, tocca **Refresh**, seleziona l'App ID di questa app e poi tocca
   **Add Increased Memory Limit**.
4. Reinstalla l'app da SideStore (l'app viene aggiornata sul posto e la cartella `Documents/`, l'archivio RomFS e i
   salvataggi vengono mantenuti).
5. Verifica: il file `Documents/log.txt` dovrebbe ora mostrare un valore molto più elevato alla voce `headroom to the system memory limit`
   nelle righe `memory up to frame N`. GetMoreRam occupa uno dei tre slot app disponibili con un ID Apple gratuito, quindi
   puoi eliminarla subito dopo se ti serve liberare lo slot.

## Come verificare se è attivo

Avvia il gioco, lascialo girare per qualche centinaio di fotogrammi e poi leggi la riga relativa alla memoria in `Documents/log.txt`:

```
memory up to frame 600: resident 3342 MB, ... headroom to the system memory limit 33 MB
```

La somma `resident + headroom` corrisponde al budget imposto dal kernel:

- ≈ 3.375 MB → l'entitlement non è attivo.
- ≈ 6.000–8.000 MB → l'entitlement è attivo.

La funzione `os_proc_available_memory()` è ciò che produce quel valore (`dm/gfx/nvn/nvn_mtl.m`) e indica
la distanza rimanente rispetto al limite massimo imposto dal kernel.

## Perché la firma segnaposto è fondamentale

Lo script `build_ipa.sh` compila un pacchetto non firmato. Uno strumento di sideloading decide quali entitlement mantenere leggendoli
dalla firma che sta andando a sostituire — un binario completamente privo di firma non ne possiede alcuno, perciò la richiesta andrebbe persa indipendentemente
da ciò che si trova nel bundle. Lo script incorpora quindi l'entitlement tramite una
firma ad-hoc (`codesign --force --sign - --entitlements …`, che non richiede alcun certificato): lo strumento di
sideloading rimuove quella firma e la sostituisce con quella dell'utente, ma così facendo rileva l'entitlement e
lo conserva. Puoi verificare qualsiasi IPA compilato eseguendo:

```bash
codesign -d --entitlements :- Payload/DmIOS.app/DmIOS | grep increased-memory-limit
```

Risultato misurato qui (iPhone da 12 GB, AltStore Classic 2.3): prima dell'introduzione della firma segnaposto il budget era di
3.375 MB e Hades II veniva terminato all'ingresso in una scena più ampia. Dopo l'aggiunta della firma segnaposto il gioco gira regolarmente. Se il budget rimane fermo a
3.375 MB anche con un IPA firmato, il passaggio mancante riguarda l'App ID — abilita la capacità con uno strumento
come GetMoreRam (usando lo stesso ID Apple del sideloader, andando su App IDs → Refresh → seleziona l'app → Add
Increased Memory Limit), quindi reinstalla l'app affinché il profilo di provisioning recepisca la modifica.

## Percorso tramite Xcode

Un progetto preparato con `--prepare-xcode` include già l'entitlement (`Gen/DmIOS.entitlements`).
Con un Personal Team e un dispositivo reale collegato, puoi compilare direttamente da lì. Questo è l'unico percorso in cui l'app viene
firmata direttamente in fase di compilazione, evitando qualsiasi passaggio di rifirma successivo che possa perdere l'entitlement. La funzione
**Installa su** del launcher per Mac utilizza esattamente questo percorso.
