#!/bin/bash
sudo systemctl restart --now ronny-watch ronny-bot ronny-watchdog
journalctl -u ronny-watch -u ronny-bot -f
