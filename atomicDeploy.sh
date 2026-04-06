#!/bin/bash
set -euo pipefail

# =========================================================
# CONFIGURAÇÃO
# =========================================================
# FORMATO:
# PROJECTS["nome"]="repo|branch|php_bin|frontend_cmd|composer_mode|run_migrate|healthcheck_artisan"
#
# composer_mode: prod | dev
# run_migrate: yes | no
# healthcheck_artisan: ex: "about" ou "route:list"

declare -A PROJECTS
#PROJECTS["project_1"]="git@github.com:............git|main|/usr/bin/php8.4|build|prod|yes"
#PROJECTS["project_2"]="git@github.com:............git|main|/usr/bin/php8.5|build|prod|yes"

BASE_ROOT="/var/www"
APP_USER="www-data"
WEB_GROUP="www-data"
KEEP_RELEASES=5
LOCK_FILE="/tmp/atomic_deploy.lock"

# =========================================================
# LOCK DE EXECUÇÃO
# =========================================================
exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo "Outro deploy já está em execução."
    exit 1
}

# =========================================================
# FUNÇÕES AUXILIARES
# =========================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

fail() {
    log "ERRO: $1"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Comando obrigatório não encontrado: $1"
}

validate_php_bin() {
    local php_bin="$1"
    [ -x "$php_bin" ] || fail "Binário PHP inválido ou inexistente: $php_bin"
}

ensure_base_commands() {
    require_command git
    require_command composer
    require_command ln
    require_command rm
    require_command mkdir
    require_command chmod
    require_command chown
    require_command readlink
    require_command flock
    require_command grep
    require_command cp
}

ensure_project_structure() {
    local project_name="$1"
    local base_dir="$BASE_ROOT/$project_name"
    local releases_dir="$base_dir/releases"
    local shared_dir="$base_dir/shared"

    log "Garantindo estrutura base do projeto: $project_name"

    sudo mkdir -p "$releases_dir"
    sudo mkdir -p "$shared_dir/storage"
    sudo mkdir -p "$shared_dir/bootstrap/cache"

    sudo mkdir -p "$shared_dir/storage/app"
    sudo mkdir -p "$shared_dir/storage/framework/cache"
    sudo mkdir -p "$shared_dir/storage/framework/sessions"
    sudo mkdir -p "$shared_dir/storage/framework/views"
    sudo mkdir -p "$shared_dir/storage/logs"

    sudo chown -R "$APP_USER:$WEB_GROUP" "$base_dir"
    sudo chmod -R 775 "$shared_dir/storage"
    sudo chmod -R 775 "$shared_dir/bootstrap/cache"
}

cleanup_old_releases() {
    local releases_dir="$1"

    cd "$releases_dir"
    ls -1dt */ 2>/dev/null | tail -n +$((KEEP_RELEASES + 1)) | xargs -r rm -rf
}

check_repo_access() {
    local repo_url="$1"
    git ls-remote "$repo_url" >/dev/null 2>&1 || fail "Não foi possível acessar o repositório: $repo_url"
}

detect_node_manager_and_install() {
    local frontend_cmd="$1"

    if [ ! -f package.json ]; then
        log "Projeto sem package.json, pulando etapa Node"
        return 0
    fi

    if [ -f yarn.lock ]; then
        require_command yarn
        log "Instalando dependências Node com Yarn"
        yarn install --frozen-lockfile

        if [ -n "$frontend_cmd" ] && [ "$frontend_cmd" != "none" ]; then
            log "Executando build front: yarn run $frontend_cmd"
            yarn run "$frontend_cmd"
        fi
        return 0
    fi

    if [ -f pnpm-lock.yaml ]; then
        require_command pnpm
        log "Instalando dependências Node com pnpm"
        pnpm install --frozen-lockfile

        if [ -n "$frontend_cmd" ] && [ "$frontend_cmd" != "none" ]; then
            log "Executando build front: pnpm run $frontend_cmd"
            pnpm run "$frontend_cmd"
        fi
        return 0
    fi

    if [ -f package-lock.json ]; then
        require_command npm
        log "Instalando dependências Node com npm"
        npm ci

        if [ -n "$frontend_cmd" ] && [ "$frontend_cmd" != "none" ]; then
            log "Executando build front: npm run $frontend_cmd"
            npm run "$frontend_cmd"
        fi
        return 0
    fi

    fail "package.json encontrado, mas nenhum lockfile foi encontrado. Abortando por segurança."
}

run_composer_install() {
    local php_bin="$1"
    local composer_mode="$2"
    local release_dir="$3"
    local composer_bin

    composer_bin="$(command -v composer)" || fail "Composer não encontrado"

    if [ "$composer_mode" = "prod" ]; then
        "$php_bin" "$composer_bin" install \
            --working-dir="$release_dir" \
            --no-dev \
            --prefer-dist \
            --optimize-autoloader \
            --no-interaction
    else
        "$php_bin" "$composer_bin" install \
            --working-dir="$release_dir" \
            --prefer-dist \
            --no-interaction
    fi
}

health_check_release() {
    local php_bin="$1"
    local artisan_cmd="$2"

    log "Executando health check básico: php artisan $artisan_cmd"
    "$php_bin" artisan $artisan_cmd >/dev/null 2>&1 || fail "Health check falhou na release"
}

