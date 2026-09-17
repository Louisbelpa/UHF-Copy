# Plan de construction — lecteur IPTV type UHF

> Objectif : un lecteur IPTV natif Apple (iPhone / iPad / Apple TV, puis Mac), qui lit
> les playlists **M3U/M3U8** et les comptes **Xtream Codes**, avec EPG, favoris,
> VOD/séries, catch-up, PiP/AirPlay et un abonnement PRO.
>
> L'app est un **lecteur** : elle ne fournit aucun contenu. L'utilisateur apporte sa
> propre source. Ce point n'est pas cosmétique, il conditionne la validation App Store
> (voir §9).

---

## 0. Ce que fait UHF (référence fonctionnelle)

Relevé depuis la fiche App Store (sept. 2026) pour fixer la cible :

| Domaine | Fonctionnalités |
|---|---|
| Sources | M3U8, Xtream Codes, Plex, Jellyfin, Emby |
| Navigation | Recherche instantanée multi-playlists, catégories, favoris, renommage de chaînes, dossiers protégés par PIN |
| EPG | Guide moderne tactile, rappels/alertes, catch-up TV |
| Lecture | 4K HDR, Dolby Vision, Dolby Atmos, PiP, reconnexion auto |
| Diffusion | AirPlay, Chromecast |
| Extras | Client VPN intégré (WireGuard/OpenVPN), intégration Trakt, serveur DVR (Mac/Win/Linux) |
| Plateformes | iOS 16+, iPadOS, tvOS, macOS (M1+), visionOS |
| Modèle | Gratuit + PRO : 1,99 €/mois, 17,99 €/an, 49,99 € à vie. PRO = sync multi-appareils, sans pub, alertes EPG illimitées |

C'est **plusieurs années de travail cumulé**. Le plan ci-dessous découpe ça en lots
livrables, du plus structurant au plus accessoire.

---

## 1. Décisions de stack (et pourquoi)

### 1.1 Natif Swift, pas de cross-platform

**Recommandation : Swift 6 + SwiftUI, code partagé en packages SPM locaux.**

Tu viens du web, donc le réflexe serait React Native ou Flutter. À éviter ici, pour
trois raisons qui sont bloquantes, pas esthétiques :

- **tvOS est indispensable** dans cette catégorie (c'est là que se fait l'usage), et
  le support tvOS de React Native (`react-native-tvos`) / Flutter est marginal, mal
  maintenu, et ne gère pas correctement le *focus engine*.
- **HDR / Dolby Vision / Atmos / PiP / AirPlay** passent par `AVPlayer` +
  `AVPlayerViewController`. Tout wrapper ajoute une couche qui casse un de ces points.
- **Lecture MPEG-TS** (§4.1) demande d'embarquer un second moteur natif (libVLC).
  En cross-platform c'est du bridge natif de toute façon — autant tout écrire en Swift.

