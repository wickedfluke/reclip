#!/bin/bash
# Avvia ReClip + un Cloudflare Quick Tunnel con un solo comando.
# Pensato per Termux, ma funziona su qualunque Linux con bash.
#
# Setup una tantum su Termux:
#   pkg update && pkg install python ffmpeg yt-dlp cloudflared
#   (facoltativo, evita che Android sospenda Termux a schermo spento)
#   pkg install termux-api
#
# Poi, ad ogni avvio:
#   ./termux-start.sh
set -e
cd "$(dirname "$0")"

PORT="${PORT:-8899}"
export PORT
export HOST="${HOST:-127.0.0.1}"

if ! command -v cloudflared &> /dev/null; then
    echo "cloudflared non trovato."
    echo "Installalo con:  pkg install cloudflared"
    echo "(se il pacchetto non è disponibile: pkg install tur-repo && pkg install cloudflared)"
    exit 1
fi

RECLIP_PID=""
TUNNEL_PID=""
WATCH_PID=""

CLEANED_UP=0
cleanup() {
    [ "$CLEANED_UP" = 1 ] && return
    CLEANED_UP=1
    echo ""
    echo "Arresto in corso..."
    [ -n "$RECLIP_PID" ] && kill "$RECLIP_PID" 2>/dev/null
    [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
    command -v termux-wake-unlock &> /dev/null && termux-wake-unlock
}
trap cleanup EXIT INT TERM

if command -v termux-wake-lock &> /dev/null; then
    termux-wake-lock
    echo "Wake lock attivo: il telefono non sospenderà Termux a schermo spento."
else
    echo "Suggerimento: installa 'termux-api' (pkg install termux-api) e l'app Termux:API,"
    echo "poi rilancia questo script per attivare automaticamente il wake lock e mantenere"
    echo "il tunnel attivo anche a schermo spento."
fi

echo "Avvio di ReClip sulla porta $PORT..."
./reclip.sh > reclip.log 2>&1 &
RECLIP_PID=$!

echo "Attendo che ReClip sia pronto (la prima volta può richiedere un po', mentre aggiorna yt-dlp)..."
READY=0
for _ in $(seq 1 60); do
    if ! kill -0 "$RECLIP_PID" 2>/dev/null; then
        break
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
        exec 3>&- 2>/dev/null
        READY=1
        break
    fi
    sleep 1
done

if [ "$READY" != 1 ]; then
    echo ""
    echo "ReClip non è partito in tempo. Ultime righe di reclip.log:"
    tail -n 20 reclip.log 2>/dev/null
    exit 1
fi

echo "Avvio del tunnel Cloudflare..."
cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate > cloudflared.log 2>&1 &
TUNNEL_PID=$!

(
    for _ in $(seq 1 30); do
        url=$(grep -m1 -oE 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' cloudflared.log 2>/dev/null || true)
        if [ -n "$url" ]; then
            echo ""
            echo "=================================================="
            echo " ReClip è raggiungibile da fuori casa su:"
            echo " $url"
            echo "=================================================="
            break
        fi
        sleep 1
    done
) &
WATCH_PID=$!

while kill -0 "$RECLIP_PID" 2>/dev/null && kill -0 "$TUNNEL_PID" 2>/dev/null; do
    sleep 2
done

if [ "$CLEANED_UP" = 0 ]; then
    if ! kill -0 "$RECLIP_PID" 2>/dev/null; then
        echo ""
        echo "ReClip si è arrestato inaspettatamente. Ultime righe di reclip.log:"
        tail -n 20 reclip.log 2>/dev/null
    elif ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        echo ""
        echo "Il tunnel Cloudflare si è arrestato inaspettatamente. Ultime righe di cloudflared.log:"
        tail -n 20 cloudflared.log 2>/dev/null
    fi
fi
