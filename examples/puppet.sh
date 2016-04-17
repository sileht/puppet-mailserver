#!/bin/bash

here=$(readlink -f $(dirname $0))

default_opts="--onetime --ignorecache --no-daemonize --no-usecacheonfailure --no-splay --show_diff --verbose --pluginsync --hiera_config $here/hiera.yaml --modulepath=$here/modules"
puppet apply $default_opts "$@" site.pp

