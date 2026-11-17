#!/bin/sh
# Rebuilds index.html from the pieces in src/ (photos are already embedded in src/photos.js).
cd "$(dirname "$0")"
{ printf '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'; cat src/top.html src/photos.js src/bottom.html; } > index.html
