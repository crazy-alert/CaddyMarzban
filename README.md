# Marzban + Caddy
Основано на https://github.com/Gozargah/Marzban и https://github.com/caddyserver/caddy
## Установка

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/crazy-alert/CaddyMarzban/refs/heads/main/install.sh)"
```

Для добавления адммина войдите в контейнер:
```docker exec -it XXXXX sh```
Вбейте команду:
```marzban-cli admin create```
И следуйте указаниям

## Marzban и Xray-core обновляются довольно часто. Для обновления всей связки в Docker достаточно выполнить:
```bash
docker compose pull
docker compose up -d --remove-orphans
```

## Если внесены изменеия в Caddyfile

_перед выполнением reload используйте команду валидации:_
```bash
docker exec -it caddy caddy validate --config /etc/caddy/Caddyfile
```
_сам reload:_
```bash
docker-compose exec -w /etc/caddy caddy caddy reload
```
```bash
docker-compose restart caddy
````

Глянуть логи: 
```bash
docker-compose logs --tail=50
```
Или:
```bash
docker-compose logs --tail=50 caddy
```

```bash
docker-compose logs --tail=50 marzban
```

_Обновление:_
```bash
docker-compose down
git stash
git pull
docker-compose up -d

```