# Immich • Just Player

Fork personnel de l'application Android Immich **v3.3.1**, pour lire les vidéos
du serveur avec Just Player à travers Tailscale. Le serveur Immich reste inchangé.
Ce patch a été développé avec un assistant LLM et n'est pas destiné à une PR upstream.

## Installation et utilisation

1. Installer l'APK **arm64-v8a** sur le OnePlus 8T et installer Just Player
   (`com.brouken.player`). L'application du fork apparaît sous le nom
   **Immich • Just Player** ; son identifiant `app.alextran.immich.justplayer`
   permet de garder l'application officielle installée.
2. Activer Tailscale sur le téléphone et se connecter au serveur Immich avec
   son adresse Tailscale : `http://100.x.x.x:2283`, un nom complet `*.ts.net`,
   ou son IPv6 Tailscale. Utiliser cette adresse pour toutes les adresses de
   connexion Immich si l'application choisit automatiquement un autre réseau.
   Vérifier aussi que **Immich • Just Player** et **Just Player** ne sont pas exclus
   du VPN dans le [split tunneling Android de Tailscale](https://tailscale.com/docs/features/client/android-app-split-tunneling).
3. Ouvrir une vidéo qui vous appartient, puis son menu **⋮ → Ouvrir avec un
   lecteur externe**. Just Player est lancé directement s'il est installé ;
   sinon Android propose les lecteurs vidéo disponibles.
4. Le réglage Immich **Forcer la vidéo originale** choisit le fichier
   original. Sans ce réglage, le lecteur reçoit la vidéo optimisée du serveur,
   avec le comportement de repli standard d'Immich si aucune version encodée
   n'existe. Aucune copie complète préalable n'est nécessaire ; le serveur
   conserve la gestion HTTP des plages d'octets pour les déplacements dans la vidéo.

Le bouton existe uniquement sur Android, pour une seule vidéo sauvegardée sur
le serveur et appartenant au compte connecté. Il n'est pas proposé pour les
photos, médias locaux, vidéos verrouillées, corbeille ou sélections multiples.
Le lecteur intégré est mis en pause avant l'ouverture du lecteur externe.

Le fork a ses propres données d'application : il faut se reconnecter et choisir
ses réglages de sauvegarde. Pour éviter des envois simultanés, activer la sauvegarde
automatique dans une seule des deux applications. Le schéma de retour OAuth
`app.immich` est conservé ; Android peut proposer un choix d'application au retour
d'une connexion OAuth lorsque les deux applications sont installées.

## Accès temporaire à la vidéo

L'application crée un partage Immich individuel pour **une seule vidéo** avec
une expiration obligatoire : deux heures minimum, ou la durée de la vidéo plus
une heure pour les vidéos longues. L'URL de lecture contient cette clé temporaire,
jamais la session du compte ou une clé API permanente. Elle est transmise au lecteur
choisi ; il faut donc utiliser une application de confiance.

Les partages interdisent les uploads. La lecture optimisée masque les métadonnées
et interdit le téléchargement original. La lecture originale autorise l'accès à
l'original et aux métadonnées, car Immich impose cette combinaison. Ce lien reste
un partage Immich de la vidéo, visible dans la gestion des liens partagés : il peut
aussi être supprimé manuellement pour révoquer l'accès immédiatement.

Un journal local conserve uniquement les identifiants des partages, le serveur,
le propriétaire et la date d'expiration. Il ne conserve ni la clé de lecture ni
la session. Les partages expirés du compte/serveur actif sont supprimés à la prochaine
ouverture externe. Un lancement échoué déclenche une suppression immédiate lorsque
la session le permet. Si l'application est arrêtée ou désinstallée, l'expiration
côté serveur reste effective ; une ligne expirée peut rester dans la liste des partages.

## Périmètre Tailscale

Le fork refuse les adresses publiques et LAN pour cette action. Il accepte les
IPv4 `100.64.0.0/10`, les IPv6 `fd7a:115c:a1e0::/48` et les noms `*.ts.net` dont
**toutes** les réponses DNS appartiennent à ces plages. Les identifiants intégrés
dans l'URL sont interdits, et l'API utilisée doit correspondre au serveur enregistré.
Les créations/suppressions de partage sont épinglées à ce serveur, interrompues
si le compte ou la session change, et ne suivent pas de redirections HTTP.

Avant le lancement, une requête `Range: bytes=0-0` vérifie le flux sur une adresse
Tailscale résolue et épinglée, sans proxy système ni redirections. Une redirection
vers une URL publique est refusée. Le lecteur reçoit ensuite l'URL directe Immich
Tailscale ; le serveur v3.3.1 fournit le fichier sans redirection sur ces routes.

Ces contrôles ne sont pas un pare-feu Android : après le lancement, le lecteur
externe contrôle ses propres requêtes. Tailscale doit rester actif, le serveur doit
être accessible uniquement par le tailnet, et le lecteur doit être de confiance.
La plage IPv4 acceptée est aussi utilisée par certains opérateurs pour le CGNAT ;
l'adresse seule ne prouve pas qu'une route VPN est active. Une garantie système
contre toute sortie hors VPN doit être imposée par la configuration réseau du
téléphone. Ce fork ne modifie ni les règles Tailscale ni l'exposition du serveur.

## Rebuild et signature

La branche est basée sur le tag upstream `v3.3.1` (`db6e11ecc851228aec9c525abb0ee026d1f5055e`).
Utiliser les versions de Flutter et Java du fichier `mobile/mise.toml` et générer
le SDK OpenAPI ainsi que les fichiers Flutter avant la compilation. Avec l'outillage
Mise du dépôt installé :

```bash
mise install
pnpm -w install --frozen-lockfile
mise run //mobile:install:ci
mise run //mobile:codegen
cd mobile
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --android-project-arg force-version-code-ignoring-abi=true --no-pub
```

La sortie est `mobile/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.
Le split exclut les autres architectures ; l'argument Gradle conserve le code
de version d'Immich pour les prochaines mises à jour de ce fork.
Pour la première compilation dans cette VM, les outils portables sont installés
dans `/home/codex/projects/divers/.toolchains` ; charger leur `env.sh` remplace
la sélection de versions via Mise.

L'APK distribué est signé avec une clé propre à ce fork. **Conserver cette clé**
pour que les prochaines versions puissent mettre à jour l'application sans
désinstallation. `mobile/android/key.jks` et `mobile/android/key.properties` sont
privés, exclus de Git et ne doivent jamais être publiés avec l'APK.
Sans ces fichiers, le script upstream peut produire une release signée avec la
clé de debug ; elle ne pourra pas remplacer l'APK signé avec la clé de ce fork.

Vérifications ciblées :

```bash
cd mobile
dart analyze --fatal-infos
flutter test --no-pub test/services/external_player_service_test.dart \
  test/utils/tailscale_endpoint_test.dart test/utils/action_button_utils_test.dart
cd android
./gradlew :app:testDebugUnitTest --tests 'app.alextran.immich.core.*' \
  -Ptarget-platform=android-arm64
```

Les tests utilisent des API, DNS et requêtes simulés. La lecture réelle et les
déplacements dans la vidéo doivent encore être vérifiés sur le téléphone connecté
au serveur ; la VM ne contacte ni le téléphone ni le serveur privé.

L'analyse Dart, le formatage Dart/JSON et les tests ciblés ont été exécutés.
L'analyse complémentaire DCM n'a pas pu être exécutée : l'installation locale
ne dispose pas d'une licence activée. `custom_lint` est désactivé dans la CI upstream
de cette version.
