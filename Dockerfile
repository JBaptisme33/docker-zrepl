# syntax=docker/dockerfile:1

# =============================================================================
#  zrepl — image conteneur multi-architecture (linux/amd64 + linux/arm64)
# =============================================================================
#  BINAIRE : dsh2dsh/zrepl, fork activement maintenu de zrepl/zrepl.
#
#  POURQUOI CETTE IMAGE EXISTE
#  ---------------------------
#  zrepl tourne aujourd'hui sur les hotes, installe par le systeme, avec un
#  /etc/zrepl/zrepl.yml ecrit a la main (voir configs/README.md du depot
#  gitops-manifests : « aujourd'hui : a la main »). Conteneuriser zrepl permet
#  de le deployer comme une release Helm (DaemonSet privilegie qui monte
#  /dev/zfs de l'hote), donc de supprimer cette brique shadow.
#
#  POURQUOI dsh2dsh/zrepl ET PAS zrepl/zrepl
#  -----------------------------------------
#  zrepl/zrepl n'a rien publie depuis mai 2026 : la branche amont est de fait
#  dormante. dsh2dsh/zrepl partage cet historique mais est activement maintenu
#  (Go 1.26, dependances fraiches, releases regulieres). Il corrige une
#  douzaine d'issues amont et apporte des gains concrets en replication WAN :
#
#    * `zfs send -I` en un seul paquet (tous les snapshots intermediaires) au
#      lieu d'un `-i` par snapshot — determinante sur un lien WAN ;
#    * `zfs send -R` recursif, `send.raw` (= -w) par defaut ;
#    * pipelines entre send et recv (`execpipe` : zstd | mbuffer) ;
#    * pruning et snapshotting concurrents ;
#    * surveillance Icinga/Nagios integree (`zrepl monitor`).
#
#  ATTENTION : c'est un CHANGEMENT CASSANT de format de configuration.
#  L'API est passee de gRPC a REST et les transports `tcp`/`tls` (mTLS par CN)
#  ont ete remplaces par `local` et `http` (jetons via `keys.yaml`). Les blocs
#  `serve:` par job n'existent plus : le service est declare une fois, dans un
#  `listen:` global. Voir le README pour la table de correspondance.
#
#  POURQUOI IL N'Y A RIEN A COMPILER
#  ---------------------------------
#  Le fork publie zrepl sous forme de binaire Go STATIQUE (verifie : `ldd`
#  repond « not a dynamic executable »). Il n'y a donc pas de cross-compilation
#  a faire : on telecharge le binaire de l'architecture cible. C'est ce qui
#  rend le multi-arch trivial — ni QEMU, ni toolchain Go.
#
#  CE QUE L'IMAGE DOIT CONTENIR, ET POURQUOI
#  -----------------------------------------
#  zrepl n'embarque PAS de bibliotheque ZFS : il invoque les binaires `zfs` et
#  `zpool` du systeme (`internal/zfs/zfs.go` : `ZFS_BINARY = "zfs"`). Sans
#  zfsutils-linux, le conteneur demarre puis echoue a la premiere operation
#  ZFS. Le binaire zrepl, lui, etant statique, n'a aucune dependance libc.
#
#  L'image de base est alignee sur la famille du noeud hote (Ubuntu 22.04 chez
#  k3s-home) : les outils ZFS en espace utilisateur doivent rester dans la meme
#  branche majeure que le module noyau pour parler a /dev/zfs sans surprise.
#  Surchargeable par BASE_IMAGE pour un hote d'une autre famille.
# =============================================================================

ARG BASE_IMAGE=ubuntu:22.04

FROM ${BASE_IMAGE}

# -- Version de zrepl a embarquer : LA valeur a faire evoluer (voir README).
ARG ZREPL_VERSION=1.4.2
# -- Depot du binaire : dsh2dsh/zrepl, fork activement maintenu.
ARG ZREPL_REPO=dsh2dsh/zrepl
# -- Architecture cible, fournie par buildx (amd64 | arm64).
ARG TARGETARCH

