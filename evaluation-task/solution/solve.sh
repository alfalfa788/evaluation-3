#!/bin/bash
set -euo pipefail
patch -t -p1 --ignore-whitespace -i /solution/patch.diff
