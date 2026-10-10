# docker-zrepl

Image conteneur **multi-architecture** de [zrepl](https://zrepl.github.io) —
solution de sauvegarde et de réplication ZFS (« one-stop ZFS backup &
replication »).

| | |
|---|---|
| Image | `ghcr.io/jbaptisme33/zrepl` |
| Architectures | `linux/amd64`, `linux/arm64` (manifeste multi-arch unique) |
| Version embarquée | zrepl `0.7.0` (amont `zrepl/zrepl`) |
| Base | `ubuntu:22.04` (alignée sur la famille du nœud hôte) |
| Build | GitHub Actions → `docker buildx` (voir `.github/workflows/build.yml`) |

---

## Pourquoi cette image

zrepl tournait jusqu'ici **installé sur les hôtes**, avec un
`/etc/zrepl/zrepl.yml` recopié **à la main**. Le dépôt `gitops-manifests` le
documente noir sur blanc (`configs/README.md`) : *« Aujourd'hui : à la main. Il
n'existe aucun chemin automatique du dépôt vers `/etc/zrepl/zrepl.yml` »* — et
propose lui-même la sortie : *« une brique `kubectl` qui monte un ConfigMap dans
un DaemonSet `hostPath` »*.

Cette image est la pièce manquante : elle rend zrepl déployable comme **release
Helm** (DaemonSet privilégié qui monte `/dev/zfs` de l'hôte), donc pilotable par
GitOps, sans brique shadow.

---

## Ce que contient l'image, et pourquoi

- **Le binaire `zrepl`**, téléchargé depuis la release amont et **vérifié par
  somme SHA-512** (`sha512sum.txt` de l'amont) pendant le build. Il est
  **statique** (`CGO_ENABLED=0`, `ldd` répond « not a dynamic executable ») :
  aucune dépendance libc, aucune compilation nécessaire.
- **`zfsutils-linux`** : zrepl n'embarque *pas* de bibliothèque ZFS, il invoque
  les binaires `zfs` et `zpool` du système (`internal/zfs/zfs.go` :
  `ZFS_BINARY = "zfs"`). Sans ces outils, le conteneur démarre puis échoue à la
  première opération ZFS.
- **Rien d'autre.** Pas de state sur disque : les curseurs de réplication sont
  des **propriétés ZFS** (`zrepl:cursor`), pas des fichiers. Seul
  `/var/run/zrepl/control` (socket de contrôle) est écrit — à monter en
  `emptyDir` dans le pod.

> **Le conteneur doit être root** et le pod **privilégié**, avec `/dev/zfs` de
> l'hôte monté. C'est la condition pour ouvrir `/dev/zfs` et pour que les
> opérations ZFS (`zfs send`/`recv`, propriétés, holds) aboutissent.

---

## Utilisation

```bash
docker run --rm --privileged \
  -v /dev/zfs:/dev/zfs \
  -v "$PWD/zrepl.yml:/etc/zrepl/zrepl.yml:ro" \
  -v "$PWD/tls:/etc/zrepl/tls:ro" \
  ghcr.io/jbaptisme33/zrepl daemon
```

- `ENTRYPOINT` = `zrepl --config /etc/zrepl/zrepl.yml`
- `CMD` = `daemon`
- Commandes utiles sans lancer le démon :
  - `... configcheck` — valide le fichier de configuration ;
  - `... configcheck --skip-cert-check` — idem sans exiger les certificats TLS ;
  - `... test filesystems --job <job> --all` — **preuve** du périmètre retenu
    par le filtre d'un job `push`/`source` (applique le filtre et rend
    `ACCEPT`/`REJECT` par jeu de données) ;
  - `... version --show client` — version du binaire.

---

## Construction

Le build est **entièrement dans GitHub Actions** (`.github/workflows/build.yml`) :
aucun démon Docker n'est requis sur le poste, et l'image multi-arch est produite
par `docker buildx`.

```bash
# déclenchement manuel
gh workflow run build.yml -R JBaptisme33/docker-zrepl
# suivi
gh run list -R JBaptisme33/docker-zrepl -L 5
```

En local, pour reproduire une seule architecture (nécessite un démon Docker) :

```bash
docker build --build-arg ZREPL_VERSION=0.7.0 -t zrepl:local .
```

### Faire évoluer la version de zrepl

La version est déclarée **une seule fois** dans le workflow
(`env.ZREPL_VERSION`) ; elle sert à la fois de `build-arg` et de **tag d'image**,
donc les deux ne peuvent pas diverger. Bumper = un commit sur ce fichier :

1. vérifier que la release amont publie bien `zrepl-linux-amd64` et
   `zrepl-linux-arm64` (`gh release view -R zrepl/zrepl`) ;
2. changer `ZREPL_VERSION` dans `.github/workflows/build.yml` ;
3. pousser — l'image `<version>` et `latest` sont reconstruites.

Ensuite, côté `gitops-manifests`, épingler le même tag dans
`k0s-home/zrepl/values.yaml` (champ `image.tag`) **et** dans `appVersion` du
chart.

---

## Variante : la branche `dsh2dsh/zrepl`

`dsh2dsh/zrepl` est un dépôt **autonome** (pas un fork GitHub) qui partage
l'historique amont mais est **nettement plus actif** que `zrepl/zrepl` (dont la
dernière publication date de mai 2026). Il conserve le modèle multi-destination
de l'amont et change l'architecture (API REST, `keys.yaml` au lieu de mTLS
`serv:`).

Pour construire l'image depuis cette branche, **la nomenclature des assets
diffère** : `zrepl_<version>_linux_<arch>.tar.gz` (archive) au lieu de
`zrepl-linux-<arch>` (binaire nu). Le `Dockerfile` de ce dépôt suit la
nomenclature amont ; passer à `dsh2dsh` demande d'adapter l'étape de
téléchargement (extraire l'archive) **et** de réécrire les configurations zrepl
au format REST. Ce n'est donc pas un simple changement de `build-arg`.

---

## Limites connues

- **Ne pas faire tourner deux zrepl sur les mêmes pools.** Tant que le service
  zrepl natif de l'hôte tourne, déployer ce conteneur créerait deux démons
  concurrents (snapshots et purge en double). La bascule se fait en **arrêtant
  le service natif** — c'est une étape de migration, pas un ajout.
- **Les outils ZFS de l'image doivent rester dans la branche majeure du module
  noyau** de l'hôte. L'image est alignée sur Ubuntu 22.04 (`zfsutils-linux`
  2.1.x) parce que le nœud `k3s-home` est en Ubuntu 22.04.5. Pour un hôte d'une
  autre famille, surcharger `BASE_IMAGE` (build-arg).
- **Les certificats TLS ne sont pas dans l'image** : ils vivent sur l'hôte et
  doivent être fournis au pod par un Secret Kubernetes (voir le chart
  `k0s-home/zrepl` du dépôt `gitops-manifests`).

---

## Licence

MIT (voir `LICENSE`). zrepl est distribué sous MIT par ses auteurs ; cette image
ne fait que l'empaqueter.