ensure_shared_env_from_example() {
    local shared_dir="$1"
    local release_dir="$2"

    if [ ! -f "$shared_dir/.env" ]; then
        log "Criando .env compartilhado a partir do .env.example"

        if [ -f "$release_dir/.env.example" ]; then
            cp "$release_dir/.env.example" "$shared_dir/.env"
            chown "$APP_USER:$WEB_GROUP" "$shared_dir/.env"
            chmod 664 "$shared_dir/.env"

            log "Arquivo criado: $shared_dir/.env"
            log "ATENÇÃO: revise as variáveis de ambiente antes de usar em produção"
        else
            fail ".env.example não encontrado no repositório"
        fi
    fi
}

ensure_app_key() {
    local php_bin="$1"
    local shared_dir="$2"

    if ! grep -q '^APP_KEY=base64:' "$shared_dir/.env"; then
        log "APP_KEY ausente ou inválida. Gerando automaticamente..."
        "$php_bin" artisan key:generate --force || fail "Falha ao gerar APP_KEY"
    fi
}

deploy_project() {
    local project_name="$1"
    local config="$2"

    IFS="|" read -r repo_url branch php_bin frontend_cmd composer_mode run_migrate healthcheck_artisan <<< "$config"

    local base_dir="$BASE_ROOT/$project_name"
    local releases_dir="$base_dir/releases"
    local shared_dir="$base_dir/shared"
    local current_link="$base_dir/current"
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local release_dir="$releases_dir/$timestamp"
    local previous_current=""

    log "========================================================="
    log "Iniciando deploy do projeto: $project_name"
    log "Repositório: $repo_url"
    log "Branch: $branch"
    log "Nova release: $release_dir"

    validate_php_bin "$php_bin"
    check_repo_access "$repo_url"
    ensure_project_structure "$project_name"

    if [ -L "$current_link" ] || [ -e "$current_link" ]; then
        previous_current="$(readlink -f "$current_link" || true)"
        if [ -n "$previous_current" ]; then
            log "Release atual: $previous_current"
        fi
    fi

    rollback_on_error() {
        log "Falha detectada no deploy de $project_name"
        log "A release ativa permanece inalterada"
        if [ -d "$release_dir" ]; then
            rm -rf "$release_dir"
            log "Release com falha removida: $release_dir"
        fi
    }

    trap rollback_on_error ERR

    log "Clonando repositório"
    git clone --branch "$branch" --depth 1 "$repo_url" "$release_dir"

    cd "$release_dir"

    local current_branch
    current_branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "$current_branch" = "$branch" ] || fail "Branch clonada inválida. Esperada: $branch | Atual: $current_branch"

    ensure_shared_env_from_example "$shared_dir" "$release_dir"

    log "Configurando links compartilhados"

    rm -rf storage
    ln -s "$shared_dir/storage" storage

    mkdir -p bootstrap
    mkdir -p "$shared_dir/bootstrap/cache"
    rm -rf bootstrap/cache
    ln -s "$shared_dir/bootstrap/cache" bootstrap/cache

    [ -f "$shared_dir/.env" ] || fail "Arquivo .env compartilhado não encontrado"
    ln -s "$shared_dir/.env" .env

    log "Ajustando permissões iniciais"
    chown -R "$APP_USER:$WEB_GROUP" "$release_dir"
    chown -R "$APP_USER:$WEB_GROUP" "$shared_dir/storage" "$shared_dir/bootstrap/cache"
    chown "$APP_USER:$WEB_GROUP" "$shared_dir/.env"
    chmod -R 775 "$shared_dir/storage" "$shared_dir/bootstrap/cache"
    chmod 664 "$shared_dir/.env"

    log "Instalando dependências PHP"
    run_composer_install "$php_bin" "$composer_mode" "$release_dir"

    ensure_app_key "$php_bin" "$shared_dir"

    log "Instalando/buildando frontend, se aplicável"
    detect_node_manager_and_install "$frontend_cmd"

    log "Limpando caches do Laravel"
    "$php_bin" artisan optimize:clear

    if [ "$run_migrate" = "yes" ]; then
        log "Executando migrations"
        "$php_bin" artisan migrate --force
    else
        log "Migrations desabilitadas para este projeto"
    fi

    log "Gerando caches do Laravel"
    "$php_bin" artisan config:cache
    "$php_bin" artisan route:cache || true
    "$php_bin" artisan view:cache || true
    "$php_bin" artisan event:cache || true
    "$php_bin" artisan storage:link || true

    health_check_release "$php_bin" "$healthcheck_artisan"

    log "Trocando symlink current"
    ln -sfn "$release_dir" "$current_link"

    log "Reiniciando filas"
    "$php_bin" artisan queue:restart || true

    log "Ajustando permissões finais"
    chown -R "$APP_USER:$WEB_GROUP" "$release_dir"
    chown -R "$APP_USER:$WEB_GROUP" "$shared_dir/storage" "$shared_dir/bootstrap/cache"
    chmod -R 775 "$shared_dir/storage" "$shared_dir/bootstrap/cache"

    log "Limpando releases antigas"
    cleanup_old_releases "$releases_dir"

    trap - ERR

    log "Deploy concluído com sucesso para $project_name"
    log "Current -> $(readlink -f "$current_link")"
}

# =========================================================
# EXECUÇÃO
# =========================================================
ensure_base_commands

log "Iniciando processo de deploy"

for project_name in "${!PROJECTS[@]}"; do
    deploy_project "$project_name" "${PROJECTS[$project_name]}"
done

log "Deploy finalizado com sucesso"
