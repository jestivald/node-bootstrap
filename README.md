# node-bootstrap

Одна команда — и свежий Ubuntu/Debian VPS превращается в затюненную ноду
для **Remnawave** / **xray** / любого docker-compose стека.

## Что делает

1. `apt update && upgrade` + базовые утилиты (ufw, chrony, jq, htop, iftop, iotop…)
2. **Сетевой тюнинг**: BBR + fq, буферы 64 MB, backlog, TCP Fast Open, SACK, MTU probe
3. **ulimits 1 048 576** (limits.conf + systemd + docker daemon)
4. **Swap 2 GB** если отсутствует, `vm.swappiness=10`
5. **journald** ограничен 200 MB
6. **Docker CE + Compose v2** + `daemon.json` (log rotation, live-restore, ulimits)
7. **UFW**: deny incoming, allow `22`, `443/tcp`, `443/udp`, `2222/tcp`
8. Просит вставить `docker-compose.yml` прямо в терминал → `docker compose up -d`

## Быстрый старт

На свежем сервере под `root`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jestivald/node-bootstrap/main/node-bootstrap.sh)
```

Скрипт спросит подтверждение, прогонит все шаги, а в конце попросит:

```
Paste your full docker-compose.yml below.
When done, press Ctrl-D on an empty line to finish.
(or type a single line with   __END__   to finish)
```

Вставляешь содержимое compose-файла → **Ctrl-D** (или строка `__END__`) → готово.

Если нужен `.env` (например `SECRET_KEY` для Remnawave node) — скрипт отдельно
предложит вставить и его.

## Пример для Remnawave Node

После того как скрипт предложит вставить compose, вставляешь:

```yaml
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    restart: always
    network_mode: host
    env_file:
      - .env
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
```

Затем в `.env`:

```env
NODE_PORT=2222
SECRET_KEY="eyJub2RlQ2VydFBlbSI6..."
```

После этого на панели добавляешь ноду по `IP_СЕРВЕРА:2222`.

## Флаги

| Флаг | Что делает |
|---|---|
| `-y`, `--yes` | Не спрашивать подтверждение |
| `--compose-file=PATH` | Взять готовый compose, не запрашивать paste |
| `--env-file=PATH` | Взять готовый .env |
| `--dir=PATH` | Куда класть стек (по умолчанию `/opt/node`) |
| `--extra-ports="80,8443,51820/udp"` | Доп. порты в UFW |
| `--no-swap` | Не создавать swap |
| `--no-ufw` | Не трогать firewall |
| `--no-docker` | Не ставить Docker |
| `--no-compose` | Не деплоить compose |

Пример полностью неинтерактивного запуска:

```bash
curl -fsSLO https://raw.githubusercontent.com/jestivald/node-bootstrap/main/node-bootstrap.sh
chmod +x node-bootstrap.sh
./node-bootstrap.sh -y \
    --compose-file=/tmp/docker-compose.yml \
    --env-file=/tmp/.env \
    --dir=/opt/remnanode \
    --extra-ports="80/tcp"
```

## Требования

- Ubuntu 22.04 / 24.04 или Debian 11 / 12
- root (или `sudo -i`)
- Исходящий интернет (для apt и `get.docker.com`)

## Безопасность

- Скрипт **не трогает SSH-порт** и **не отключает пароль** — делать это решай сам.
- UFW сбрасывается через `ufw --force reset` перед накаткой правил. Если у тебя
  уже настроены кастомные правила — используй `--no-ufw` и правь руками.
- `.env` сохраняется с `chmod 600`.

## Идемпотентность

Повторный запуск безопасен:

- Docker не переустанавливается, если уже стоит
- Swap не создаётся, если уже есть
- compose просто перезапишется и перезапустится (`up -d`)

## Лицензия

MIT
