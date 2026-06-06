# CLAUDE.md — Kasten Discovery Lite (KDL)

> Ground truth for this repo. Reflects the **actual code on `main` (v1.9.2)**, not
> the aspirational v2.1 narrative found in some loose tracking docs (see
> "État réel vs. docs de suivi" at the bottom).

## Projet

| Attribut | Valeur |
|---|---|
| Nom | Kasten Discovery Lite (KDL) |
| Nature | Outil communautaire personnel, **non-officiel Veeam** |
| But | Discovery & analyse **read-only** d'un déploiement Kasten K10 |
| Auteur | Bertrand Castagnet — EMEA TAM |
| Dépôt | `BertV44/Kasten-Disco-Lite` (GitHub) |
| Branche par défaut | `main` |
| Version courante | **v1.9.2** |
| Langage | **POSIX `sh` strict** (`#!/bin/sh`, pas de bashisms) |

## Fichiers

| Fichier | Rôle |
|---|---|
| `KDL.sh` | Moteur principal. Interroge le cluster (read-only) et produit une sortie texte humaine **ou** JSON. ~4100 lignes, organisé en sections `### --- Titre ---`. |
| `kdl-json-to-html.sh` | Génère un rapport HTML à partir du JSON produit par `KDL.sh`. Rétro-compatible v1.8.1 → v1.9.1 (guards `if .field`). |
| `README.md` | Documentation utilisateur (features, usage). |
| `LICENSE` | Licence du projet. |

> Pas de `kdl-diff.sh`, pas de `sample.md`, pas de tests dans ce dépôt à ce jour
> (ce sont des artefacts de la piste v2.x, non mergés — voir bas de page).

## Lancer / tester

```sh
# Discovery texte
./KDL.sh kasten-io

# JSON (vers fichier — détecte .json automatiquement et désactive la couleur)
./KDL.sh kasten-io --json --output discovery.json

# Debug
./KDL.sh kasten-io --debug --no-color

# Environnement sensible : saute la lecture du secret Helm
./KDL.sh kasten-io --no-helm --json --output secure.json

# Rapport HTML depuis le JSON
./kdl-json-to-html.sh discovery.json discovery.html
```

**Flags** : `--json`, `--debug`, `--no-color`, `--no-helm`, `--output FILE`,
`--version`/`-V`, `--help`/`-h`. Premier argument positionnel = namespace (requis).

**Dépendances runtime** : `kubectl` (ou `oc` — voir détection plateforme), `jq`.
Accès lecture seule au cluster K10.

## Conventions de développement (réelles)

- **Portabilité POSIX stricte** : `#!/bin/sh`, `set -eu`, aucun bashism.
  Vérifier avec `shellcheck -s sh KDL.sh kdl-json-to-html.sh`.
- **Numérique locale-safe** : préfixer les `awk`/`printf` qui émettent des nombres
  par `LC_ALL=C` — sinon `fr_FR` produit `73,0` au lieu de `73.0` et casse le JSON
  (régression corrigée en v1.9.1).
- **CLI cluster** : v1.9.1 appelle **`kubectl` en direct** ; la plateforme OpenShift
  est seulement *détectée* (`PLATFORM`). Il n'y a **pas** d'alias `$CLI` dans cette
  version (c'est une feature v2.x non mergée).
- **Seuils** : **hardcodés** comme variables shell en tête de script
  (`STALE_DAYS_THRESHOLD=7`, `STUCK_HOURS_THRESHOLD=24`). Pas (encore)
  d'override par variable d'environnement — c'est aussi une piste v2.x.
- **Validation JSON** : `--argjson` validé avant émission (évite les échecs silencieux) ;
  helper `jq` `deepest_msg` pour extraire la cause la plus profonde d'une chaîne d'erreurs.
- **Collecte** : fetch partagé (« fetch once, reuse everywhere ») + collecte CRD
  parallèle ; fallback `{"items":[]}` si une requête `kubectl` échoue.
- **Fichiers complets** lors des modifs (pas de patches partiels diffusés).
- **Workflow git réel** : feature sur branche `dev-X.Y` → **Pull Request** → merge sur
  `main`. (Le dernier merge est `#9` depuis `dev-1.9`.) Commiter/pusher uniquement
  sur demande explicite.

## Architecture KDL.sh (repères)

Sections délimitées par des bannières `### --- Titre ---`, dans l'ordre : Args & flags →
Color support → Helpers → Temp files → Namespace validation → Platform detection →
K8s version/distribution → Multi-cluster → Kasten version → Shared data collection →
Parallel CRD collection → License / consumption → … → émission texte ou JSON.

## Jalon **V1.9.2** — état

Délivré via **PR #18** (`dev-1.9.2` → `main`) : #10, #11, #13, #14, #15, #16, #17.

| # | Type | Prio | Titre | Statut |
|---|---|---|---|---|
| 17 | enhancement | P1 | RBAC pre-flight check + discovery-reader ClusterRole | ✅ |
| 15 | bug | P1 | Failed Actions not detected: scope limited to K10 namespace | ✅ |
| 10 | bug | P1 | RestorePoints scope limited to single namespace | ✅ |
| 13 | enhancement | P2 | KDR detection: extend beyond policy presence | ✅ |
| 11 | bug | P2 | Namespace Protection: matchLabels selectors not resolved | ✅ |
| 16 | bug | P3 | Prometheus detection: restrict to K10 namespace | ✅ |
| 14 | enhancement | P3 | License: extract product type and compute duration | ✅ |
| 12 | enhancement | P3 | Resource Limits BP: switch from Warning to Info | ⏳ **non traité** (hors PR #18) |

Consulter une issue : `gh issue view <n>`. Lister : `gh issue list --state open`.

## Branches

- `main` — **v1.9.2** (après merge de la PR #18).
- `dev-1.9` — base des correctifs v1.9.x (mergée via PR #9).
- `dev-2.0` — piste **v2.x** (env vars overridables, détection throttling
  `collectionHealth`, tag `RANSOMWARE`, `kdl-diff.sh`). **Non mergée.** Rattrapage +
  fusion prévus *après* la série v1.9.2.

## État réel vs. docs de suivi (à savoir)

Des fichiers `backlog.md` / `projectstate.md` (dans `~/Downloads/filesKDL300526/`)
décrivent une **v2.1 « livrée »**. Ce n'est **pas** l'état du dépôt :

- Le code v2.1 (env vars, `collectionHealth`, etc.) n'est **commité nulle part** ;
  il existe en fichiers vrac dans `~/Downloads/v20-1205-1604/` (daté 12/05).
- `main` est à **v1.9.1** ; aucune branche `v2.1` n'existe (seulement `dev-2.0`).
- Conventions divergentes dans ces docs (alias `$CLI`, seuils env-overridables,
  « commits directs sans PR ») = features/process **v2.x**, pas v1.9.1.

➡️ Décision actuelle : **travailler sur v1.9.1 / `main`** (issues V1.9.2). La fusion
de la piste v2.x viendra plus tard.
