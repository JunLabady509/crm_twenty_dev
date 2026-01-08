# 🚀 Twenty – Scripts de bootstrap et de développement

Ce projet fournit **deux scripts Bash complémentaires** pour travailler efficacement sur le CRM **Twenty** en environnement de développement, avec **hot reload**, **Docker pour les dépendances**, et **Node/Yarn isolés via nvm**.

Objectif :
- zéro configuration manuelle répétée
- scripts relançables sans casser l’environnement
- focus sur le développement, pas sur le tooling

---

## 🧱 Vue d’ensemble

| Script | Rôle | Quand l’utiliser |
|------|------|------------------|
| `preparation_dev.sh` | Prépare la machine + clone le projet | **Une seule fois par machine** |
| `run_twenty.sh` | Lance l’app en dev (hot reload) | **À chaque session de dev** |

---

## 1️⃣ `preparation_dev.sh` — Bootstrap de la machine

### 🎯 Objectif
Mettre une machine Linux (Ubuntu, Debian, Fedora, Rocky) dans un état **compatible avec Twenty**, sans dépendre de la distribution.

---

### 🧩 Ce que fait le script

- Détecte automatiquement la distribution :
  - Debian / Ubuntu
  - Fedora / Rocky / RHEL-like
- Installe les prérequis système :
  - `curl`, `git`, `make`
  - Docker Engine + Docker Compose plugin
- Démarre Docker et ajoute l’utilisateur au groupe `docker`
- Clone le dépôt officiel : https://github.com/twentyhq/twenty.git
- Se place automatiquement dans le dossier `twenty/`
- (Optionnel mais recommandé) :
- installe `nvm`
- installe **Node 24.5.0**
- active **Yarn 4.9.2 via Corepack**

---

### ▶️ Utilisation

```bash
chmod +x preparation_dev.sh
./preparation_dev.sh

```
## 2️⃣ run_twenty.sh — Lancement du dev en hot reload

### 🎯 Objectif
Lancer Twenty en développement, avec :
- hot reload frontend & backend
- Postgres + Redis en Docker
- vérifications automatiques de l’environnement
- sans réinstaller inutilement les dépendances

👉 C’est le bouton “Start Dev”.

### 🧩 Ce que fait le script
À chaque exécution :
- Vérifie et force :
    - Node 24.5.0 via nvm
    - Yarn 4.9.2 via corepack
    - Vérifie que Yarn système (/usr/bin/yarn) ne parasite pas
    - Vérifie / crée les fichiers .env
    - Vérifie les limites Linux inotify (watchers) et les augmente si nécessaire (évite l’erreur ENOSPC)

- Démarre les dépendances Docker :
    - Postgres (twenty_pg)
    - Redis (twenty_redis)
    - sans erreur bloquante si tout existe déjà

- Lance yarn install uniquement si yarn.lock a changé
- (Optionnel) reset la base de données
- Lance nx start → hot reload actif

### ▶️ Utilisation de base
    chmod +x run_twenty.sh
    cd twenty
    ../run_twenty.sh

## ⚙️ Options disponibles
- Option                Effet
    - --no-reset	Ne reset pas la base de données
    - --no-install	Skip yarn install
    - --server-only	Lance uniquement le backend
    - --front-only	Lance uniquement le frontend
    - --help	Affiche l’aide
Exemples
# Dev classique sans reset DB
./run_twenty.sh --no-reset

# Backend uniquement
./run_twenty.sh --server-only

# Lancement rapide sans toucher aux deps
./run_twenty.sh --no-install --no-reset

# 🧠 Philosophie des scripts
- Idempotents : relançables sans punition
- Déterministes : même état → même résultat
- Portables :
    - Ubuntu
    - Debian
    - Fedora
    - Rocky Linux

- Séparation claire des rôles :
    - bootstrap ≠ runtime dev
    - Pas de Docker inutile :
    - Node/Yarn en user-space
    - DB/Redis en conteneurs

## 🧯 Dépannage rapide
### ❌ ENOSPC: System limit for number of file watchers reached

Géré automatiquement par run_twenty.sh.

Sinon, manuel :

sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=1024

### ❌ Problème Docker
docker ps

Si refus :

newgrp docker

### ❌ Mauvaise version de Node / Yarn
node -v   # doit être v24.5.0
yarn -v   # doit être 4.9.2

## ✅ Workflow recommandé
(une fois)
└─ ./preparation_dev.sh

(au quotidien)
└─ cd twenty
└─ ../run_twenty.sh

# 🏁 Conclusion

## Avec ces deux scripts :
    - changement de machine sans stress
    - relance du projet à volonté
    - plus besoin de mémoriser le setup

👉 Le tooling est maîtrisé.
👉 Le focus revient sur le code et les évolutions du CRM.