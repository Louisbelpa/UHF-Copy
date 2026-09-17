# UHF-Copy

Lecteur IPTV natif pour l'écosystème Apple (iOS, iPadOS, tvOS, macOS), inspiré de
[UHF — Love your IPTV](https://apps.apple.com/fr/app/uhf-love-your-iptv/id6443751726).

Sources visées : playlists **M3U/M3U8**, comptes **Xtream Codes**, puis
Plex / Jellyfin / Emby.

> L'application est un **lecteur**. Elle ne fournit ni n'héberge aucun contenu :
> l'utilisateur apporte ses propres sources.

## État

Toute la logique non graphique est écrite et testée : **173 tests verts** (Swift 6.1).
Une source peut être téléchargée, analysée, stockée, resynchronisée, recherchée et
rapprochée de son guide — sans interface. C'est délibéré : voir `docs/SPIKE.md`.

| Paquet | Contenu | État |
|---|---|---|
| `Packages/UHFCore` | Modèles, `StableKey`, normalisation des libellés | ✅ 14 tests |
| `Packages/UHFSources` | M3U, Xtream, XMLTV, catch-up, appariement EPG, choix du moteur | ✅ 96 tests |
| `Packages/UHFStore` | Persistance GRDB/SQLite, resync, FTS5, guide, favoris | ✅ 47 tests |
| `Packages/UHFSync` | Orchestration : téléchargement → analyse → base → appariement | ✅ 16 tests |
| `Packages/UHFPlayback` | Moteurs `AVPlayer` / `VLCKit` et leur arbitrage | ⚠️ non compilé (exige un Mac) |
| `Tools/uhf-probe` | Diagnostic en ligne de commande | ✅ compilé |

**Ce qui manque pour avoir une app : l'interface.** Aucun projet Xcode, aucune vue
SwiftUI, aucune cible iOS ou tvOS. Le détail de ce qui reste est en fin de
`docs/PLAN.md`.

## Démarrage

```bash
# Toutes les suites de tests
./Scripts/test-all.sh            # ou: ./Scripts/test-all.sh release

# Analyser une playlist, sans interface ni simulateur
swift run --package-path Tools/uhf-probe uhf-probe m3u <fichier|url>
swift run --package-path Tools/uhf-probe uhf-probe xtream 'http://srv:8080/get.php?username=…&password=…'
swift run --package-path Tools/uhf-probe uhf-probe epg <fichier|url>
swift run --package-path Tools/uhf-probe uhf-probe match <m3u> <epg>
```

Sous **Linux uniquement**, lancer d'abord `./Scripts/build-sqlite-linux.sh` : GRDB
utilise `sqlite3_snapshot_*`, absent de la libsqlite3 d'Ubuntu. La SQLite d'Apple
l'active, le problème ne se pose donc ni sur Mac ni sur appareil.

## Un rafraîchissement complet, en un appel

```swift
let database = try UHFDatabase.onDisk(at: UHFDatabase.defaultURL())
let service  = PlaylistSyncService(database: database,
                                   credentialsProvider: keychain.credentials)

let report = try await service.refresh(playlist: playlist) { phase in
    statusLabel = phase.label        // « Import du guide… 40 000 programmes »
}

report.channels        // ajoutées / mises à jour / supprimées
report.epgMatchRate    // part de chaînes rattachées au guide
report.warnings        // abonnement bientôt expiré, films indisponibles…
```

Puis, côté lecture :

```swift
let store = ChannelStore(database)
let visible = try store.channels(playlistID: playlist.id, group: "FR | Sport")
let results = try store.search("canal+")                       // < 30 ms sur 100 000 chaînes
let guide   = try EPGStore(database).nowNext(channelKeys: visible.map(\.stableKey),
                                             playlistID: playlist.id)
```

## Ce qui est couvert

- **M3U étendu** : `group-title` / `#EXTGRP`, `#EXTVLCOPT` et `#EXTHTTP` convertis en
  en-têtes HTTP, en-têtes inline après le `|`, catch-up, `tvg-shift`. Lecture en flux,
  mémoire constante, poursuite de l'import sur entrée malformée.
- **Xtream Codes** : compte, catégories, live, films, séries, EPG court. Décodage
  tolérant aux types incohérents des panneaux, erreurs traduites en messages
  compréhensibles.
- **XMLTV** : parsing SAX en flux, gunzip par blocs, fenêtre temporelle, choix de
  langue.
- **Catch-up** : conventions `default`, `append`, `shift`, `flussonic` et Xtream.
- **Persistance** : resynchronisation non destructive, recherche FTS5, guide, favoris,
  dossiers à code, renommages, progression, rappels, export/import iCloud.
- **Choix du moteur de lecture** : extension, puis type MIME, puis signature des
  premiers octets — parce que les serveurs IPTV mentent sur les deux premiers.

### La garantie que les tests protègent

Un fournisseur qui réattribue ses `stream_id` — le cas courant — ne fait perdre ni
favoris, ni renommages, ni progression. Un favori dont la chaîne disparaît n'est pas
effacé. Une correspondance EPG corrigée à la main n'est jamais écrasée. Un rappel
survit au remplacement intégral du guide. Et une playlist tronquée par un serveur
défaillant est refusée avant d'écraser le catalogue.

## Performance mesurée

Build `release`, x86_64, base sur fichier. Cibles : `docs/PLAN.md` §6.

| Mesure | Résultat | Cible |
|---|---|---|
| M3U, 100 000 chaînes (16,5 Mo) | 4,6 s | < 5 s |
| Import en base, 100 000 chaînes | 4,8 s | — |
| XMLTV, 100 000 programmes (27 Mo) | 1,5 s (~18 Mo/s) | 200 Mo < 60 s |
| Import EPG en base, 100 800 programmes | 0,64 s | — |
| Recherche FTS5 sur 100 000 chaînes | 15 – 67 ms | < 50 ms* |
| Now/next sur 60 chaînes visibles | 13,5 ms | 60 fps |
| Page de catégorie (100 lignes) | 1,4 ms | 60 fps |
| Taille de la base | 28,4 Mo | — |

\* 67 ms correspond au pire cas, une saisie de deux lettres qui apparie la totalité du
catalogue. Un minimum de deux caractères et l'anti-rebond de 200 ms de l'interface
placent l'usage réel dans la fourchette basse.

## Documentation

- 📄 **[`docs/PLAN.md`](docs/PLAN.md)** — plan de construction : stack, modèle de
  données, protocoles, roadmap chiffrée, contraintes App Store, et état d'avancement.
- 🔬 **[`docs/SPIKE.md`](docs/SPIKE.md)** — le spike de lecture à faire sur Mac, qui
  lève le seul risque technique bloquant du projet.

## Prochaine étape

Le spike de `docs/SPIKE.md`, sur un Mac avec Xcode. Tant qu'il n'est pas passé,
construire l'interface serait bâtir sur une hypothèse non vérifiée.
