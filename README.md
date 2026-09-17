# UHF-Copy

Lecteur IPTV natif pour l'écosystème Apple (iOS, iPadOS, tvOS, macOS), inspiré de
[UHF — Love your IPTV](https://apps.apple.com/fr/app/uhf-love-your-iptv/id6443751726).

Sources visées : playlists **M3U/M3U8**, comptes **Xtream Codes**, puis
Plex / Jellyfin / Emby.

> L'application est un **lecteur**. Elle ne fournit ni n'héberge aucun contenu :
> l'utilisateur apporte ses propres sources.

## État

Le socle non graphique est écrit et testé : **110 tests verts** (Swift 6.1).
Aucune interface pour l'instant — c'est délibéré, voir `docs/SPIKE.md`.

| Paquet | Contenu | État |
|---|---|---|
| `Packages/UHFCore` | Modèles, `StableKey`, normalisation des libellés | ✅ testé |
| `Packages/UHFSources` | M3U, Xtream, XMLTV, catch-up, appariement EPG, choix du moteur | ✅ testé |
| `Packages/UHFPlayback` | Moteurs `AVPlayer` / `VLCKit` et leur arbitrage | ⚠️ non compilé (exige un Mac) |
| `Tools/uhf-probe` | Diagnostic en ligne de commande | ✅ compilé |

## Démarrage

```bash
# Analyser une playlist, sans interface ni simulateur
swift run --package-path Tools/uhf-probe uhf-probe m3u <fichier|url>

# Interroger un panneau Xtream
swift run --package-path Tools/uhf-probe uhf-probe xtream 'http://srv:8080/get.php?username=…&password=…'

# Analyser un guide XMLTV (gzip accepté)
swift run --package-path Tools/uhf-probe uhf-probe epg <fichier|url>

# Mesurer le taux d'appariement chaînes ↔ guide
swift run --package-path Tools/uhf-probe uhf-probe match <m3u> <epg>

# Tests
swift test --package-path Packages/UHFCore
swift test --package-path Packages/UHFSources
```

`uhf-probe m3u` affiche notamment combien de chaînes tomberont sur `AVPlayer`
(donc avec PiP, AirPlay et HDR) et combien exigeront `VLCKit`.

## Ce qui est déjà couvert

- **M3U étendu** : `group-title` / `#EXTGRP`, `#EXTVLCOPT` et `#EXTHTTP` convertis en
  en-têtes HTTP, en-têtes inline après le `|`, catch-up, `tvg-shift`. Lecture en flux,
  mémoire constante, et poursuite de l'import sur entrée malformée.
- **Xtream Codes** : compte, catégories, live, films, séries, EPG court. Décodage
  tolérant aux types incohérents des panneaux, erreurs traduites en messages
  compréhensibles (abonnement expiré, limite de connexions…).
- **XMLTV** : parsing SAX en flux, gunzip par blocs, fenêtre temporelle, choix de
  langue. ~18 Mo/s.
- **Catch-up** : conventions `default`, `append`, `shift`, `flussonic` et Xtream.
- **Appariement EPG** : cascade à quatre niveaux de confiance, avec taux de
  couverture pour l'écran de correspondance manuelle.
- **Choix du moteur de lecture** : extension, puis type MIME, puis signature des
  premiers octets — parce que les serveurs IPTV mentent sur les deux premiers.

## Performance mesurée

Build `release`, x86_64. Les cibles sont celles de `docs/PLAN.md` §6.

| Mesure | Résultat | Cible |
|---|---|---|
| M3U, 100 000 chaînes (16,5 Mo) | 4,6 s | < 5 s |
| XMLTV, 100 000 programmes (27 Mo) | 1,5 s (~18 Mo/s) | 200 Mo < 60 s |
| 20 000 `StableKey` (normalisation incluse) | 0,18 s | — |

## Documentation

- 📄 **[`docs/PLAN.md`](docs/PLAN.md)** — plan de construction : stack, modèle de
  données, protocoles, roadmap en 8 lots chiffrée, contraintes App Store.
- 🔬 **[`docs/SPIKE.md`](docs/SPIKE.md)** — le spike de lecture à faire sur Mac, qui
  lève le seul risque technique bloquant du projet.

## Prochaine étape

Le spike de `docs/SPIKE.md`, sur un Mac avec Xcode. Tant qu'il n'est pas passé,
construire l'interface serait bâtir sur une hypothèse non vérifiée.
