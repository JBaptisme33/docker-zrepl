# syntax=docker/dockerfile:1

# =============================================================================
#  zrepl — image conteneur multi-architecture (linux/amd64 + linux/arm64)
# =============================================================================
#  POURQUOI CETTE IMAGE EXISTE
#  ---------------------------
#  zrepl tourne aujourd'hui sur les hotes, installe par le systeme, avec un
#  /etc/zrepl/zrepl.yml ecrit a la main (voir configs/README.md du depot
#  gitops-manifests : « aujourd'hui : a la main »). Conteneuriser zrepl permet
#  de le deployer comme une release Helm (DaemonSet privilegie qui monte
#  /dev/zfs de l'hote), donc de supprimer cette brique shadow.
#
#  POURQUOI IL N'Y A RIEN A COMPILER
#  ---------------------------------
#  L'amont publie zrepl sous forme de binaire Go STATIQUE (build `CGO_ENABLED=0`,
#  verifie : `ldd` repond « not a dynamic executable »). Il n'y a donc pas de
#  cross-compilation a faire : on telecharge le binaire de l'architecture cible.
#  C'est ce qui rend le multi-arch trivial — ni QEMU, ni toolchain Go.
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
ARG ZREPL_VERSION=0.7.0
# -- Depot amont. Passer a `dsh2dsh/zrepl` pour la branche activement maintenue
#    (nomenclature d'assets differente : voir README, section « Variante »).
ARG ZREPL_REPO=zrepl/zrepl
# -- Architecture cible, fournie par buildx (amd64 | arm64).
ARG TARGETARCH

LABEL org.opencontainers.image.title="zrepl" \
      org.opencontainers.image.description="One-stop ZFS backup & replication — binaire statique + outils ZFS en espace utilisateur" \
      org.opencontainers.image.url="https://zrepl.github.io" \
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
 # -- Binaire zrepl + verrou d'integrite. Le fichier de sommes amont est au
 #    format `sha512sum` standard (`<hash>  <nom>`) ; on ne verifie QUE la ligne
 #    de l'architecture cible, les autres assets n'etant pas telecharges.
 && curl -fsSL -o "/tmp/zrepl-linux-${TARGETARCH}" \
      "https://github.com/${ZREPL_REPO}/releases/download/v${ZREPL_VERSION}/zrepl-linux-${TARGETARCH}" \
 && curl -fsSL -o /tmp/sha512sum.txt \
      "https://github.com/${ZREPL_REPO}/releases/download/v${ZREPL_VERSION}/sha512sum.txt" \
 && ( cd /tmp \
      && grep -E "  zrepl-linux-${TARGETARCH}\$" sha512sum.txt \
      && grep -E "  zrepl-linux-${TARGETARCH}\$" sha512sum.txt | sha512sum -c - ) \
 && install -m 0755 "/tmp/zrepl-linux-${TARGETARCH}" /usr/local/bin/zrepl \
 && rm -f /tmp/zrepl-linux-* /tmp/sha512sum.txt \
 # -- Repertoire du socket de controle. zrepl ne stocke AUCUN etat sur disque :
 #    les curseurs de replication sont des proprietes ZFS (`zrepl:cursor`).
 #    Seul /var/run/zrepl/control est ecrit — monte en emptyDir dans le pod.
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
