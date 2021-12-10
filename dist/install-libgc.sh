#!/bin/bash
if ! command -v brew &> /dev/null
then
    echo "Homebrew not found; Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
brew install libgc