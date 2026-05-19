# Platform Mairie-Agglo — Kapsule Migration

Plateforme Kubernetes (Scaleway Kapsule) mutualisée pour les 6 apps Django :

- **entreprise** → `entreprise.satkaar.io`
- **ecole** → `ecole.satkaar.io`
- **creche** → `creche.satkaar.io`
- **association** → `association.satkaar.io`
- **document-citoyen** → `documents.satkaar.io`
- **crm-mairie-agglo** → `crm.satkaar.io`

## Architecture cible

```
                  Internet
                     │
                     ▼
          ┌──────────────────────┐
          │ LoadBalancer Scaleway│ ← 1 IP publique, géré par Scaleway
          └──────────┬───────────┘
                     │
                     ▼
          ┌──────────────────────┐
          │ Ingress NGINX        │ ← TLS via cert-manager (Let's Encrypt)
          └──────────┬───────────┘
                     │
       ┌────┬────┬───┴────┬────┬────┐
       ▼    ▼    ▼        ▼    ▼    ▼
     ns:  ns:  ns:       ns:  ns:  ns:
   entr. ecol crech    assoc doc  crm
       │    │    │        │    │    │
       └────┴────┴───┬────┴────┴────┘
                     ▼
          ┌──────────────────────┐
          │ Managed Postgres     │ ← 1 instance, 6 databases isolées
          │ (DB-DEV-S, 20 Go)    │   6 users distincts, mdp aléatoires
          └──────────────────────┘
```

## Coût estimé

| Composant | Coût mensuel |
|---|---|
| Kapsule control plane | 0 € (gratuit, version non-Dedicated) |
| 3× nœuds PRO2-XXS | ~45 € |
| LoadBalancer | ~9 € |
| Managed Postgres DB-DEV-S 20Go | ~12 € |
| Container Registry | ~0 € (free tier) |
| **Total** | **~70 €/mois** |

Vs. aujourd'hui : 6 Postgres séparés + 6 Serverless Containers, probablement >100 €/mois.

## Arborescence

```
platform/
├── terraform/
│   ├── shared/                 # projet Scaleway + bucket state + Container Registry
│   ├── envs/prod/              # VPC + Kapsule + Postgres + Ingress + cert-manager
│   └── Makefile                # bootstrap commands
├── helm/
│   ├── django-app/             # chart générique Django
│   └── values/                 # values par app (6 fichiers)
├── dockerfiles/
│   ├── Dockerfile.django-simple
│   └── entrypoint-simple.sh
└── scripts/
    ├── install-dockerfile.sh           # copie le Dockerfile dans une app simple
    ├── cert-manager-issuer.yaml        # ClusterIssuer Let's Encrypt (post-apply)
    ├── build-and-push.sh               # docker build + push vers registry
    ├── helm-deploy.sh                  # helm upgrade --install
    └── migrate-sqlite-to-postgres.sh   # data migration
```

## Runbook

### Pré-requis

- `scw` CLI configuré (clé IAM avec accès projet + Object Storage + Container Registry)
- `terraform` >= 1.5
- `kubectl` et `helm`
- `docker` (avec `buildx` pour build multi-arch)
- Variables d'env OVH : `OVH_APPLICATION_KEY`, `OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY`, `OVH_ENDPOINT=ovh-eu`
- Login Container Registry Scaleway :
  ```
  docker login rg.fr-par.scw.cloud -u nologin -p <scw_secret_key>
  ```

### 1. Provision infra Scaleway

