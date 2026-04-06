#!/bin/bash
set -Eeuo pipefail

# =========================================================
# CONFIGURACAO
# =========================================================
# FORMATO:
# PROJECTS["nome"]="repo|branch|php_bin|frontend_cmd|composer_mode|run_migrate|healthcheck_artisan"
#
# composer_mode: prod | dev
# run_migrate: yes | no
# frontend_cmd: build | dev | none
# healthcheck_artisan: ex: "about" ou "route:list"

declare -A PROJECTS
PROJECTS["atomic_deploy_example_laravel_13"]="git@github.com:DuilioFanton/atomic-deploy-project-example-laravel-13.git|master|/usr/bin/php|build|prod|yes|about"
# PROJECTS["project_1"]="git@github.com:org/project_1.git|main|/usr/bin/php8.4|build|prod|yes|about"
# PROJECTS["project_2"]="git@github.com:org/project_2.git|main|/usr/bin/php8.3|none|prod|no|route:list"

BASE_ROOT="${BASE_ROOT:-/var/www}"
APP_USER="${APP_USER:-www-data}"
WEB_GROUP="${WEB_GROUP:-www-data}"
# Usuario utilizado para git clone e build frontend (por padrao: usuario que executa o script)
DEPLOY_USER="${DEPLOY_USER:-$(id -un)}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
LOCK_FILE="${LOCK_FILE:-/tmp/atomic_deploy.lock}"
AUTO_GENERATE_APP_KEY="${AUTO_GENERATE_APP_KEY:-no}"

# =========================================================
# LOCK DE EXECUCAO
# =========================================================
exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo "Outro deploy ja esta em execucao."
    exit 1
}

# =========================================================
# FUNCOES AUXILIARES
# =========================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

fail() {
    log "ERRO: $1"
    return 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Comando obrigatorio nao encontrado: $1"
}

run_as_root() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_as_user() {
    local target_user="$1"
    shift

    if [ "$(id -un)" = "$target_user" ]; then
        "$@"
    elif [ "$EUID" -eq 0 ]; then
        if command -v runuser >/dev/null 2>&1; then
            runuser -u "$target_user" -- "$@"
        elif command -v sudo >/dev/null 2>&1; then
            sudo -u "$target_user" "$@"
        else
            fail "Nao foi possivel trocar para o usuario '$target_user' sem runuser/sudo"
        fi
    else
        sudo -u "$target_user" "$@"
    fi
}

run_as_app_user() {
    run_as_user "$APP_USER" "$@"
}

run_as_deploy_user() {
    run_as_user "$DEPLOY_USER" "$@"
}

run_artisan() {
    local php_bin="$1"
    local release_dir="$2"
    shift 2

    run_as_app_user "$php_bin" "$release_dir/artisan" "$@"
}

validate_php_bin() {
    local php_bin="$1"
    [ -x "$php_bin" ] || fail "Binario PHP invalido ou inexistente: $php_bin"
}

validate_project_name() {
    local project_name="$1"

    [[ "$project_name" =~ ^[a-zA-Z0-9._-]+$ ]] || fail "Nome de projeto invalido: $project_name"
}

