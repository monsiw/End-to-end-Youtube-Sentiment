
#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:?Podaj adres obrazu Docker}"
NGINX_CONF="/etc/nginx/conf.d/sentiment.conf"
SWITCH_SCRIPT="/usr/local/sbin/sentiment-switch"

# Blokada równoczesnych wdrożeń.
exec 9>/tmp/sentiment-deploy.lock
flock 9

# Ustal aktualny port Nginx.
if grep -q 'proxy_pass http://127.0.0.1:8081;' "$NGINX_CONF"; then
    ACTIVE_PORT=8081
    ACTIVE_NAME=cnncls-blue
    INACTIVE_PORT=8082
    INACTIVE_NAME=cnncls-green

elif grep -q 'proxy_pass http://127.0.0.1:8082;' "$NGINX_CONF"; then
    ACTIVE_PORT=8082
    ACTIVE_NAME=cnncls-green
    INACTIVE_PORT=8081
    INACTIVE_NAME=cnncls-blue

else
    echo "BŁĄD: nieznana konfiguracja Nginx"
    exit 1
fi

# Funkcje pomocnicze
container_exists() {
    docker container inspect "$1" >/dev/null 2>&1
}

health_check() {
    curl --fail --silent --show-error \
        --max-time 5 \
        "http://127.0.0.1:$1/health" \
        >/dev/null
}

show_logs() {
    echo "Logi kontenera $1:"
    docker logs --tail 100 "$1" 2>&1 || true
}

# Rozróżnij pierwsze wdrożenie od awarii.
if ! container_exists cnncls-blue && \
   ! container_exists cnncls-green; then

    FIRST_DEPLOY=true
    NEW_PORT="$ACTIVE_PORT"
    NEW_NAME="$ACTIVE_NAME"
    OLD_NAME=""

else
    FIRST_DEPLOY=false

    # Aktywny kontener musi istnieć i działać.
    if ! container_exists "$ACTIVE_NAME" || \
       ! health_check "$ACTIVE_PORT"; then
        echo "BŁĄD: aktywna wersja nie działa."
        echo "Przerwano wdrożenie, aby nie utracić rollbacku."
        exit 1
    fi

    NEW_PORT="$INACTIVE_PORT"
    NEW_NAME="$INACTIVE_NAME"
    OLD_NAME="$ACTIVE_NAME"
fi

# Usuń poprzedni nieaktywny kontener.
docker rm -f "$NEW_NAME" 2>/dev/null || true

# Uruchom nową wersję.
echo "Uruchamianie $NEW_NAME na porcie $NEW_PORT"

docker run -d \
    --restart unless-stopped \
    --name "$NEW_NAME" \
    -p "127.0.0.1:${NEW_PORT}:8080" \
    -e AWS_REGION \
    "$IMAGE"

# Poczekaj na gotowość aplikacji.
READY=false

for i in $(seq 1 30); do
    if health_check "$NEW_PORT"; then
        READY=true
        break
    fi
    sleep 2
done

if [ "$READY" != true ]; then
    echo "BŁĄD: nowa wersja nie przeszła health check"
    show_logs "$NEW_NAME"
    docker rm -f "$NEW_NAME" || true
    exit 1
fi

echo "Nowy kontener jest gotowy"

# Pierwsze wdrożenie nie wymaga zmiany portu Nginx,
# ponieważ kontener działa już na skonfigurowanym porcie.
if [ "$FIRST_DEPLOY" = false ]; then

    echo "Przełączanie Nginx na port $NEW_PORT"

    if ! sudo -n "$SWITCH_SCRIPT" "$NEW_PORT"; then
        echo "BŁĄD: przełączenie Nginx nie powiodło się"
        show_logs "$NEW_NAME"

        if sudo -n "$SWITCH_SCRIPT" "$ACTIVE_PORT" && \
           health_check "$ACTIVE_PORT" && \
           health_check 8080; then
            echo "Przywrócono poprzednią wersję"
            docker rm -f "$NEW_NAME" || true
        else
            echo "BŁĄD KRYTYCZNY: nie potwierdzono rollbacku"
            echo "Nowy kontener pozostaje uruchomiony"
        fi

        exit 1
    fi
fi

# Testy po przełączeniu przez Nginx.
echo "Sprawdzanie stabilności aplikacji"

HEALTHY=true

for i in $(seq 1 10); do
    if ! health_check 8080; then
        HEALTHY=false
        echo "Health check $i/10 nie powiódł się"
        break
    fi

    if [ "$i" -lt 10 ]; then
        sleep 3
    fi
done

if [ "$HEALTHY" != true ]; then
    echo "BŁĄD: nowa wersja nie działa poprawnie"
    show_logs "$NEW_NAME"

    if [ "$FIRST_DEPLOY" = false ] && \
       health_check "$ACTIVE_PORT"; then

        echo "Rozpoczynanie rollbacku..."

        if sudo -n "$SWITCH_SCRIPT" "$ACTIVE_PORT" && \
           health_check 8080; then

            echo "Rollback zakończony pomyślnie"
            docker rm -f "$NEW_NAME" || true
        else
            echo "BŁĄD KRYTYCZNY: rollback nie powiódł się"
            echo "Nowy kontener pozostaje uruchomiony"
        fi

    else
        echo "Brak dostępnej poprzedniej wersji"
        echo "Nowy kontener pozostaje do diagnostyki"
    fi

    exit 1
fi

echo "Wdrożenie zakończone pomyślnie"
echo "Nowa wersja: $NEW_NAME, port $NEW_PORT"

if [ "$FIRST_DEPLOY" = false ]; then
    echo "Poprzednia wersja $OLD_NAME pozostaje jako rezerwowa"
else
    echo "Pierwsze wdrożenie zakończone"
fi

echo "Czyszczenie nieużywanych obrazów..."
docker image prune -a -f --filter "until=168h"