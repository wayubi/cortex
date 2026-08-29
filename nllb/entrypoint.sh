#!/bin/sh
while true; do
    python3 /app/server.py
    echo "Server exited, restarting..."
    sleep 1
done
