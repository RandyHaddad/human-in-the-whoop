#!/bin/bash

set -euo pipefail

printf 'hitwctl|%s\n' "$*" >> "${HITW_TEST_LIFECYCLE_LOG:?missing lifecycle log fixture}"
exit 0
