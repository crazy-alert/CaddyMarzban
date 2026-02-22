# Marzban + Caddy

## Установка

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/crazy-alert/CaddyMarzban/refs/heads/main/install.sh)"
```

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