```bash
cd platform/terraform

# 1a. Couche shared (projet + bucket state + registry)
make shared-init
make shared-apply
PROJECT_ID=$(cd shared && terraform output -raw project_id)

# 1b. Préparer envs/prod/terraform.tfvars
cp envs/prod/terraform.tfvars.example envs/prod/terraform.tfvars
# Éditer terraform.tfvars : remplacer scaleway_organization_id et project_id
# (project_id = valeur de $PROJECT_ID ci-dessus)

# 1c. Bootstrap cluster (les providers K8s/Helm ne peuvent pas planifier avant
# que le cluster existe — d'où ce pas séparé)
make prod-init
make prod-bootstrap

# 1d. Reste de l'infra : Postgres, Ingress NGINX, cert-manager, namespaces, secrets DB
make prod-apply

# 1e. ClusterIssuer Let's Encrypt (après installation des CRDs cert-manager)
make apply-issuer

# 1f. Récupérer l'IP du LoadBalancer (visible ~1-2 min après prod-apply)
make lb-ip

# 1g. Créer les records DNS OVH une fois l'IP connue
make prod-apply-dns
```

### 2. Récupérer le kubeconfig

```bash
make kubeconfig > ~/.kube/mairie-agglo-prod.yaml
export KUBECONFIG=~/.kube/mairie-agglo-prod.yaml
kubectl get nodes
```

### 3. Créer les secrets applicatifs (apps qui en ont besoin)

```bash
# document-citoyen
kubectl -n document-citoyen create secret generic document-citoyen-secrets \
  --from-literal=DJANGO_SECRET_KEY=$(openssl rand -hex 32) \
  --from-literal=KATARINA_CRM_TOKEN=xxx \
  --from-literal=CRM_WEBHOOK_SECRET=xxx \
  --from-literal=AWS_ACCESS_KEY_ID=xxx \
  --from-literal=AWS_SECRET_ACCESS_KEY=xxx \
  --from-literal=AWS_STORAGE_BUCKET_NAME=katarina-media-prod

# crm-mairie-agglo
kubectl -n crm-mairie-agglo create secret generic crm-secrets \
  --from-literal=DJANGO_SECRET_KEY=$(openssl rand -hex 32) \
  --from-literal=MISTRAL_API_KEY=xxx \
  --from-literal=KATARINA_CRM_TOKEN=xxx \
  --from-literal=CRM_WEBHOOK_SECRET=xxx \
  --from-literal=DIRECTION_GENERALE_PASSWORD=xxx \
  --from-literal=EMAIL_HOST_USER=xxx \
  --from-literal=EMAIL_HOST_PASSWORD=xxx
```

### 4. Build + push images

```bash
# Une app à la fois (recommandé pour la 1ère fois)
./platform/scripts/build-and-push.sh entreprise v1.0.0

# Ou tout en série
for app in entreprise ecole creche association document-citoyen crm-mairie-agglo; do
  ./platform/scripts/build-and-push.sh "$app" v1.0.0
done
```

### 5. Deploy via Helm

```bash
./platform/scripts/helm-deploy.sh entreprise v1.0.0
./platform/scripts/helm-deploy.sh ecole v1.0.0
# ...
```

### 6. Migration data SQLite → Postgres (4 apps simples)

```bash
# Pour chaque app simple qui a une db.sqlite3 à migrer :
./platform/scripts/migrate-sqlite-to-postgres.sh entreprise
./platform/scripts/migrate-sqlite-to-postgres.sh ecole
./platform/scripts/migrate-sqlite-to-postgres.sh creche
./platform/scripts/migrate-sqlite-to-postgres.sh association
```

Pour **document-citoyen** et **crm-mairie-agglo** qui tournent déjà sur Postgres : utiliser `pg_dump` depuis l'ancienne base puis `pg_restore` vers la nouvelle Postgres mutualisée.

### 7. Vérifier

```bash
# Pods up
kubectl get pods -A

# Ingress avec cert TLS
kubectl get ingress -A
kubectl get certificate -A

# Logs d'une app
kubectl -n entreprise logs -l app.kubernetes.io/name=entreprise --tail=50

# Tester depuis Internet (après propagation DNS)
curl -I https://entreprise.satkaar.io
```

## Runner Telegram MTProto (CRM)

