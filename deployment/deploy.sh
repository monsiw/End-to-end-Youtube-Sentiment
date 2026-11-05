#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:?Podaj adres obrazu Docker}"
NGINX_CONF="/etc/nginx/conf.d/sentiment.conf"

# Nie dopuszczaj do dwóch równoczesnych wdrożeń.
exec 9>/tmp/sentiment-deploy.lock
flock 9

# Ustal, na który port Nginx kieruje ruch.
if sudo grep -q 'proxy_pass http://127.0.0.1:8081;' "$NGINX_CONF"; then
    NEW_PORT=8082
    NEW_NAME=cnncls-green
    OLD_NAME=cnncls-blue
elif sudo grep -q 'proxy_pass http://127.0.0.1:8082;' "$NGINX_CONF"; then
    NEW_PORT=8081
    NEW_NAME=cnncls-blue
    OLD_NAME=cnncls-green
else
    echo "Nieznana konfiguracja Nginx"
    exit 1
fi

# Usuń nieaktywny kontener z poprzedniego wdrożenia.
docker rm -f "$NEW_NAME" 2>/dev/null || true

# Uruchom nowy kontener.
docker run -d \
    --restart unless-stopped \
    --name "$NEW_NAME" \
    -p "127.0.0.1:${NEW_PORT}:8080" \
    -e AWS_REGION \
    "$IMAGE"

# Sprawdź gotowość aplikacji.
READY=false

for i in $(seq 1 30); do
    if curl --fail --silent \
        "http://127.0.0.1:${NEW_PORT}/health" \
        >/dev/null; then
        READY=true
        break
    fi

    sleep 2
done

if [ "$READY" != true ]; then
    echo "Nowa wersja nie przeszła health check"
    docker logs --tail 50 "$NEW_NAME"
    docker rm -f "$NEW_NAME"
    exit 1
fi

# Zachowaj poprzednią konfigurację.
sudo cp "$NGINX_CONF" "${NGINX_CONF}.bak"

# Przełącz ruch na nowy kontener.
sudo sed -i \
    -E "s@proxy_pass http://127\.0\.0\.1:808[12];@proxy_pass http://127.0.0.1:${NEW_PORT};@" \
    "$NGINX_CONF"

# Sprawdź konfigurację przed przeładowaniem.
if ! sudo nginx -t || ! sudo systemctl reload nginx; then
    sudo cp "${NGINX_CONF}.bak" "$NGINX_CONF"
    sudo nginx -t
    sudo systemctl reload nginx
    echo "Nie udało się przełączyć Nginx"
    exit 1
fi

echo "Nowa wersja działa na porcie ${NEW_PORT}"
echo "Poprzedni kontener ${OLD_NAME} pozostaje jako rezerwowy"