validate_project_config() {
    local project_name="$1"
    local config="$2"
    local -a parts=()

    IFS="|" read -r -a parts <<< "$config"

    [ "${#parts[@]}" -eq 7 ] || fail "Config invalida para '$project_name'. Esperado: repo|branch|php_bin|frontend_cmd|composer_mode|run_migrate|healthcheck_artisan"

    local repo_url="${parts[0]}"
    local branch="${parts[1]}"
    local php_bin="${parts[2]}"
    local frontend_cmd="${parts[3]}"
    local composer_mode="${parts[4]}"
    local run_migrate="${parts[5]}"
    local healthcheck_artisan="${parts[6]}"

    [ -n "$repo_url" ] || fail "repo_url vazio para '$project_name'"
    [ -n "$branch" ] || fail "branch vazia para '$project_name'"
    [ -n "$php_bin" ] || fail "php_bin vazio para '$project_name'"
    [[ "$php_bin" = /* ]] || fail "php_bin deve ser caminho absoluto para '$project_name'"

    case "$frontend_cmd" in
        none|build|dev)
            ;;
        "")
            fail "frontend_cmd vazio para '$project_name'"
            ;;
        *)
            if [[ "$frontend_cmd" =~ [[:space:]] ]]; then
                fail "frontend_cmd nao deve conter espacos para '$project_name'"
            fi
            ;;
    esac

    case "$composer_mode" in
        prod|dev)
            ;;
        *)
            fail "composer_mode invalido para '$project_name': $composer_mode (use prod ou dev)"
            ;;
    esac

    case "$run_migrate" in
        yes|no)
            ;;
        *)
            fail "run_migrate invalido para '$project_name': $run_migrate (use yes ou no)"
            ;;
    esac

    [ -n "$healthcheck_artisan" ] || fail "healthcheck_artisan vazio para '$project_name'"
    if [[ "$healthcheck_artisan" =~ [[:space:]] ]]; then
        fail "healthcheck_artisan nao deve conter espacos para '$project_name'"
    fi
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
    require_command sort
    require_command id
    require_command getent
    require_command dirname
    require_command touch

    if [ "$EUID" -ne 0 ]; then
        require_command sudo
    fi

    if [ "$EUID" -eq 0 ] && { [ "$(id -un)" != "$APP_USER" ] || [ "$(id -un)" != "$DEPLOY_USER" ]; }; then
        if ! command -v runuser >/dev/null 2>&1 && ! command -v sudo >/dev/null 2>&1; then
            fail "Execute como $APP_USER/$DEPLOY_USER ou instale runuser/sudo"
        fi
    fi

    id -u "$APP_USER" >/dev/null 2>&1 || fail "Usuario APP_USER nao encontrado: $APP_USER"
    id -u "$DEPLOY_USER" >/dev/null 2>&1 || fail "Usuario DEPLOY_USER nao encontrado: $DEPLOY_USER"
    getent group "$WEB_GROUP" >/dev/null 2>&1 || fail "Grupo WEB_GROUP nao encontrado: $WEB_GROUP"

    [[ "$KEEP_RELEASES" =~ ^[1-9][0-9]*$ ]] || fail "KEEP_RELEASES deve ser inteiro positivo"

    case "$AUTO_GENERATE_APP_KEY" in
        yes|no)
            ;;
        *)
            fail "AUTO_GENERATE_APP_KEY invalido: $AUTO_GENERATE_APP_KEY (use yes ou no)"
            ;;
    esac
}

ensure_project_structure() {
    local project_name="$1"
    local base_dir="$BASE_ROOT/$project_name"
    local releases_dir="$base_dir/releases"
    local shared_dir="$base_dir/shared"

    log "Garantindo estrutura base do projeto: $project_name"

    run_as_root mkdir -p "$releases_dir"
    run_as_root mkdir -p "$shared_dir/storage"
    run_as_root mkdir -p "$shared_dir/bootstrap/cache"

    run_as_root mkdir -p "$shared_dir/storage/app"
    run_as_root mkdir -p "$shared_dir/storage/framework/cache"
    run_as_root mkdir -p "$shared_dir/storage/framework/sessions"
    run_as_root mkdir -p "$shared_dir/storage/framework/views"
    run_as_root mkdir -p "$shared_dir/storage/logs"

    run_as_root chown "$APP_USER:$WEB_GROUP" "$base_dir" "$shared_dir"
    run_as_root chown "$DEPLOY_USER:$WEB_GROUP" "$releases_dir"
    run_as_root chmod 2775 "$base_dir" "$releases_dir" "$shared_dir"

    run_as_root chown -R "$APP_USER:$WEB_GROUP" "$shared_dir/storage" "$shared_dir/bootstrap/cache"
    run_as_root chmod -R 775 "$shared_dir/storage" "$shared_dir/bootstrap/cache"
}

cleanup_old_releases() {
    local releases_dir="$1"
    local current_link="$2"
    local current_target=""
    local release_path
    local -a releases=()
    local -a sorted_releases=()
    local index

    if [ -L "$current_link" ] || [ -e "$current_link" ]; then
        current_target="$(readlink -f "$current_link" || true)"
    fi

    shopt -s nullglob
    for release_path in "$releases_dir"/*; do
        [ -d "$release_path" ] || continue
        releases+=("$release_path")
    done
    shopt -u nullglob

    [ "${#releases[@]}" -le "$KEEP_RELEASES" ] && return 0

    mapfile -t sorted_releases < <(printf '%s\n' "${releases[@]}" | sort -r)

    for ((index = KEEP_RELEASES; index < ${#sorted_releases[@]}; index++)); do
        if [ -n "$current_target" ] && [ "${sorted_releases[$index]}" = "$current_target" ]; then
            continue
        fi
        run_as_root rm -rf "${sorted_releases[$index]}"
    done
}

check_repo_access() {
    local repo_url="$1"

    run_as_deploy_user git ls-remote "$repo_url" >/dev/null 2>&1 || fail "Nao foi possivel acessar o repositorio: $repo_url"
}

detect_node_manager_and_install() {
    local release_dir="$1"
    local frontend_cmd="$2"

    if [ ! -f "$release_dir/package.json" ]; then
        log "Projeto sem package.json, pulando etapa Node"
        return 0
    fi

    if [ -f "$release_dir/yarn.lock" ]; then
        require_command yarn
        log "Instalando dependencias Node com Yarn"
        run_as_deploy_user yarn --cwd "$release_dir" install --frozen-lockfile

        if [ "$frontend_cmd" != "none" ]; then
            log "Executando build front: yarn run $frontend_cmd"
            run_as_deploy_user yarn --cwd "$release_dir" run "$frontend_cmd"
        fi
        return 0
    fi

    if [ -f "$release_dir/pnpm-lock.yaml" ]; then
        require_command pnpm
        log "Instalando dependencias Node com pnpm"
        run_as_deploy_user pnpm --dir "$release_dir" install --frozen-lockfile

        if [ "$frontend_cmd" != "none" ]; then
            log "Executando build front: pnpm run $frontend_cmd"
            run_as_deploy_user pnpm --dir "$release_dir" run "$frontend_cmd"
        fi
        return 0
    fi

    if [ -f "$release_dir/package-lock.json" ]; then
        require_command npm
        log "Instalando dependencias Node com npm"
        run_as_deploy_user npm --prefix "$release_dir" ci

        if [ "$frontend_cmd" != "none" ]; then
            log "Executando build front: npm run $frontend_cmd"
            run_as_deploy_user npm --prefix "$release_dir" run "$frontend_cmd"
        fi
        return 0
    fi

    fail "package.json encontrado, mas nenhum lockfile foi encontrado. Abortando por seguranca."
}

run_composer_install() {
    local php_bin="$1"
    local composer_mode="$2"
    local release_dir="$3"
    local composer_bin

    composer_bin="$(command -v composer)" || fail "Composer nao encontrado"

    if [ "$composer_mode" = "prod" ]; then
        run_as_app_user "$php_bin" "$composer_bin" install \
            --working-dir="$release_dir" \
            --no-dev \
            --prefer-dist \
            --optimize-autoloader \
            --no-interaction \
            --no-progress
    else
        run_as_app_user "$php_bin" "$composer_bin" install \
            --working-dir="$release_dir" \
            --prefer-dist \
            --no-interaction \
            --no-progress
    fi
}

health_check_release() {
    local php_bin="$1"
    local release_dir="$2"
    local artisan_cmd="$3"

    log "Executando health check basico: php artisan $artisan_cmd"
    run_artisan "$php_bin" "$release_dir" "$artisan_cmd" >/dev/null 2>&1 || fail "Health check falhou na release"
}

ensure_shared_env_from_example() {
    local shared_dir="$1"
    local release_dir="$2"

    if [ ! -f "$shared_dir/.env" ]; then
        log "Criando .env compartilhado a partir do .env.example"

        if [ -f "$release_dir/.env.example" ]; then
            run_as_root cp "$release_dir/.env.example" "$shared_dir/.env"
            run_as_root chown "$APP_USER:$WEB_GROUP" "$shared_dir/.env"
            run_as_root chmod 640 "$shared_dir/.env"

            log "Arquivo criado: $shared_dir/.env"
            log "ATENCAO: revise as variaveis de ambiente antes de usar em producao"
        else
            fail ".env.example nao encontrado no repositorio"
        fi
    fi
}

ensure_app_key() {
    local php_bin="$1"
    local release_dir="$2"
    local shared_dir="$3"

    if grep -Eq '^APP_KEY=.+$' "$shared_dir/.env"; then
        return 0
    fi

    if [ "$AUTO_GENERATE_APP_KEY" = "yes" ]; then
        log "APP_KEY ausente. Gerando automaticamente (AUTO_GENERATE_APP_KEY=yes)..."
        run_artisan "$php_bin" "$release_dir" key:generate --force
        return 0
    fi

    fail "APP_KEY ausente em $shared_dir/.env. Defina manualmente ou use AUTO_GENERATE_APP_KEY=yes"
}

read_env_value() {
    local env_file="$1"
    local key="$2"
    local line
    local value

    [ -f "$env_file" ] || return 1

    while IFS= read -r line; do
        case "$line" in
            ''|'#'*)
                continue
                ;;
            "$key"=*)
                value="${line#*=}"
                value="${value%\"}"
                value="${value#\"}"
                value="${value%\'}"
                value="${value#\'}"
                printf '%s' "$value"
                return 0
                ;;
        esac
    done < "$env_file"

    return 1
}

ensure_sqlite_database_if_needed() {
    local release_dir="$1"
    local env_file="$release_dir/.env"
    local db_connection=""
    local db_database=""
    local db_path=""
    local db_dir=""

    db_connection="$(read_env_value "$env_file" "DB_CONNECTION" || true)"
    [ "$db_connection" = "sqlite" ] || return 0

    db_database="$(read_env_value "$env_file" "DB_DATABASE" || true)"
    if [ -z "$db_database" ] || [ "$db_database" = "null" ]; then
        db_database="database/database.sqlite"
    fi

    if [[ "$db_database" = /* ]]; then
        db_path="$db_database"
    else
        db_path="$release_dir/$db_database"
    fi

    db_dir="$(dirname "$db_path")"
    run_as_app_user mkdir -p "$db_dir"
    if [ ! -f "$db_path" ]; then
        run_as_app_user touch "$db_path"
        log "Arquivo SQLite criado para ambiente sqlite: $db_path"
    fi
}

deploy_project() {
    local project_name="$1"
    local config="$2"
    local repo_url
    local branch
    local php_bin
    local frontend_cmd
    local composer_mode
    local run_migrate
    local healthcheck_artisan

    validate_project_name "$project_name"
    validate_project_config "$project_name" "$config"

    IFS="|" read -r repo_url branch php_bin frontend_cmd composer_mode run_migrate healthcheck_artisan <<< "$config"

    local base_dir="$BASE_ROOT/$project_name"
    local releases_dir="$base_dir/releases"
    local shared_dir="$base_dir/shared"
    local current_link="$base_dir/current"
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local release_dir="$releases_dir/$timestamp"
    local previous_current=""
    local current_switched="no"

    log "========================================================="
    log "Iniciando deploy do projeto: $project_name"
    log "Repositorio: $repo_url"
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
        local rollback_error=0

        trap - ERR
        log "Falha detectada no deploy de $project_name"

        if [ "$current_switched" = "yes" ]; then
            if [ -n "$previous_current" ] && [ -d "$previous_current" ]; then
                run_as_root ln -sfn "$previous_current" "$current_link" || rollback_error=1
                log "Symlink current restaurado para: $previous_current"
            else
                run_as_root rm -f "$current_link" || rollback_error=1
                log "Symlink current removido (nao havia release anterior)"
            fi
        fi

        if [ -d "$release_dir" ]; then
            run_as_root rm -rf "$release_dir" || rollback_error=1
            log "Release com falha removida: $release_dir"
        fi

        if [ "$rollback_error" -ne 0 ]; then
            log "ATENCAO: rollback parcial. Verifique manualmente: $current_link"
        else
            log "Rollback concluido com sucesso"
        fi
    }

    trap rollback_on_error ERR

    log "Clonando repositorio"
    run_as_deploy_user git clone --branch "$branch" --single-branch --depth 1 "$repo_url" "$release_dir"

    local current_branch
    current_branch="$(run_as_deploy_user git -C "$release_dir" rev-parse --abbrev-ref HEAD)"
    [ "$current_branch" = "$branch" ] || fail "Branch clonada invalida. Esperada: $branch | Atual: $current_branch"

    ensure_shared_env_from_example "$shared_dir" "$release_dir"

    log "Configurando links compartilhados"
    run_as_deploy_user rm -rf "$release_dir/storage"
    run_as_deploy_user ln -s "$shared_dir/storage" "$release_dir/storage"

    run_as_deploy_user mkdir -p "$release_dir/bootstrap"
    run_as_deploy_user rm -rf "$release_dir/bootstrap/cache"
    run_as_deploy_user ln -s "$shared_dir/bootstrap/cache" "$release_dir/bootstrap/cache"

    [ -f "$shared_dir/.env" ] || fail "Arquivo .env compartilhado nao encontrado"

    if [ -e "$release_dir/.env" ] || [ -L "$release_dir/.env" ]; then
        run_as_deploy_user rm -rf "$release_dir/.env"
    fi
    run_as_deploy_user ln -s "$shared_dir/.env" "$release_dir/.env"

    log "Ajustando permissoes iniciais"
    run_as_root chown -R "$APP_USER:$WEB_GROUP" "$shared_dir/storage" "$shared_dir/bootstrap/cache"
    run_as_root chown "$APP_USER:$WEB_GROUP" "$shared_dir/.env"
    run_as_root chmod -R 775 "$shared_dir/storage" "$shared_dir/bootstrap/cache"
    run_as_root chmod 640 "$shared_dir/.env"

    log "Instalando/buildando frontend, se aplicavel"
    detect_node_manager_and_install "$release_dir" "$frontend_cmd"

    run_as_root chown -R "$APP_USER:$WEB_GROUP" "$release_dir"

    log "Instalando dependencias PHP"
    run_composer_install "$php_bin" "$composer_mode" "$release_dir"

    ensure_app_key "$php_bin" "$release_dir" "$shared_dir"
    ensure_sqlite_database_if_needed "$release_dir"

    if [ "$run_migrate" = "yes" ]; then
        log "Executando migrations"
        run_artisan "$php_bin" "$release_dir" migrate --force
    else
        log "Migrations desabilitadas para este projeto"
    fi

    log "Limpando caches do Laravel"
    run_artisan "$php_bin" "$release_dir" optimize:clear

    log "Gerando caches do Laravel"
    run_artisan "$php_bin" "$release_dir" config:cache
    run_artisan "$php_bin" "$release_dir" route:cache || true
    run_artisan "$php_bin" "$release_dir" view:cache || true
    run_artisan "$php_bin" "$release_dir" event:cache || true
    run_artisan "$php_bin" "$release_dir" storage:link || true

    health_check_release "$php_bin" "$release_dir" "$healthcheck_artisan"

    log "Trocando symlink current"
    run_as_root ln -sfn "$release_dir" "$current_link"
    current_switched="yes"

    log "Reiniciando filas"
    run_artisan "$php_bin" "$release_dir" queue:restart || true

    log "Ajustando permissoes finais"
    run_as_root chown -R "$APP_USER:$WEB_GROUP" "$shared_dir/storage" "$shared_dir/bootstrap/cache"
    run_as_root chmod -R 775 "$shared_dir/storage" "$shared_dir/bootstrap/cache"

    log "Limpando releases antigas"
    cleanup_old_releases "$releases_dir" "$current_link"

    trap - ERR

    log "Deploy concluido com sucesso para $project_name"
    log "Current -> $(readlink -f "$current_link")"
}

# =========================================================
# EXECUCAO
# =========================================================
ensure_base_commands

[ "${#PROJECTS[@]}" -gt 0 ] || fail "Nenhum projeto configurado no array PROJECTS"

log "Iniciando processo de deploy"

for project_name in "${!PROJECTS[@]}"; do
    deploy_project "$project_name" "${PROJECTS[$project_name]}"
done

log "Deploy finalizado com sucesso"