Le CRM a un daemon Telegram (Telethon MTProto) qui doit tourner en **singleton** à côté du web. Le dispatch est fait par `entrypoint.sh` du CRM via la variable `RUN_MODE=runner` (qui delegate à `entrypoint-runner.sh`). On utilise donc la **même image Docker** que le web, et on déploie une **2ème release Helm** sur le **même chart** `django-app` avec des values différentes (`helm/values/crm-mairie-agglo-runner.yaml`).

**Caractéristiques du déploiement runner :**

- `replicaCount: 1` (sessions MTProto rejettent la concurrence — Telegram invalide les sessions ouvertes en parallèle)
- `service.enabled: false` et `ingress.enabled: false` (daemon en arrière-plan, pas de trafic HTTP entrant)
- Probes K8s sur le mini HTTP server intégré au runner : `/healthz` (liveness), `/readyz` (readiness), port 8080
- Sessions MTProto stockées **chiffrées en DB Postgres** (champ `session_encrypted` de `TelegramAccount`, chiffré via Fernet) → aucun PVC ni stockage persistant nécessaire
- Déployé **dans le même namespace** que le CRM web (`crm-mairie-agglo`) pour partager le secret `db-credentials` et `crm-secrets`

### Setup une fois pour toutes

#### 1. Obtenir les credentials Telegram

Aller sur **https://my.telegram.org** → "API development tools" → créer une application. Noter :
- `api_id` (entier)
- `api_hash` (chaîne hex 32 caractères)

#### 2. Générer la clé Fernet (chiffrement des sessions en DB)

```bash
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
# → ex: gAAAAABl...= (44 caractères, urlsafe base64)
```

⚠️ **Cette clé est définitive** : si tu la perds, tu ne peux plus déchiffrer les sessions stockées. Si tu la changes, tous les comptes liés devront être ré-authentifiés.

#### 3. Créer le secret K8s `crm-telegram-secrets`

Dans le **même namespace** que le CRM web :

```bash
kubectl -n crm-mairie-agglo create secret generic crm-telegram-secrets \
  --from-literal=TELEGRAM_API_ID=<api_id> \
  --from-literal=TELEGRAM_API_HASH=<api_hash> \
  --from-literal=TELEGRAM_FERNET_KEY=<fernet_key>
```

### Déploiement

```bash
# Build : image déjà buildée pour le web, on la réutilise telle quelle.
# Si elle n'est pas encore poussée :
./platform/scripts/build-and-push.sh crm-mairie-agglo v1.0.0

# Deploy du runner dans le namespace du CRM web (pour partager les secrets)
./platform/scripts/helm-deploy.sh crm-mairie-agglo-runner v1.0.0 \
    --namespace crm-mairie-agglo

# Vérifier
kubectl -n crm-mairie-agglo get pods -l app.kubernetes.io/instance=crm-mairie-agglo-runner
kubectl -n crm-mairie-agglo logs -l app.kubernetes.io/instance=crm-mairie-agglo-runner --tail=100 -f
```

Logs attendus au boot :
```
==> RUN_MODE=runner — délégation à entrypoint-runner.sh
==> Running migrations (idempotent, partagé avec le service web)...
==> Starting telegram_runner on PORT=8080...
telegram_runner: démarrage (api_id=..., once=False, http_port=8080, no_http=False)
telegram_runner: HTTP healthz écoute sur 0.0.0.0:8080
telegram_runner: heartbeat (logins=0, clients=0, syncs=0)
```

### Première authentification d'un compte Telegram

Aucune commande shell à lancer côté infra — tout se fait via **l'UI du CRM web** :