LABEL org.opencontainers.image.title="zrepl" \
      org.opencontainers.image.description="One-stop ZFS backup & replication — binaire statique (dsh2dsh/zrepl) + outils ZFS en espace utilisateur" \
      org.opencontainers.image.url="https://github.com/dsh2dsh/zrepl" \
      org.opencontainers.image.source="https://github.com/${ZREPL_REPO}" \
      org.opencontainers.image.version="${ZREPL_VERSION}" \
      org.opencontainers.image.licenses="MIT"

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# -- Empeche les postinst de demarrer des services (zfs-zed) pendant le build :
#    sans cela, un paquet qui tente un `systemctl start` peut faire echouer
#    l'installation dans un conteneur sans systemd.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
 && chmod +x /usr/sbin/policy-rc.d \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      zfsutils-linux \
 # -- Binaire zrepl + verrou d'integrite. La nomenclature du fork est
 #    `zrepl_<version>_linux_<arch>.tar.gz` (une ARCHIVE, pas un binaire nu), et
 #    le fichier de sommes est en SHA-256 (`zrepl_<version>_checksums.txt`,
 #    format `sha256sum` standard `<hash>  <nom>`). On ne verifie QUE la ligne de
 #    l'architecture cible : les autres assets ne sont pas telecharges.
 && curl -fsSL -o "/tmp/zrepl_${ZREPL_VERSION}_linux_${TARGETARCH}.tar.gz" \
      "https://github.com/${ZREPL_REPO}/releases/download/v${ZREPL_VERSION}/zrepl_${ZREPL_VERSION}_linux_${TARGETARCH}.tar.gz" \
 && curl -fsSL -o /tmp/checksums.txt \
      "https://github.com/${ZREPL_REPO}/releases/download/v${ZREPL_VERSION}/zrepl_${ZREPL_VERSION}_checksums.txt" \
 # -- Le nom du fichier telecharge DOIT etre celui de l'asset : `sha256sum -c`
 #    resout chaque ligne du fichier de sommes comme un NOM DE FICHIER local.
 #    Un nom different fait echouer la verification (« FAILED open or read »).
 && ( cd /tmp \
      && grep -E "  zrepl_${ZREPL_VERSION}_linux_${TARGETARCH}\.tar\.gz\$" checksums.txt \
      && grep -E "  zrepl_${ZREPL_VERSION}_linux_${TARGETARCH}\.tar\.gz\$" checksums.txt | sha256sum -c - ) \
 # -- L'archive contient `zrepl` a la racine (plus dist/ pour FreeBSD et un
 #    tableau de bord Grafana). On n'installe QUE le binaire.
 && tar -xzf "/tmp/zrepl_${ZREPL_VERSION}_linux_${TARGETARCH}.tar.gz" -C /tmp zrepl \
 && install -m 0755 /tmp/zrepl /usr/local/bin/zrepl \
 && rm -rf "/tmp/zrepl_${ZREPL_VERSION}_linux_${TARGETARCH}.tar.gz" /tmp/checksums.txt /tmp/zrepl \
 # -- Repertoire du socket de controle. zrepl ne stocke AUCUN etat sur disque :
 #    les curseurs de replication sont des proprietes ZFS (`zrepl:cursor`).
 #    Seul /var/run/zrepl/control est ecrit — monte en emptyDir dans le pod, et
 #    declare dans le `listen:` de la configuration (`unix:` + `control: true`).
 && install -d -m 0700 /var/run/zrepl \
 && install -d -m 0755 /etc/zrepl \
 && apt-get purge -y --auto-remove curl \
 && rm -rf /var/lib/apt/lists/* \
 # -- Preuves de construction : l'image echoue ici plutot qu'au premier
 #    deploiement, et la sortie reste lisible dans le journal du build.
 #    `zfs --version` sort en code != 0 dans un conteneur SANS module noyau
 #    (« zfs_version_kernel() failed: No such file or directory ») : c'est
 #    ATTENDU au build, la version du module n'existe que sur l'hote. On verifie
 #    donc que l'outil s'execute et s'annonce, pas son code de retour.
 && command -v zrepl zfs zpool \
 && zrepl version --show client \
 && { zfs --version || true; }

WORKDIR /etc/zrepl

# -- Meme contrat que l'image de reference (Skaronator/docker-zrepl) : le
#    fichier de configuration est monte sur /etc/zrepl/zrepl.yml, et `daemon`
#    est la commande par defaut.
ENTRYPOINT ["/usr/local/bin/zrepl", "--config", "/etc/zrepl/zrepl.yml"]
CMD ["daemon"]
