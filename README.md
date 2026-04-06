# 🚀 Atomic Laravel Deploy Script (Multi-PHP, Zero Downtime)

Deploy automatizado, seguro e **idempotente** para aplicações Laravel com suporte a **multi-versões de PHP**, **rollback automático** e **zero downtime**.

> Feito para ambientes reais. Sem gambiarra. Sem downtime. Sem dor de cabeça.

---

## ✨ Features

* ⚡ Deploy atômico com symlink (`current`)
* 🔁 Rollback automático em caso de erro
* 🧠 Suporte a múltiplas versões de PHP por projeto
* 📦 Composer isolado por versão de PHP
* 🧵 Lock de execução (evita deploy simultâneo)
* 🗂 Estrutura padrão (`releases`, `shared`)
* 🔐 Permissões ajustadas automaticamente
* 🧪 Healthcheck pós-deploy
* 🔄 Migrações automáticas (opcional)
* 🧹 Limpeza de releases antigas
* 🎯 Compatível com:

  * npm / yarn / pnpm
* 🔧 Sem dependência de `update-alternatives` (sem risco global)

---

## 📁 Estrutura de Diretórios

```
/var/www/
  └── projeto/
      ├── current -> releases/20260405_120240
      ├── releases/
      │    ├── 20260405_120240/
      │    ├── 20260404_101010/
      │    └── ...
      └── shared/
           ├── .env
           ├── storage/
           └── bootstrap/cache/
```

---

## ⚙️ Configuração

No topo do script:

```bash
declare -A PROJECTS

PROJECTS["project"]="repo|branch|php_bin|frontend_cmd|composer_mode|run_migrate|healthcheck"
PROJECTS["atomic_deploy_example_laravel_13"]="git@github.com:DuilioFanton/atomic-deploy-project-example-laravel-13.git|master|/usr/bin/php|build|prod|yes|about"
```

E ajuste também as variáveis globais do script:

* `BASE_ROOT` (default `/var/www`)
* `APP_USER` / `WEB_GROUP` para o usuário de runtime do Laravel
* `DEPLOY_USER` para o usuário de clone/build (default: usuário atual)
* `KEEP_RELEASES` e `LOCK_FILE`
* `AUTO_GENERATE_APP_KEY` (`yes` ou `no`, default `no`)

---

## 🧩 Parâmetros explicados

| Campo         | Descrição                            |
| ------------- | ------------------------------------ |
| repo          | URL do repositório                   |
| branch        | Branch de deploy                     |
| php_bin       | Caminho absoluto do PHP              |
| frontend_cmd  | Comando (ex: `build`, `dev`, `none`) |
| composer_mode | `prod` ou `dev`                      |
| run_migrate   | `yes` ou `no`                        |
| healthcheck   | Comando artisan                      |

---

## 🚀 Como usar

```bash
chmod +x atomicDeploy.sh
./atomicDeploy.sh
```

---

## 🔥 Filosofia do Script

### ❌ NÃO usamos:

* `update-alternatives`
* PHP global mutável
* hacks com PATH
* downtime

### ✅ USAMOS:

* PHP explícito por projeto:

```bash
"$php_bin" artisan ...
"$php_bin" composer ...
```

👉 Cada projeto roda com sua própria versão de PHP — sem conflito.

---

## 🧠 Por que isso importa?

Em ambientes reais:

* Projeto A → PHP 7.4
* Projeto B → PHP 8.2
* Projeto C → PHP 8.5

Se você usar PHP global:
💥 quebra tudo

Esse script resolve isso **de forma limpa e previsível**.

---

## 📦 Composer (IMPORTANTE)

O script força o Composer a rodar com o PHP correto:

```bash
"$php_bin" "$(command -v composer)" install
```

👉 Isso evita:

* erro de platform
* dependências incompatíveis
* bugs invisíveis em produção

---

## 🔐 Segurança

* `set -Eeuo pipefail`
* lock com `flock`
* validação de comandos
* validação de binário PHP
* validação de branch
* validação estrita de configuração por projeto
* `APP_KEY` não é gerada automaticamente por padrão (fail fast)
* rollback automático

---

## 🔄 Deploy Flow

1. Lock de execução
2. Validação de ambiente
3. Clone do repo
4. Link de arquivos compartilhados
5. Composer install (PHP correto)
6. Build frontend (se existir)
7. Cache clear + rebuild
8. Migrate (opcional)
9. Health check
10. Switch de symlink (`current`)
11. Restart queue
12. Cleanup releases antigas

---

## 💥 Rollback automático

Se qualquer etapa falhar:

* release é descartada
* versão anterior continua ativa
* zero impacto para usuários

---

## 🧪 Healthcheck

Configuração:

```bash
about
route:list
config:cache
```

Executado automaticamente:

```bash
php artisan <healthcheck>
```

Se falhar → deploy abortado

---

## 🧵 Lock de Deploy

Evita deploy simultâneo:

```bash
/tmp/atomic_deploy.lock
```

---

## 🧹 Cleanup automático

Mantém apenas:

```bash
KEEP_RELEASES=5
```

---

## ⚠️ Requisitos

* PHP (múltiplas versões suportadas)
* Composer
* Git
* Node (opcional)
* Yarn / pnpm / npm
* Permissões sudo (para setup inicial)

---

## 💡 Boas práticas

* Use SSH keys para Git
* Configure `.env` corretamente no `shared`
* Nunca versionar `.env`
* Use filas com supervisor
* Use opcache em produção

---

## 🧠 Dicas avançadas

### Multi-servidor

Combine com:

* rsync
* load balancer
* deploy rolling

---

### Zero downtime real

Se quiser elevar nível:

* usar queue worker draining
* healthcheck HTTP
* deploy blue/green

---

## ❤️ Filosofia

> Deploy não é sobre rodar comando.
> É sobre garantir consistência, previsibilidade e segurança.

Esse script foi feito com isso em mente.

---

## 🤝 Contribuindo

PRs são bem-vindos.

Ideias:

* suporte a Docker
* integração com CI/CD
* notificação Slack/Discord
* healthcheck HTTP

---

## 📜 Licença

MIT

---

## 🧠 Autor

Feito por quem já sofreu com deploy quebrando produção 😄
