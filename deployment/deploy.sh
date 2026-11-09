#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:?Podaj adres obrazu Docker}"
NGINX_CONF="/etc/nginx/conf.d/sentiment.conf"

# Nie dopuszczaj do dwóch równoczesnych wdrożeń.
exec 9>/tmp/sentiment-deploy.lock
flock 9

# Sprawdź aktualny port Nginx.
if sudo grep -q 'proxy_pass http://127.0.0.1:8081;' "$NGINX_CONF"; then
    ACTIVE_PORT=8081
    ACTIVE_NAME=cnncls-blue
    INACTIVE_PORT=8082
    INACTIVE_NAME=cnncls-green

elif sudo grep -q 'proxy_pass http://127.0.0.1:8082;' "$NGINX_CONF"; then
    ACTIVE_PORT=8082
    ACTIVE_NAME=cnncls-green
    INACTIVE_PORT=8081
    INACTIVE_NAME=cnncls-blue

else
    echo "Nieznana konfiguracja Nginx"
    exit 1
fi

# Pierwsze wdrożenie: żaden kontener Blue/Green nie istnieje.
if ! docker ps -a --format '{{.Names}}' | grep -qx 'cnncls-blue' && \
   ! docker ps -a --format '{{.Names}}' | grep -qx 'cnncls-green'; then

    NEW_PORT="$ACTIVE_PORT"
    NEW_NAME="$ACTIVE_NAME"
    OLD_NAME=""

else
    NEW_PORT="$INACTIVE_PORT"
    NEW_NAME="$INACTIVE_NAME"
    OLD_NAME="$ACTIVE_NAME"
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

    echo "Odpowiedź HTTP:"
    curl -i --max-time 10 \
        "http://127.0.0.1:${NEW_PORT}/health" || true

    echo "Zarejestrowane endpointy Flask:"
    docker exec "$NEW_NAME" python -c \
        "from app import app; print(app.url_map)" || true

    echo "Logi kontenera:"
    docker logs --tail 100 "$NEW_NAME" || true

    docker rm -f "$NEW_NAME" || true
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
    echo "Nie udało się przełączyć Nginx"

    sudo cp "${NGINX_CONF}.bak" "$NGINX_CONF"
    sudo nginx -t
    sudo systemctl reload nginx

    docker rm -f "$NEW_NAME" || true
    exit 1
fi

echo "Nowa wersja działa na porcie ${NEW_PORT}"
echo "Nowa wersja działa na porcie ${NEW_PORT}"

if [ -n "$OLD_NAME" ]; then
    echo "Poprzedni kontener ${OLD_NAME} pozostaje jako rezerwowy"
else
    echo "Pierwsze wdrożenie zakończone"
fi