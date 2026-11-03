Follows [BUILDING.md](BUILDING.md) as of v1.0.2

# Compilare dal codice sorgente

Il launcher (vedi il [README](README.it.md)) esegue gli stessi script che lanceresti da terminale. Questa pagina descrive la procedura manuale, pensata per gli utenti esperti, per lo sviluppo o per i casi in cui il launcher non è utilizzabile: gli strumenti necessari, il tuo file `prod.keys` e la creazione del file IPA da terminale. Le regole per contribuire al progetto si trovano in [CONTRIBUTING.it.md](CONTRIBUTING.it.md).

## Ottenere gli strumenti

Questo è il percorso da riga di comando che il launcher esegue automaticamente per te. Il sistema di compilazione è quello del progetto upstream. Segui il [README](https://github.com/seedds/nxnative) upstream per installare Xcode, gli strumenti di Homebrew e i pacchetti Python, quindi crea il pacchetto IPA.

```bash
git clone https://github.com/<tuo-utente>/NX2Apple.git
cd NX2Apple
python3 tools/engine.py sync                      # scarica il motore (nxnative al commit fissato più le nostre patch) in engine/, circa 80 MB
brew bundle --file=Brewfile                       # xcodegen, zstd, spirv-cross, glslang (controllato dallo script NSP), .NET SDK
python3 -m venv .venv                             # il Python di Homebrew rifiuta le installazioni pip globali (PEP 668)
.venv/bin/python -m pip install lz4 capstone fonttools zbic nsz "backports.zstd; python_version < '3.14'"
source .venv/bin/activate                         # fa sì che il comando python3 successivo usi il venv (da eseguire in ogni nuovo terminale)
```

## Cosa ti serve su disco

Tre elementi, nessuno dei quali è incluso nel repository:

| Cosa | Da dove proviene | Usato da |
|---|---|---|
| **`prod.keys`** | estratto dalla **tua console personale** (vedi sotto) | l'estrattore, per decifrare il tuo gioco |
| **I file NSP del gioco** | estratti dalla tua cartuccia o dai tuoi acquisti sull'eShop | l'estrattore |
| **Xcode + iOS SDK** | App Store / Apple Developer | la compilazione dell'app |

`prod.keys` è il set di chiavi della console — un file di testo composto da righe `nome = valore esadecimale` (circa 230 voci:
`master_key_xx`, `titlekek_xx`, `header_key`, `key_area_key_application_xx`, …). Tutti gli strumenti homebrew per Switch
leggono questo formato. **Non** è legato a un gioco specifico: un singolo file `prod.keys` decifra
qualsiasi tuo gioco. L'unico requisito è che il file contenga le chiavi per la generazione di chiavi
(versione del firmware) con cui il gioco è stato impacchettato — un dump recente copre tutti i giochi commerciali.

Dove posizionarlo dipende da te. Puoi passare il percorso con l'opzione `-k`:

```bash
# qualsiasi struttura di cartelle va bene, ad es.
~/keys/prod.keys
# oppure tienilo accanto ai file NSP del gioco
~/Games/Hades2/prod.keys
```

```bash
python3 engine/scripts/build_ipa_from_nsp.py ~/Games/Hades2 -k ~/keys/prod.keys
```

La procedura di estrazione delle chiavi è ampiamente documentata nella community homebrew di Switch (Lockpick_RCM da una
console modificata è il metodo abituale). Questo repository non tratta quel passaggio e non include alcuno strumento per farlo.
Due note pratiche basate su dump reali:

- **Righe malformate.** Alcuni strumenti di dump generano righe il cui valore esadecimale ha una lunghezza errata (33 righe
  `master_kek_source_*` non valide in un dump reale), il che porta lo strumento di estrazione a rifiutare l'intero
  file. Elimina le righe problematiche conservando una copia di backup del file originale.
- **Aggiornamenti.** Il ticket di un file NSP di aggiornamento può utilizzare una generazione di chiavi più recente rispetto al gioco base.
  L'estrattore legge la title key direttamente dal common ticket all'interno di ciascun NSP, quindi in pratica
  entrambi vengono decifrati senza problemi purché `prod.keys` sia ragionevolmente aggiornato — verificato qui con un gioco
  base sulla generazione 15 e il relativo aggiornamento sulla 16, usando un file di chiavi che arrivava solo alla 15.

Il pacchetto `backports.zstd` è necessario per i dizionari zstd di Tears of the Kingdom. Gli altri giochi non lo utilizzano.

## Compilare il file IPA

Lo script di compilazione principale crea per impostazione predefinita un **IPA leggero ("slim")** (senza RomFS al suo interno, poiché l'app legge i dati del gioco dalla relativa cartella sul dispositivo, `Documents/games/<id>/`), quindi il comando mostrato sopra lo ha già generato. Per ricreare solo il pacchetto in un secondo momento:

```bash
GAME=<title id> W=<cartella di lavoro> PATCHED=<cartella patchata> \
  ROMFS=<cartella RomFS> MSL_IOS=<cartella shader> \
  engine/dm/ios/tools/build_ipa.sh <output.ipa>
```

L'opzione `--full-romfs` (oppure `DM_FULL_ROMFS=1`) inserisce invece la RomFS direttamente dentro il pacchetto — che è il comportamento predefinito
upstream, sensato solo per i giochi di piccole dimensioni.

La RomFS non deve più essere divisa in un archivio a frammenti: il processo di compilazione scrive i dati del gioco in un unico file `romfs.img`. Gli archivi a frammenti creati con le versioni precedenti (`romfs.idx` accompagnato da `romfs.00`, `romfs.01`, …) non vengono più letti: il launcher segnala una cartella di questo tipo come priva di dati di gioco e i dati vanno inviati nuovamente una sola volta sotto forma di `romfs.img`.
