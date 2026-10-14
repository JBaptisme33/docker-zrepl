# docker-zrepl

Image conteneur **multi-architecture** de [zrepl](https://github.com/dsh2dsh/zrepl) — sauvegarde et réplication ZFS.

| | |
|---|---|
| Image | `ghcr.io/jbaptisme33/zrepl` |
| Architectures | `linux/amd64`, `linux/arm64` (manifeste multi-arch unique) |
| Version embarquée | zrepl `1.4.2` — fork **`dsh2dsh/zrepl`** |
| Base | `ubuntu:22.04` (alignée sur la famille du nœud hôte) |
| Build | GitHub Actions → `docker buildx` (voir `.github/workflows/build.yml`) |

> **Le conteneur doit être root** et le pod **privilégié**, avec `/dev/zfs` de l'hôte monté : c'est la condition pour ouvrir `/dev/zfs` et pour que les opérations ZFS (`zfs send`/`recv`, propriétés, holds) aboutissent.

## Pourquoi cette image

zrepl tournait jusqu'ici **installé sur les hôtes**, avec un `/etc/zrepl/zrepl.yml` recopié **à la main** — `gitops-manifests` le documente (`configs/README.md`) et propose la sortie : *« une brique `kubectl` qui monte un ConfigMap dans un DaemonSet `hostPath` »*. Cette image est la pièce manquante : elle rend zrepl déployable comme **release Helm** (DaemonSet privilégié qui monte `/dev/zfs` de l'hôte), donc pilotable par GitOps, sans brique shadow.

`zrepl/zrepl` **n'a rien publié depuis mai 2026** : sa branche amont est dormante. Le fork **`dsh2dsh/zrepl`** partage cet historique mais est **activement maintenu** (Go 1.26, dépendances rafraîchies par dependabot, releases régulières) et résout une douzaine d'issues amont. Apports pour un usage WAN (notre cas : home → pair OCI / Tronque) :

| Apport | Effet |
|---|---|
| `zfs send -I` en **un seul paquet** (tous les snapshots intermédiaires) au lieu d'un `-i` par snapshot | mesuré par l'auteur : 1m32 au lieu de 8m sur WLAN |
| `zfs send -R` récursif, `send.raw` (= `-w`) par défaut ; `execpipe` entre `zfs send` et `zfs recv` | moins de code, moins d'échecs ; permet `zstd \| mbuffer` sur le flux |
| pruning et snapshotting **concurrents** | plus de purge bloquée derrière un snapshot |
| `zrepl monitor alive\|snapshots` + endpoint `/health` | surveillance Icinga/Nagios sans sonde maison |
| intervalle ou **cron** par job de réplication ; `client_keys` par job | cadencement fin ; restriction d'accès par client nommé |

**⚠️ Changement cassant de format de configuration.** Le passage de `zrepl/zrepl` 0.7 à `dsh2dsh/zrepl` 1.4.2 **n'est pas un simple changement de `build-arg`** : la configuration zrepl elle-même change de forme — l'API passe de **gRPC à REST**, et les transports `tcp`/`tls` sont remplacés par `local` et `http`.

| `zrepl/zrepl` 0.7 (avant) | `dsh2dsh/zrepl` 1.4.2 (après) |
|---|---|
| `serve:` **par job** (`type: tls`, `ca`, `cert`, `key`, `client_cns`) | un **`listen:` global** unique : `addr: ":5555"`, `tls_cert`, `tls_key`, `zfs: true` |
| Authentification **mTLS par CN** de certificat client | **jetons** : `include_keys: "keys.yaml"`, `client_keys:` par job, `client_identity` côté client |
| `connect: { type: tls, address, ca, cert, key, server_cn }` | `connect: { type: http, server: "https://…", listener_name, client_identity }` |
| `filesystems:` (filtre par préfixe) | `datasets:` (motifs, `recursive`, `exclude`, `shell`) — l'ancien `filesystems:` fonctionne encore mais est **déprécié** |
| socket de contrôle implicite | déclaré dans `listen:` : `unix: "/var/run/zrepl/control"` + `control: true` |
| `postgres-checkpoint`, `mysql-lock-tables` | **supprimés** |

Conséquence : **les configurations zrepl doivent être réécrites** au format REST avant de faire tourner cette image. Voir `k0s-home/zrepl/values.yaml` du dépôt `gitops-manifests`, configuration cible validée par le binaire 1.4.2 lui-même.

## Ce que contient l'image