Ce que ton profil web te fait gagner malgré tout : le backend de sync (§7), le serveur
DVR (§8.3), les outils de build/CI, et la compréhension des APIs HTTP (Xtream est une
API REST classique, XMLTV c'est du parsing XML).

### 1.2 Découpage en modules

```
UHF/
├─ Packages/
│  ├─ UHFCore/          # modèles, DB, réglages — zéro dépendance UI
│  ├─ UHFSources/       # parseurs M3U, client Xtream, XMLTV, Jellyfin/Plex/Emby
│  ├─ UHFPlayback/      # abstraction moteur de lecture (AVPlayer / VLCKit)
│  └─ UHFDesign/        # composants partagés, tokens de couleur, images
├─ Apps/
│  ├─ iOS/              # UI iPhone/iPad (+ Mac Catalyst plus tard)
│  └─ tvOS/             # UI Apple TV — code UI **distinct**, logique partagée
└─ Tools/
   └─ uhf-dvr/          # démon d'enregistrement (phase 3)
```

Règle : **70 % de la logique dans les packages, 30 % d'UI par plateforme.** L'UI tvOS
n'est pas l'UI iOS redimensionnée — modèle d'interaction totalement différent
(focus + télécommande vs tactile). Ne cherche pas à mutualiser les vues.

### 1.3 Persistance : SQLite via GRDB, pas SwiftData

Contrainte dimensionnante : une playlist IPTV courante fait **10 000 à 150 000 chaînes**,
et un fichier XMLTV **50 à 500 Mo** représentant des millions de programmes.

- SwiftData / Core Data s'effondrent à cette échelle (inserts lents, mémoire).
- **GRDB** (SQLite) : inserts par lots de 5 000 en transaction, recherche instantanée
  via **FTS5**, index sur `(channel_id, start_at)` pour l'EPG. C'est la brique qui
  fait la différence entre « app fluide » et « app qui rame » sur ce type de produit.

| Choix | Retenu | Alternative écartée |
|---|---|---|
| Langage/UI | Swift 6 + SwiftUI | React Native / Flutter (tvOS inexploitable) |
| DB | GRDB / SQLite + FTS5 | SwiftData (ne tient pas la volumétrie) |
| Lecture | AVPlayer + VLCKit en repli | AVPlayer seul (ne lit pas le MPEG-TS brut) |
| Images | Nuke (cache disque agressif) | AsyncImage (pas de cache disque sérieux) |
| Réseau | URLSession + async/await | Alamofire (inutile ici) |
| Achats | StoreKit 2 natif | RevenueCat (0 % de commission en moins si Apple-only) |
| Sync | CloudKit (CKSyncEngine) | Backend maison (voir §7) |

---

## 2. Modèle de données

Schéma minimal (SQLite) :

```
playlists        (id, name, kind[m3u|xtream|jellyfin…], url, username, password,
                  user_agent, epg_url, last_sync_at, refresh_interval)
channels         (id, playlist_id, stream_id, name, logo_url, group_title,
                  tvg_id, tvg_shift, sort_index, catchup_mode, catchup_days,
                  catchup_source, is_adult)
channels_fts     -- table virtuelle FTS5 sur (name, group_title)
epg_channels     (id, playlist_id, xmltv_id, display_name, icon_url)
epg_programmes   (id, epg_channel_id, start_at, end_at, title, subtitle,
                  description, category, icon_url)   -- INDEX (epg_channel_id, start_at)
vod_items        (id, playlist_id, kind[movie|series], stream_id, title, year,
                  poster_url, rating, plot, container_ext, tmdb_id)
episodes         (id, series_id, season, number, title, stream_id, container_ext)
favorites        (id, target_type, target_key, folder_id, sort_index)
folders          (id, name, pin_hash, sort_index)
watch_progress   (target_key, position_ms, duration_ms, updated_at)
reminders        (id, programme_id, fire_at, notification_id)
channel_overrides(channel_key, custom_name, custom_logo, hidden)
```

Deux points qui évitent une réécriture plus tard :

1. **`target_key` stable et indépendant de l'ID du fournisseur.** Un resync de playlist
   réattribue souvent les `stream_id`. Utilise un hash de `(playlist_id, tvg_id ?? name normalisé)`.
   Sinon les favoris et l'historique sautent à chaque rafraîchissement — c'est la
   plainte n°1 sur ce type d'app.
2. **Le resync est un *merge*, pas un `DELETE` + `INSERT`.** Diff sur `target_key`,
   conserve `channel_overrides`, `favorites`, `watch_progress`.

---

## 3. Les sources : protocoles à implémenter

### 3.1 M3U étendu

```
#EXTM3U url-tvg="http://…/xmltv.php"
#EXTINF:-1 tvg-id="TF1.fr" tvg-name="TF1" tvg-logo="http://…/tf1.png"
           group-title="France|HD" catchup="default" catchup-days="7",TF1 HD
#EXTVLCOPT:http-user-agent=VLC/3.0
http://serveur/live/user/pass/1234.ts
```

Attributs à gérer : `tvg-id`, `tvg-name`, `tvg-logo`, `tvg-shift`, `group-title`,
`catchup`, `catchup-source`, `catchup-days`, plus les directives `#EXTGRP`,
`#EXTVLCOPT` (user-agent, referer — **nécessaires**, beaucoup de serveurs rejettent
l'UA par défaut) et `#KODIPROP` (à ignorer : c'est du DRM Widevine, non lisible sur Apple).

Parseur en **streaming ligne à ligne** (`FileHandle` / `AsyncLineSequence`), jamais
`String(contentsOf:)` — un M3U de 150 000 chaînes fait 30–60 Mo.

### 3.2 Xtream Codes

API REST sur `player_api.php` :

| Action | Retour |
|---|---|
| *(aucune)* | `user_info` (expiration, connexions max) + `server_info` |
| `get_live_categories` / `get_live_streams[&category_id=]` | catégories et chaînes live |
| `get_vod_categories` / `get_vod_streams` / `get_vod_info&vod_id=` | films |
| `get_series_categories` / `get_series` / `get_series_info&series_id=` | séries + épisodes |
| `get_short_epg&stream_id=&limit=` | EPG court (now/next) |
| `get_simple_data_table&stream_id=` | EPG complet d'une chaîne |

URLs de flux :

```
live   : {base}/live/{user}/{pass}/{stream_id}.ts        (ou .m3u8 si le serveur le propose)
film   : {base}/movie/{user}/{pass}/{vod_id}.{container_extension}
épisode: {base}/series/{user}/{pass}/{episode_id}.{container_extension}
EPG    : {base}/xmltv.php?username={user}&password={pass}
```

**Toujours préférer `.m3u8` quand le serveur le sert** : ça débloque AVPlayer, donc PiP,
AirPlay, HDR et Atmos (§4.1).

### 3.3 XMLTV (EPG)

Le point le plus piégeux côté perf. Fichier `.xml` ou `.xml.gz` de 50 à 500 Mo.

- Décompression **en flux** (gzip streaming), pas en mémoire.
- Parsing **SAX** (`XMLParser` sur un `InputStream`), pas DOM.
- Insertion par lots de 5 000 dans une transaction, sur une `Task` détachée en priorité
  basse, avec progression remontée à l'UI.
- Purge : ne garde que `now - 1 jour` → `now + 7 jours`. Un `VACUUM` périodique.
- Objectif : **200 Mo importés en < 60 s, < 150 Mo de RAM**, app utilisable pendant.

Mapping chaîne ↔ EPG : `tvg-id` en priorité, repli sur nom normalisé (minuscules,
sans accents, suffixes `HD|FHD|4K|UHD` retirés) + distance de Levenshtein.

### 3.4 Plex / Jellyfin / Emby *(lot tardif)*

APIs REST distinctes, chacune avec son auth (Plex : token via plex.tv ;
Jellyfin/Emby : `X-Emby-Token` + `/Users/AuthenticateByName`). À traiter comme des
implémentations supplémentaires du protocole `ContentSource` défini dans `UHFSources`.

---

## 4. Le cœur technique : la lecture

### 4.1 Deux moteurs, pas un — c'est la décision structurante

`AVPlayer` **ne lit pas le MPEG-TS brut en HTTP progressif**, qui est pourtant le format
de sortie par défaut de la majorité des serveurs Xtream (`.ts`). Il ne lit que HLS
(`.m3u8`), MP4, MOV et quelques conteneurs.

Architecture retenue :

```swift
protocol PlaybackEngine {
    func load(_ item: PlaybackItem) async throws
    func play(); func pause(); func seek(to: CMTime) async
    var state: AsyncStream<PlaybackState> { get }
    var capabilities: EngineCapabilities { get }   // pip, airplay, hdr, audioTracks…
}

struct AVPlayerEngine: PlaybackEngine { … }   // HLS, MP4 → PiP, AirPlay, HDR, Atmos
struct VLCKitEngine:  PlaybackEngine { … }    // MPEG-TS, MKV, AVI, codecs exotiques
```

Sélection du moteur :

1. Extension `.m3u8` → AVPlayer.
2. Extension `.ts`/`.mkv`/inconnue → requête `HEAD` (ou `GET` avec `Range: bytes=0-1023`)
   pour lire le `Content-Type` ; `application/vnd.apple.mpegurl` → AVPlayer, sinon VLCKit.
3. Échec du moteur A → bascule automatique sur le moteur B, mémorisée par chaîne.

`MobileVLCKit` / `TVVLCKit` existent en CocoaPods et SPM (paquets lourds : +80 Mo
d'app, c'est normal, UHF fait 142 Mo). **Attention licence : libVLC est en LGPL** —
liaison dynamique obligatoire, mention dans les crédits, sources de libVLC mises à
disposition. C'est compatible App Store, mais ça se prépare.

### 4.2 Fonctions de lecture à couvrir

- **Zapping rapide** : précharger le flux `n+1`/`n-1` de la liste courante ; cible
  **< 1,5 s** entre l'appui et la première image.
- **Reconnexion auto** : backoff exponentiel (1, 2, 4, 8 s), reprise à la position live,
  bandeau non bloquant. Distingue erreur réseau / 403 (abonnement expiré, connexions max
  atteintes) / 404 (chaîne morte).
- **PiP** : `AVPictureInPictureController`, capacité AVPlayer uniquement.
- **AirPlay** : `AVRoutePickerView`, gratuit avec AVPlayer.
- **Chromecast** : SDK Google Cast — s'ajoute à la fin, il impose des contraintes de
  build (et n'existe pas sur tvOS).
- **Pistes audio / sous-titres** : sélection dans les deux moteurs, mémorisée par contenu.
- **Contrôles système** : `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`, obligatoire
  pour l'écran verrouillé, CarPlay et la télécommande Apple TV.
- **Reprise de lecture** VOD : `watch_progress` écrit toutes les 5 s + à la sortie.

### 4.3 Catch-up / replay

Deux conventions :

- **M3U** : `catchup="default|append|shift|flussonic"` + `catchup-source` avec les
  jetons `${start}`, `${end}`, `${timestamp}`, `${offset}` à substituer.
- **Xtream** : champs `tv_archive` / `tv_archive_duration` sur la chaîne, puis
  `{base}/streaming/timeshift.php?username=&password=&stream={id}&start=YYYY-MM-DD:HH-MM&duration={minutes}`.

Point d'entrée UI : appui long sur un programme passé dans l'EPG.

---

## 5. Roadmap par lots

Estimations en **jours-homme pour un dev solo**, avec ton niveau (web solide, iOS
partiel — compte la montée en compétence SwiftUI/AVFoundation dans le lot 1).

### Lot 0 — Fondations (3 j)
Projet Xcode multi-cibles, packages SPM, GRDB + migrations, réglages, thème,
CI GitHub Actions (build + tests), TestFlight interne.

### Lot 1 — MVP iOS live TV (18 j) ⭐ *le jalon qui valide tout*
- Ajout d'une playlist : URL M3U, fichier local, compte Xtream.
- Parseurs M3U + client Xtream, import en base, écran de progression.
- Liste des chaînes par catégorie, logos en cache, recherche FTS5 instantanée.
- Lecteur : AVPlayer + VLCKit avec bascule automatique, plein écran, contrôles.
- Favoris.
- **Critère de sortie** : une playlist de 50 000 chaînes s'importe en < 10 s, la
  recherche répond en < 50 ms, le zapping en < 2 s.

### Lot 2 — EPG (10 j)
Import XMLTV en flux, grille temporelle scrollable (chaînes en Y, temps en X),
now/next dans la liste des chaînes, fiche programme, rappels via
`UNUserNotificationCenter`. Rafraîchissement en tâche de fond (`BGAppRefreshTask`).

### Lot 3 — Apple TV (14 j)
Cible tvOS, UI focus-driven complète, lecteur adapté à la télécommande
(swipe = zapping, appui = infos), grille EPG en 10-foot UI, Top Shelf.
**Ne commence pas par tvOS** : le focus engine est un modèle mental à part et tu
avanceras deux fois plus vite après avoir maîtrisé SwiftUI sur iOS.

### Lot 4 — VOD & séries (9 j)
Films et séries Xtream, affiches, saisons/épisodes, reprise de lecture,
« continuer à regarder », enrichissement optionnel TMDb.

### Lot 5 — Finition (8 j)
Catch-up, PiP, AirPlay, dossiers avec PIN, renommage/masquage de chaînes,
tri manuel, reconnexion auto robuste, multi-playlists, gestion d'erreurs explicite
(« abonnement expiré » plutôt que « erreur -1009 »).

### Lot 6 — Monétisation & sync (10 j)
StoreKit 2 (mensuel, annuel, à vie), paywall, période d'essai, restauration,
sync CloudKit des playlists/favoris/progression/rappels.

### Lot 7 — Extras, par ordre de rentabilité (20 j+)
1. macOS via Catalyst (quasi gratuit après iPadOS) — 3 j
2. Trakt (OAuth *device flow*, adapté à la télécommande) — 3 j
3. Jellyfin / Emby — 5 j ; Plex — 4 j
4. Chromecast — 4 j
5. Serveur DVR (§8.3) — 10 j+
6. Client VPN (§8.4) — 10 j+, entitlement Apple requis
7. visionOS — 5 j

**Total jusqu'à une v1 crédible (lots 0→6) : ~72 jours-homme**, soit environ
**4 à 6 mois en soirées et week-ends**, ou 3,5 mois à plein temps.

---

## 6. Performance : les chiffres à tenir

| Métrique | Cible | Technique |
|---|---|---|
| Import M3U 100k lignes | < 5 s | parsing en flux + inserts par lots |
| Import XMLTV 200 Mo | < 60 s, < 150 Mo RAM | SAX + gzip en flux + transactions |
| Recherche dans 150k chaînes | < 50 ms | FTS5 + `debounce` 200 ms |
| Scroll grille EPG | 60 fps | fenêtrage par plage horaire, requêtes paginées |
| Zapping | < 1,5 s | préchargement voisins + réutilisation de connexion |
| Démarrage à froid | < 1 s | pas d'import au lancement, UI d'abord |

Les logos sont le piège caché : 50 000 PNG distants tuent la scroll. Cache disque
plafonné (Nuke), chargement uniquement des cellules visibles, placeholder coloré
dérivé du nom de la chaîne (c'est exactement le *color-coded channel identification*
de UHF).

---

## 7. Sync multi-appareils

**v1 : CloudKit (`CKSyncEngine`, iOS 17+).** Zéro serveur, zéro coût, zéro RGPD à
gérer, et l'identité est déjà là. Tu synchronises playlists, favoris, dossiers,
progression, rappels — **jamais les flux**.

**Passe à un backend maison seulement si** tu vises Android/web plus tard, ou du
partage entre comptes. Dans ce cas, avec ton profil : Postgres (Supabase ou Neon) +
une API REST légère, auth par *Sign in with Apple*, et une table `sync_events`
append-only avec curseur — c'est le modèle le plus simple à rendre correct.

⚠️ **Les identifiants Xtream (user/pass) sont des secrets.** Keychain avec
`kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrSynchronizable` sur l'appareil, jamais
en clair dans CloudKit ni en base SQLite, jamais dans les logs.

---

## 8. Les quatre chantiers lourds (à ne pas sous-estimer)

### 8.1 Les serveurs IPTV sont hostiles
UA filtrés, redirections multiples, limites de connexions simultanées, certificats
auto-signés, flux qui coupent sans prévenir, `Content-Type` menteurs. Prévois dès le
lot 1 : UA configurable par playlist, suivi de redirections, timeouts courts (5 s en
connexion, 15 s en lecture), et un écran de diagnostic (URL testée, code HTTP, en-têtes,
moteur choisi). Tu t'en serviras tous les jours.

### 8.2 Le mapping EPG ↔ chaînes
Aucune playlist n'a des `tvg-id` propres. Prévois un écran de correspondance manuelle
avec suggestions. C'est une fonction de rétention forte et peu d'apps la font bien.

### 8.3 Serveur DVR
Composant séparé (Go ou Node + ffmpeg) qui reçoit un ordre d'enregistrement, ouvre le
flux, remuxe en MP4, et expose une API de bibliothèque. C'est là que ton expérience web
paye. Distribution : binaire + image Docker. Phase 3, pas avant.

### 8.4 Client VPN
`NEPacketTunnelProvider` + `WireGuardKit` / `OpenVPNAdapter`. L'entitlement
Network Extension se **demande à Apple** et n'est pas automatique. Ça double la
complexité de build (app + extension + partage de Keychain par App Group). À ne
lancer que si c'est un vrai argument de vente pour toi.

---

## 9. App Store : le risque n°1 n'est pas technique

Les lecteurs IPTV se font régulièrement rejeter ou retirer (règles 5.2 – propriété
intellectuelle, et 1.4 / 4.3). Ce qui protège :

- ✅ **Aucune playlist préchargée**, aucun contenu fourni, aucun lien vers un
  fournisseur IPTV — dans l'app, sur le site, dans la fiche App Store.
- ✅ Positionnement explicite : *lecteur de flux fournis par l'utilisateur*, comme VLC.
- ✅ Notes de review : fournis une **playlist de test légale** (flux FAST /
  domaine public / chaînes publiques librement diffusées) pour que le reviewer teste
  sans que tu envoies un accès à du contenu piraté.
- ✅ Mots-clés propres : pas de « free TV », pas de noms de chaînes ou de bouquets,
  pas de logos de chaînes dans les captures.
- ✅ Classification d'âge adaptée et filtre « contenu adulte » activé par défaut
  (les playlists contiennent presque toujours des catégories XXX → risque 1.1.4).
- ✅ Crédits LGPL pour libVLC.
- ✅ Politique de confidentialité + *App Privacy* honnête (aucune collecte de flux).

Prépare ces éléments **avant** la première soumission, pas après un rejet.

---

## 10. Qualité et outillage

- **Tests unitaires** sur `UHFSources` : jeu de M3U réels et tordus (BOM, CRLF,
  guillemets non échappés, `#EXTINF` sans virgule, attributs inconnus), réponses
  Xtream figées, extraits XMLTV. C'est là que les bugs se concentrent.
- **Tests de perf** : import de 100k chaînes en CI avec seuil d'échec.
- **Snapshot tests** sur les vues principales iOS + tvOS.
- **CI GitHub Actions** : build iOS + tvOS, tests, lint (SwiftLint/SwiftFormat),
  upload TestFlight sur tag.
- **Crash reporting** : Sentry ou MetricKit, avec scrubbing des URLs (elles contiennent
  les identifiants Xtream en clair — à masquer avant tout envoi).

---

## 11. Ordre d'attaque recommandé

Sur quatre semaines, pour lever les inconnues techniques avant de construire :

1. **Jour 1–2** : un *spike* jetable — lire un flux `.ts` Xtream avec VLCKit et un
   `.m3u8` avec AVPlayer, sur iPhone **et** Apple TV. Si ça marche, tout le reste est
   du travail connu. Si ça coince, c'est maintenant qu'il faut le savoir.
2. **Jour 3–5** : parseur M3U + Xtream, en package SPM pur avec tests, sans UI.
3. **Semaine 2–3** : GRDB, import, liste, recherche, lecteur.
4. **Semaine 4** : EPG sur une seule chaîne, de bout en bout.

Puis déroule les lots.

---

## 12. État d'avancement

Toute la logique non graphique est écrite et testée — **200 tests verts** sous
Swift 6.1. Une source peut être téléchargée, analysée, stockée, resynchronisée,
recherchée et rapprochée de son guide, sans interface.

| Livré | Où | Tests |
|---|---|---|
| Modèles, `StableKey`, normalisation | `Packages/UHFCore` | 14 |
| Parseur M3U étendu, lecture en flux | `Packages/UHFSources/M3U` | — |
| Client Xtream Codes, décodage tolérant | `Packages/UHFSources/Xtream` | — |
| Import XMLTV (SAX + gunzip en flux) | `Packages/UHFSources/XMLTV` | — |
| Catch-up, appariement EPG (§8.2), choix du moteur (§4.1) | `Packages/UHFSources` | 96 au total |
| Persistance, resync, FTS5, guide, favoris | `Packages/UHFStore` | 47 |
| Orchestration d'un rafraîchissement complet | `Packages/UHFSync` | 16 |
| Logique d'interface : pagination, anti-rebond, favoris, renommage | `Packages/UHFViewModels` | 27 |
| Description du projet Xcode (XcodeGen) | `project.yml` | — |
| Diagnostic en ligne de commande | `Tools/uhf-probe` | — |
| Moteurs AVPlayer / VLCKit | `Packages/UHFPlayback` | **non compilé, exige un Mac** |

Performances en `release` : M3U 100 000 chaînes analysées en 4,6 s puis écrites en
base en 4,8 s ; XMLTV à ~18 Mo/s ; recherche FTS5 de 15 à 67 ms ; now/next sur une
page de 60 chaînes en 13,5 ms.

### Ce que le code a corrigé par rapport au plan initial

Onze défauts trouvés par les tests. Les plus coûteux s'ils avaient atteint la
production :

- Les résolutions nues étaient retirées à la normalisation, si bien que
  « Chaîne 720 » et « Chaîne 1080 » partageaient la même ``StableKey`` — donc les
  mêmes favoris.
- `"\r\n"` forme **un seul** `Character` en Swift : `split(separator: "\n")` ne
  découpait pas les playlists à fins de ligne Windows, qui sont la majorité.
- Une extension de `HTTPURLResponse` redéfinissant `value(forHTTPHeaderField:)`
  se serait appelée elle-même indéfiniment sur Darwin, sans que Linux le montre.
- `${utc}` laissait un `$` orphelin, la substitution de `{utc}` passant en premier.
- `previousChannelCount` n'était renseigné qu'après le premier lot d'import, donc
  faux pour toute playlist de moins de 5 000 chaînes.

### Ce qui reste

Le chiffrage initial était de ~72 jours-homme jusqu'à une v1. Il en reste **~42**,
et ils sont tous sur Mac.

| Lot | Reste | Estimation |
|---|---|---|
| 0 · Fondations | projet Xcode, cibles iOS/tvOS, TestFlight | ~3 j |
| 1 · MVP iOS live | **les vues SwiftUI** : listes, recherche, lecteur (la logique d'écran est faite) | ~6 j |
| 2 · EPG | grille temporelle, fiche programme, notifications, `BGAppRefreshTask` | ~5 j |
| 3 · Apple TV | tout (focus engine, 10-foot UI, Top Shelf) | ~14 j |
| 4 · VOD & séries | affiches, saisons, « continuer à regarder » | ~4 j |
| 5 · Finition | PiP, AirPlay, écran de correspondance EPG, diagnostic | ~5 j |
| 6 · Monétisation & sync | StoreKit 2, paywall, CloudKit (`exportUserData` est prêt) | ~8 j |

Plus le lot 7 (Jellyfin/Plex/Emby, Trakt, Chromecast, macOS, visionOS, DVR, VPN) et
les préparatifs App Store du §9, à faire **avant** la première soumission.

### Ordre d'attaque

1. **Le spike de lecture** — `docs/SPIKE.md`, deux jours. Seul risque technique
   encore ouvert, et seule chose qui puisse encore invalider un choix d'architecture.
2. **`xcodegen generate`**, puis les vues du premier écran iOS. Toute la mécanique
   est là : `PlaylistSyncService.refresh` pour l'import, `ChannelListModel` pour la
   liste, `SearchModel` pour la recherche. Les vues sont de l'habillage.
3. **tvOS**, une fois iOS solide.
