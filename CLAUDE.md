# CLAUDE.md — Kasten-Disco-Lite

## Projet
**Kasten Discovery Lite (KDL)** — script de découverte *read-only* pour analyser une
infrastructure de sauvegarde Veeam Kasten K10. Produit un inventaire « support-grade »
(santé, RBAC, politiques, RPO effectif, score de readiness ransomware, conformité aux
bonnes pratiques, etc.) à partir d'un cluster Kubernetes/OpenShift.

## Stack technique
- **Langage** : shell POSIX (`#!/bin/sh`, `set -eu`) — point d'entrée `KDL.sh`
- **Dépendances runtime** : `oc` (OpenShift) ou `kubectl`, `jq`
- **CLI OpenShift** : `oc` utilisé en priorité quand OpenShift est détecté (switch introduit en v2.0.1, `#cli-switch`)
- **Sorties** : JSON + HTML (`kdl-json-to-html.sh`, `kdl-diff.sh`)
- **Contraintes** : portable, POSIX-compliant, sortie pure ASCII

## Fichiers clés
- `KDL.sh` — script principal de découverte
- `kdl-json-to-html.sh` — rendu HTML à partir du JSON
- `kdl-diff.sh` — comparaison entre deux découvertes
- `kdl-rbac.yaml` — RBAC minimal requis pour exécuter le script
- `CHANGELOG.md`, `RELEASING.md` — gestion des versions / process de release

## État courant (2026-08-19)
- Branche de travail : `dev-2.2.0-kasten-v9` (poussée). `main` est encore en
  v2.1.1 sur `df21cd4` et ne contient **rien** de la 2.2.0.
- `proto-go` est un prototype de réécriture Go, indépendant.
- Remote : https://github.com/BertV44/Kasten-Disco-Lite.git
- v2.2.0 : compatibilité Kasten 9.0 + un lot de correctifs de précision issus de
  deux rapports de production (`ocp-infra-prd-2` en 8.5, `kasten-se-lab` en
  9.0.1). Exécutée sur cluster 9.0.1 réel.
- Gate : `kdl-v9-validate.sh` (nécessite un cluster). Hors cluster, un faux
  `kubectl` renvoyant `{"items":[]}` exerce tout le script et attrape les
  variables non initialisées sous `set -eu`.

## Compatibilité Kasten
- Version Kasten validée max : **9.0** (`KDL_KASTEN_TESTED_MAX` dans `KDL.sh`).
  À mettre à jour à chaque nouvelle version Kasten supportée — le script avertit
  quand le cluster est plus récent (`kastenCompatibility.newerThanValidated`).
- Sélecteurs de policy Kasten (mutuellement exclusifs) :
  `appNamespace` (namespaces) · `virtualMachineRef` (`ns/vmName`, 8.5+) ·
  `virtualMachineNamespace` (namespaces + `matchLabels` sur les **VM**, 9.0+).
  Helpers jq partagés dans `JQ_SELECTOR_LIB` (`policy_scope`, `glob_match`,
  `resolved_ns`) — à réutiliser plutôt que de redupliquer la logique.
- Depuis 9.0 une policy peut porter **deux actions `export`** (additional
  export) : ne jamais utiliser `first` sur la liste des actions export.
- **Schéma RestorePoint en 9.0** : `spec.source` est **absent** (null) sur
  *tous* les RestorePoints — vérifié sur un cluster 9.0.3 réel, et le même échec
  s'observait en 8.5. Donc `.spec.source.actionName` n'existe pas : c'est ce qui
  faisait planter la détection d'orphelins sur *tout* cluster 9.0 (`null |
  split("-")`), pas un cas limite. L'attribution passe par le label
  `k10.kasten.io/policyName`, que Kasten renseigne (aux côtés de `appName`,
  `appNamespace`, `appType`, `policyNamespace`, `runActionName`). Le chemin par
  nom d'action ne subsiste que pour d'anciens catalogues. Si ni le label ni le
  nom d'action ne sont présents, l'attribution est impossible et la section doit
  passer en `NOT_ASSESSED` plutôt que d'annoncer zéro orphelin.
- **Sémantique des wildcards de sélecteur** (doc Kasten, `usage/protect`
  #application-selection) : deux formes seulement sont documentées — `*` seul
  (toutes les applications) et un wildcard **en fin** qui matche les noms
  *commençant par* le préfixe. `glob_match` ancré est conforme aux deux
  (`prod-*` -> `^prod-.*$`). Toute autre position (`*-bit`, `bia*bit`) n'a pas de
  sémantique définie : ne **jamais** deviner, ça se trompe dans les deux sens
  (`*-bit` en glob strict matche `foo-bit` alors qu'un moteur préfixe ne matche
  rien -> surestimation de la protection -> gaps masqués). Ces motifs rendent la
  policy non résoluble et forcent `NOT_ASSESSED`
  (`nonStandardPatterns`).
- `matchNames` est une forme de sélecteur à part entière : l'oublier fait tomber
  la policy dans la branche catch-all et marque **tous** les namespaces comme
  protégés — le sens dangereux. Seul un sélecteur réellement vide est un
  catch-all.
- Les sélecteurs matchExpressions/matchLabels se combinent en **ET** (comme tout
  LabelSelector Kubernetes). Les unionner surestime la couverture, donc masque
  des gaps.

## Conventions détectées
- Versioning sémantique aligné sur les versions Kasten (v1.9.x → v2.2.x)
- Commits conventionnels (`feat:`, `docs:`, `fix:`)
- Branches de dev par version (`dev-X.Y`)
- 16 best-practices checks avec niveaux de sévérité
- Pièges jq récurrents (déjà corrigés, à ne pas réintroduire) :
  `select(.spec.actions[]?.action == "x")` duplique l'élément une fois par
  action correspondante → utiliser `select([...] | index("x"))` ; une
  comparaison dans une valeur d'objet jq doit être parenthésée.
  `["a","b"] | index(.)` cherche le tableau **dans lui-même** et renvoie
  toujours `0` → lier la valeur d'abord : `. as $o | [...] | index($o)`.
  L'argument d'une fonction est évalué dans le contexte de l'entrée **au point
  d'appel** : après `$ns | f(.)`, le `.` transmis vaut `$ns`, pas l'élément
  courant du générateur englobant → lier : `. as $e | ($ns | f($e))`.
  Aucun des deux ne lève d'erreur : ils renvoient silencieusement un faux
  résultat, d'où l'obligation de tester chaque filtre sur fixtures.
- Deux vues de la protection, à ne pas confondre : la vue **sélecteur**
  (`coverage.*`, quels namespaces une policy cible) et la vue **preuve**
  (`namespaceProtectionStatus`, quels namespaces ont réellement un backup
  réussi). La preuve prime toujours sur l'inférence : un namespace sauvegardé
  n'est jamais un gap. Voir `backedUpDespiteSelector`.
- Un calcul en échec ne doit jamais se rendre comme un résultat propre :
  utiliser le motif `NOT_ASSESSED` (licence, couverture, orphelins) plutôt
  qu'un zéro de repli. `_jq_fail` n'écrit que sur stderr — il faut en plus
  propager un statut jusqu'au JSON et au HTML.

## Prochaine action
<!-- À remplir manuellement -->
