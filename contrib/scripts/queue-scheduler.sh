#!/bin/sh
# Copyright (c) 2010 Tomas Carnecky

# *************
# Path to transmission-remote
REMOTE="transmission-remote"

# Maximum number of torrents that may be active at any given time
MAXACTIVE="8"

# *************
# Stop all finished torrents
LIST="$($REMOTE -l | tail --lines=+2 | grep 100% | grep -v Stopped | awk '{ print $1; }')"
for ID in $LIST; do
    NAME="$($REMOTE --torrent $ID --info | grep Name:)"
    echo "<<< $ID: ${NAME#*Name: }"
    $REMOTE --torrent $ID --stop >/dev/null
done

# How many are still running?
ACTIVE="$($REMOTE -l | tail --lines=+2 | grep -v Stopped | grep -v "^Sum\:" | wc -l)"
if [ $ACTIVE -gt $MAXACTIVE ]; then
    exit
fi

# Start new torrents
LIST="$($REMOTE -l | tail --lines=+2 | grep -v 100% | grep Stopped | shuf | head -n $(expr $MAXACTIVE - $ACTIVE) | awk '{ print $1; }')"
for ID in $LIST; do
    NAME="$($REMOTE --torrent $ID --info | grep Name:)"
    echo ">>> $ID: ${NAME#*Name: }"
    $REMOTE --torrent $ID --start --verify >/dev/null
done