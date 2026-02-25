#!/usr/bin/env bash

set -o monitor

GREEN='\033[0;32m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
NC='\033[0m'

log() {
  echo -e "${GREEN}[INFO]${NC} $@"
}

warning() {
  echo -e "${ORANGE}[WARNING]${NC} $@"
}

error() {
  echo -e "${RED}[ERROR]${NC} $@"
}
