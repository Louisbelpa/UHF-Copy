# Spike de lecture — à faire sur un Mac, en deux jours

Objectif : lever le **seul risque technique vraiment bloquant** du projet avant
d'écrire quoi que ce soit d'autre. Si ce spike passe, tout le reste est du travail
connu. S'il coince, mieux vaut le savoir maintenant.

> Ce code n'a **pas** été compilé : l'environnement de développement utilisé pour
> écrire cette base est sous Linux, sans Xcode ni AVFoundation. Les paquets
> `UHFCore`, `UHFSources` et l'outil `uhf-probe`, eux, sont compilés et testés
> (110 tests verts). `UHFPlayback` est à considérer comme une structure de départ
> dont les API AVFoundation restent à vérifier au premier build.

## La question à trancher

`AVPlayer` ne lit **pas** le MPEG-TS brut servi en HTTP progressif — le format de
sortie par défaut de la majorité des panneaux Xtream (`.../live/user/pass/123.ts`).
Il faut donc un second moteur, `VLCKit`. Le spike vérifie trois choses :

1. Un `.m3u8` se lit bien avec `AVPlayer`, sur iPhone **et** Apple TV.
2. Un `.ts` se lit bien avec `VLCKit`, sur iPhone **et** Apple TV.
3. La bascule automatique de l'un à l'autre fonctionne sans que l'utilisateur
   voie autre chose qu'un bref chargement.

Le troisième point est celui qu'on oublie, et c'est celui qui décide de la
qualité perçue du zapping.

## Étapes

### 1. Projet

```
Xcode → File → New → Project → Multiplatform → App
Nom : UHF   Interface : SwiftUI   Langage : Swift
Ajouter une cible tvOS au même projet.
```

Puis ajouter les paquets locaux : `File → Add Package Dependencies… → Add Local…`
et pointer `Packages/UHFCore`, `Packages/UHFSources`, `Packages/UHFPlayback`.

### 2. VLCKit

Pas de distribution SPM officielle. Au choix :

```ruby
# Podfile
target 'UHF-iOS'  do platform :ios,  '17.0'; pod 'MobileVLCKit', '~> 3.6.0' end
target 'UHF-tvOS' do platform :tvos, '17.0'; pod 'TVVLCKit',     '~> 3.6.0' end
```

ou télécharger les XCFrameworks depuis `download.videolan.org/pub/cocoapods/`.

Compter **+80 Mo** sur la taille de l'app — c'est normal, UHF en fait 142.

⚠️ libVLC est sous **LGPL** : liaison dynamique obligatoire, mention dans les
crédits, sources mises à disposition. Compatible App Store, mais à préparer.

### 3. Capacités et réglages

- `Signing & Capabilities` → **Background Modes** → *Audio, AirPlay and Picture in Picture*.
  Sans cela, ni PiP ni lecture en arrière-plan.
- `Info.plist` → **App Transport Security** : la quasi-totalité des serveurs IPTV
  sont en HTTP simple. `NSAllowsArbitraryLoads = YES` est nécessaire, et devra
  être justifié à la revue App Store (« le lecteur se connecte à des serveurs
  fournis par l'utilisateur, dont l'app ne contrôle pas la configuration TLS »).
- Au démarrage :

  ```swift
  try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
  try? AVAudioSession.sharedInstance().setActive(true)
  ```

### 4. Écran de test

```swift
import SwiftUI
import AVKit
import UHFCore
import UHFSources
import UHFPlayback

struct SpikeView: View {
    @State private var urlText = ""
    @State private var outcome: StreamProbe.Outcome?
    @State private var engine: PlaybackEngine?

    var body: some View {
        VStack(spacing: 16) {
            TextField("URL du flux", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            Button("Lire") { Task { await lire() } }

            if let outcome {
                Text("Moteur : \(outcome.engine.rawValue) — décidé par \(outcome.reason.rawValue)")
                    .font(.footnote.monospaced())
                if let type = outcome.contentType {
                    Text("Content-Type : \(type)").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let avEngine = engine as? AVPlayerEngine {
                VideoPlayer(player: avEngine.player)
                    .aspectRatio(16/9, contentMode: .fit)
            }
            // Pour VLCKit : une UIViewRepresentable dont la vue sert de `drawable`.
        }
        .padding()
    }

    private func lire() async {
        guard let url = URL(string: urlText) else { return }
        outcome = await StreamProbe().probe(url)

        let coordinator = PlayerCoordinator { kind in
            kind == .avPlayer ? AVPlayerEngine() : nil   // brancher VLCKitEngine ici
        }
        let item = PlaybackItem(url: url, title: "Test", isLive: true)
        engine = await coordinator.play(item, key: StableKey(rawValue: "spike"))
    }
}
```

### 5. Flux de test

Avant d'utiliser un vrai abonnement, valider sur des flux **libres de droits** —
ce sont aussi ceux à fournir à la revue App Store (voir `PLAN.md` §9) :

| Format | Où en trouver |
|---|---|
| HLS `.m3u8` | flux de démonstration d'Apple (`devstreaming-cdn.apple.com`), Big Buck Bunny en HLS |
| MPEG-TS `.ts` | `ffmpeg` en local : `ffmpeg -re -i film.mp4 -c copy -f mpegts udp://…`, ou les playlists publiques du dépôt `iptv-org/iptv` (chaînes librement diffusées) |

`uhf-probe` permet d'inspecter une source avant même de la lire :

```
swift run uhf-probe m3u https://iptv-org.github.io/iptv/index.m3u --limit 5
```

Sa section « Moteur de lecture » indique immédiatement combien de chaînes
tomberont sur AVPlayer et combien exigeront VLCKit.

## Critères de réussite

- [ ] Un `.m3u8` se lit sur iPhone et sur Apple TV, PiP compris.
- [ ] Un `.ts` se lit sur iPhone et sur Apple TV.
- [ ] La bascule AVPlayer → VLCKit est automatique et invisible.
- [ ] Un flux avec `User-Agent` imposé se lit dans les deux moteurs.
- [ ] Premier image en moins de 2 s sur une connexion correcte.

Tout coché : passer au lot 1 du plan. Un point qui résiste : le régler **avant**
de construire quoi que ce soit au-dessus.