1. Se connecter au CRM web (`https://crm.satkaar.io`)
2. Aller sur la page "Compte Telegram" (URL exposée par l'app `telegram` du CRM)
3. Cliquer sur "Lier mon compte"
4. Le runner détecte la `TelegramLoginRequest(pending)` en DB, génère un QR code et le renvoie via une mise à jour du statut
5. Scanner le QR avec l'app Telegram mobile → confirmer
6. (Si 2FA activé : saisir le mot de passe Telegram dans le formulaire CRM)
7. Le runner persiste la session chiffrée dans `TelegramAccount.session_encrypted`
8. Au prochain cycle de réconciliation (≤1s), le runner connecte un client MTProto pour ce compte et démarre la sync historique des chats

Si on perd le pod runner (crash, rolling update), il rechargera la session depuis la DB au prochain démarrage — pas besoin de re-scanner.

### Désactiver / arrêter le runner

```bash
# Stop temporaire
kubectl -n crm-mairie-agglo scale deployment crm-runner --replicas=0

# Suppression complète
helm -n crm-mairie-agglo uninstall crm-mairie-agglo-runner
```

Les sessions restent en DB : on peut redéployer plus tard sans perdre les comptes liés.

---

## Migrations DB + seeds via Job Helm pre-upgrade

Le chart `django-app` supporte un **Job Helm `pre-install,pre-upgrade`** qui exécute migrate + seeds **une seule fois** par `helm upgrade`, avant le rolling update des pods web. Permet de scaler le Deployment à >1 réplica sans collisions de seed concurrents.

**Activation côté values :**

```yaml
env:
  SKIP_DB_INIT: "true"   # le pod web saute migrate/seeds (gérés par le Job)

migrationJob:
  enabled: true
  command: ["./entrypoint-migrate.sh"]
  activeDeadlineSeconds: 900
```

**Pré-requis côté image** : l'entrypoint applicatif doit :
1. Skip migrate/seeds si `SKIP_DB_INIT=true`
2. Exposer un `entrypoint-migrate.sh` qui fait migrate + seeds + exit 0

Déjà en place sur le CRM (`crm-mairie-agglo/entrypoint-migrate.sh` + gate `SKIP_DB_INIT` dans `entrypoint.sh`). Le CRM tourne en `replicaCount: 2` à présent.

**Inspecter le Job après un upgrade :**

```bash
kubectl -n crm-mairie-agglo get jobs
kubectl -n crm-mairie-agglo logs job/crm-mairie-agglo-migrate
```

Le Job précédent n'est PAS supprimé sur succès (hook-delete-policy: `before-hook-creation` seul) : logs consultables jusqu'au prochain déploiement.

**Si le Job échoue** : `helm upgrade` échoue et l'ancien Deployment reste en place (pas de rolling update lancé). Investiguer via `kubectl logs job/...-migrate`, corriger, relancer `helm upgrade`.

---

## Points d'attention pour demain

### Migration prod : cutover DNS

Surtout **ne pas** modifier les records DNS prod (s'il y en a déjà) sans :

1. Avoir déployé et testé l'app sur Kapsule avec un sous-domaine *staging* (ex: `entreprise-k8s.satkaar.io`)
2. Avoir vérifié que toutes les données sont bien migrées
3. Réduire TTL DNS à 60s la veille pour rollback rapide
4. Faire le cutover en heure creuse
5. Garder les anciens Serverless Containers en standby ~7 jours

### Postgres : passage en réseau privé

Pour ce soir, Postgres a son endpoint LB public (avec SSL + auth). Plus tard, le durcir :

1. Ajouter `private_network` block au `scaleway_rdb_instance.shared`
2. Configurer un peering VPC ↔ Postgres
3. Modifier les `DATABASE_URL` dans les secrets K8s pour utiliser l'IP privée

## Maintenance

```bash
# Mettre à jour une app (nouvelle image)
./platform/scripts/build-and-push.sh entreprise v1.0.1
./platform/scripts/helm-deploy.sh entreprise v1.0.1

# Rollback Helm
helm -n entreprise rollback entreprise

# Voir les events du namespace
kubectl -n entreprise get events --sort-by=.lastTimestamp

# Accéder à un shell dans un pod
kubectl -n entreprise exec -it deployment/entreprise -- /bin/sh
```

---

## CI/CD GitHub Actions (preprod + prod)

Chaque app (entreprise, ecole, creche, association, document-citoyen, crm-mairie-agglo) a un `.github/workflows/` qui appelle deux **reusable workflows** centralisés dans ce repo :

- `platform/.github/workflows/reusable-django-ci.yml` — tests Django sur Postgres 16 + hadolint
- `platform/.github/workflows/reusable-deploy.yml` — build buildx, scan Trivy, helm upgrade --atomic, smoke test

### Mapping branche → environnement

| Branche push | Environnement | Namespace K8s | Hôte | Approval |
|---|---|---|---|---|
| `preprod` | `preprod` | `<app>-preprod` | `preprod.<sub>.satkaar.io` | non |
| `main` | `prod` | `<app>` | `<sub>.satkaar.io` | **required reviewer** (GitHub Environment) |
| `workflow_dispatch` | au choix | selon input | selon input | selon env |

PR et push sur `develop` ne déclenchent que la CI (tests + lint), pas de deploy.

### Mode parallèle Kapsule ↔ Serverless Containers (cutover)

Pendant la phase de migration, les apps `document-citoyen` et `crm-mairie-agglo` ont **deux** workflows de deploy qui tournent en doublon sur les mêmes triggers :

| Workflow | Cible | Fichier | À garder jusqu'à |
|---|---|---|---|
| 🚢 Build & Deploy (Kapsule) | nouveau cluster Kapsule | `.github/workflows/deploy.yml` | définitif |
| 🚀 Deploy Serverless Containers (prod) [LEGACY] | ancienne infra Scaleway Serverless | `.github/workflows/deploy-serverless.yml` | DNS cutover validé |
| 🧪 Deploy Serverless Containers (preprod) [LEGACY] | (document-citoyen uniquement) | `.github/workflows/deploy-serverless-preprod.yml` | DNS cutover validé |

**Pourquoi tourner les deux en parallèle :**
- Le DNS prod pointe encore sur les Serverless Containers → l'ancienne pipe doit continuer à servir le trafic réel.
- En même temps Kapsule reçoit les mêmes images et les mêmes migrations → on valide en continu que la nouvelle infra suit le code.
- Smoke test Kapsule = test sur `preprod.<sub>.satkaar.io` (DNS déjà fonctionnel) ou sur `<sub>.satkaar.io` (qui pointe pas encore sur Kapsule → le smoke test échouera tant que le DNS n'a pas basculé — c'est normal et attendu pour la branche `main`).
- Quand le DNS bascule, on désactive les workflows legacy.

**Désactiver les workflows legacy au cutover :**

```bash
# Renommer en .yml.disabled (GitHub Actions ignore les fichiers non-.yml)
# document-citoyen
mv .github/workflows/deploy-serverless.yml .github/workflows/deploy-serverless.yml.disabled
mv .github/workflows/deploy-serverless-preprod.yml .github/workflows/deploy-serverless-preprod.yml.disabled

# crm-mairie-agglo
mv .github/workflows/deploy-serverless.yml .github/workflows/deploy-serverless.yml.disabled

git add -A && git commit -m "chore(ci): disable legacy Serverless Containers workflows (cutover terminé)"
```

Garder les fichiers `.disabled` ~7 jours après cutover : si rollback nécessaire (`mv X.disabled X`) tu peux remettre les Serverless Containers en service en 1 commit.

**Note CI** : un seul `ci.yml` reste — il teste le code qui est build pour les DEUX infras (même Dockerfile, mêmes migrations Postgres). Pas besoin de doublon côté CI.

### Pipeline de deploy

```
push branch
   │
   ▼
resolve-env ──► build ──► scan (Trivy) ──► deploy ──► smoke-test ──► [deploy-runner si CRM]
                                              ▲
                                              │ Approval manuelle GitHub UI
                                              │ uniquement pour prod
```

Best-practices appliquées :

- **`concurrency`** : un push ne tue pas un deploy en cours (cancel-in-progress: false)
- **Tags d'image immuables** : `<env>-<sha12>` épinglé dans `--set image.tag`, force le re-pull K8s
- **`helm upgrade --atomic --wait --timeout 10m`** : rollback automatique si rollout échoue
- **Trivy SARIF** : remonte les CVE dans GitHub Security tab, bloque sur CRITICAL/HIGH non-unfixed
- **Build cache `type=registry`** : layers cachées par env pour des builds rapides
- **`provenance: false`, `sbom: false`** : compat avec Scaleway Container Registry (refuse les attestations OCI)
- **Pre-deploy guard** : refuse le deploy si namespace ou secret `db-credentials` manquant (faute de Terraform appliqué)
- **Smoke test** : 18 retries × 10s sur l'URL HTTPS publique, accepte 200/301/302/401/403
- **`permissions: contents: read`** par défaut, `security-events: write` uniquement sur scan
- **GitHub Environments** : `preprod` (open) et `production` (required reviewer + déploiement journalisé)
- **Dependabot** : pip hebdomadaire + actions hebdomadaire + base Docker mensuelle
- **PR template** : checklist tests/migrations/secrets

### Setup une fois pour toutes

#### 1. Activer le partage du repo platform pour les reusable workflows

`satkaar/platform` → Settings → Actions → General → **Access** :
- Cocher **« Accessible from repositories owned by 'satkaar' »**

Sans ça les 6 apps ne peuvent pas faire `uses: satkaar/platform/.github/workflows/...@main`.

#### 2. Créer les GitHub Environments dans chaque app repo

Pour chacun des 6 repos applicatifs : Settings → Environments → New environment.

| Name | Required reviewers | Wait timer | Deployment branches |
|---|---|---|---|
| `preprod` | aucun | 0 min | uniquement `preprod` |
| `production` | toi-même (ou équipe) | 0 min (ou 5 min pour rollback rapide) | uniquement `main` |

#### 3. Configurer les secrets/vars (au niveau org `satkaar` ou par repo)

**Secrets** (Settings → Secrets and variables → Actions → Secrets) :

| Nom | Valeur | Scope |
|---|---|---|
| `SCW_ACCESS_KEY` | clé IAM Scaleway (Container Registry + Kapsule read/write) | org ou repo |
| `SCW_SECRET_KEY` | secret IAM Scaleway | org ou repo |
| `PLATFORM_REPO_TOKEN` | fine-grained PAT, scope `satkaar/platform` → Contents: read | org ou repo |

**Variables** (Settings → Secrets and variables → Actions → Variables) :

| Nom | Valeur | Scope |
|---|---|---|
| `SCW_DEFAULT_PROJECT_ID` | ID du projet Scaleway (output `make shared-output`) | org ou repo |
| `SCW_DEFAULT_ORGANIZATION_ID` | ID de l'org Scaleway | org ou repo |

Recommandé : configurer en **org-level** pour éviter les 6 répétitions.

#### 4. Provisionner l'infrastructure preprod (Terraform)

Le fichier `terraform/envs/prod/preprod.tf` ajoute :
- 6 databases preprod (`<db_name>_preprod`) + users + privileges sur la **même instance Postgres mutualisée** (cf. answer pattern : ns séparés, DB séparées, instance unique → ~+0 € pour la DB en plus de l'existant, seules les CPU/RAM Postgres sont partagées)
- 6 namespaces K8s `<app>-preprod` + secret `db-credentials`
- 6 records DNS A `preprod.<sub>.satkaar.io` → IP LB Ingress

```bash
cd platform/terraform
make prod-apply           # crée DB + namespaces + secrets preprod
make prod-apply-dns       # crée les records DNS preprod (une fois l'IP LB stable)
```

#### 5. Créer les secrets applicatifs dans les namespaces preprod

Comme pour la prod, les secrets non-DB (DJANGO_SECRET_KEY, KATARINA_CRM_TOKEN, MISTRAL, S3, SMTP…) ne sont **pas** provisionnés par Terraform — à créer manuellement :

```bash
# document-citoyen preprod
kubectl -n document-citoyen-preprod create secret generic document-citoyen-secrets \
  --from-literal=DJANGO_SECRET_KEY=$(openssl rand -hex 32) \
  --from-literal=KATARINA_CRM_TOKEN=<token-preprod> \
  --from-literal=CRM_WEBHOOK_SECRET=<secret-preprod> \
  --from-literal=AWS_ACCESS_KEY_ID=<...> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<...> \
  --from-literal=AWS_STORAGE_BUCKET_NAME=katarina-media-preprod

# crm-mairie-agglo preprod
kubectl -n crm-mairie-agglo-preprod create secret generic crm-secrets \
  --from-literal=DJANGO_SECRET_KEY=$(openssl rand -hex 32) \
  --from-literal=MISTRAL_API_KEY=<...> \
  --from-literal=KATARINA_CRM_TOKEN=<...> \
  ... (cf. helm/values/crm-mairie-agglo.yaml pour la liste complète)

# crm-mairie-agglo-preprod : aussi le secret Telegram pour le runner
kubectl -n crm-mairie-agglo-preprod create secret generic crm-telegram-secrets \
  --from-literal=TELEGRAM_API_ID=<...> \
  --from-literal=TELEGRAM_API_HASH=<...> \
  --from-literal=TELEGRAM_FERNET_KEY=<une-NOUVELLE-clé-distincte-de-la-prod>
```

⚠ **Ne jamais réutiliser la `TELEGRAM_FERNET_KEY` prod en preprod** — les sessions sont chiffrées avec, et tu veux pouvoir tester preprod sans toucher aux comptes Telegram prod.

#### 6. Créer les branches preprod

Dans chaque app :

```bash
git checkout -b preprod
git push -u origin preprod
```

À partir de là le workflow est :
- Dev fait un PR vers `preprod` → CI tourne → merge → deploy preprod auto
- QA OK → PR `preprod` → `main` → CI tourne → merge → deploy prod **avec approval manuelle**

### Rollback

```bash
# Lister les revisions Helm
helm -n entreprise history entreprise

# Rollback à la revision précédente
helm -n entreprise rollback entreprise

# Ou explicitement à une revision N
helm -n entreprise rollback entreprise 4
```

`--atomic` rollback automatiquement si `helm upgrade` échoue, donc en pratique ce rollback manuel n'est utile que pour annuler un deploy qui a réussi techniquement mais introduit un bug fonctionnel.

### Troubleshooting CI/CD

| Symptôme | Cause probable | Fix |
|---|---|---|
| `Cluster '...' introuvable` | Mauvais `K8S_CLUSTER_NAME` ou IAM sans accès | Vérifier `vars.SCW_DEFAULT_PROJECT_ID` et `secrets.SCW_*` |
| `Namespace '<app>-preprod' absent` | Terraform preprod pas appliqué | `cd platform/terraform && make prod-apply` |
| `Secret db-credentials manquant` | Idem | Idem |
| Trivy fail HIGH/CRITICAL | CVE dans la base image ou une dépendance | Bumper la base ou patcher la lib ; en dernier recours mettre `exit-code: "0"` *temporairement* |
| Helm upgrade timeout | Pod ne devient pas Ready (probe, crash, OOM) | `kubectl -n <ns> describe pod <pod>` + `kubectl logs` |
| Smoke test KO mais pod up | DNS preprod pas propagé, cert TLS pas émis | Attendre 2 min ; `kubectl get certificate -n <ns>` |
| `uses: satkaar/platform/...` 404 | Accès reusable workflow non autorisé | Repo platform → Settings → Actions → General → Access |