- **Le binaire `zrepl`**, téléchargé depuis la release `dsh2dsh/zrepl` et **vérifié par somme SHA-256** (`zrepl_<version>_checksums.txt`) pendant le build ; **statique** (`ldd` répond « not a dynamic executable ») — aucune dépendance libc, aucune compilation.
- **`zfsutils-linux`** : zrepl n'embarque *pas* de bibliothèque ZFS, il invoque les binaires `zfs` et `zpool` du système (`internal/zfs/zfs.go` : `ZFS_BINARY = "zfs"`). Sans ces outils, le conteneur démarre puis échoue à la première opération ZFS.
- **Rien d'autre.** Pas de state sur disque : les curseurs de réplication sont des **propriétés ZFS** (`zrepl:cursor`). Seul `/var/run/zrepl/control` (socket de contrôle) est écrit — à monter en `emptyDir` dans le pod.

## Utilisation

```bash
docker run --rm --privileged \
  -v /dev/zfs:/dev/zfs \
  -v "$PWD/zrepl.yml:/etc/zrepl/zrepl.yml:ro" \
  -v "$PWD/keys.yaml:/etc/zrepl/keys.yaml:ro" \
  -v "$PWD/tls:/etc/zrepl/tls:ro" \
  ghcr.io/jbaptisme33/zrepl daemon
```

- `ENTRYPOINT` = `zrepl --config /etc/zrepl/zrepl.yml` ; `CMD` = `daemon`.
- Commandes utiles sans le démon :
  - `... configcheck` — valide la configuration (code 0 si valide) ;
  - `... configcheck --what jobs --format yaml` — configuration **interprétée** ;
  - `... test filesystems --job <job> --all` — **preuve** du périmètre retenu par le filtre `datasets:` d'un job `push`/`source` ;
  - `... version --show client` — version du binaire ;
  - `... monitor alive` / `... monitor snapshots` — contrôles Icinga/Nagios.

## Construction

Build **entièrement dans GitHub Actions** (`.github/workflows/build.yml`) : aucun démon Docker requis sur le poste, image multi-arch produite par `docker buildx`.

```bash
gh workflow run build.yml -R JBaptisme33/docker-zrepl   # déclenchement manuel
gh run list -R JBaptisme33/docker-zrepl -L 5            # suivi
```

En local, reproduire une seule architecture (démon Docker requis) :

```bash
docker build --build-arg ZREPL_VERSION=1.4.2 -t zrepl:local .
```

**Faire évoluer la version de zrepl.** `ZREPL_VERSION` est déclarée **une seule fois** dans le workflow (`env.ZREPL_VERSION`) et sert de `build-arg` **et** de tag d'image, donc les deux ne peuvent pas diverger. Bumper = un commit :

1. vérifier que la release du fork publie les deux architectures : `gh release view -R dsh2dsh/zrepl` doit lister `zrepl_<version>_linux_amd64.tar.gz` **et** `zrepl_<version>_linux_arm64.tar.gz` ;
2. changer `ZREPL_VERSION` dans `.github/workflows/build.yml` ;
3. pousser — l'image `<version>` et `latest` sont reconstruites.

Ensuite, côté `gitops-manifests`, épingler le même tag dans `k0s-home/zrepl/values.yaml` (champ `image.tag`) **et** dans `appVersion` du chart. **Ne jamais désaligner les trois.**

## Limites connues

- **Ne pas faire tourner deux zrepl sur les mêmes pools.** Tant que le service zrepl natif de l'hôte tourne, déployer ce conteneur créerait deux démons concurrents (snapshots et purge en double). La bascule se fait en **arrêtant le service natif** — étape de migration, pas un ajout.
- **Les outils ZFS de l'image doivent rester dans la branche majeure du module noyau** de l'hôte. Image alignée sur Ubuntu 22.04 (`zfsutils-linux` 2.1.x) parce que le nœud `k3s-home` est en Ubuntu 22.04.5 ; pour un hôte d'une autre famille, surcharger `BASE_IMAGE` (build-arg).
- **Les secrets ne sont pas dans l'image** : certificats TLS (`listen.tls_cert`/`tls_key`) **et** fichier de jetons `keys.yaml` vivent hors de l'image et sont fournis au pod par des Secrets Kubernetes (chart `k0s-home/zrepl` du dépôt `gitops-manifests`).
- **Authentification par jeton, pas par certificat client.** Là où l'amont liait l'identité au **CN** d'un certificat client, le fork authentifie par **jeton partagé** (`keys.yaml`). Un jeton vaut une identité : il doit circuler sur un transport chiffré (`https://`), et chaque hôte détient les jetons des deux sens de la réplication croisée.

## Licence

MIT (voir `LICENSE`). zrepl est distribué sous MIT par ses auteurs ; cette image ne fait que l'empaqueter.
