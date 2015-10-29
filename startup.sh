#!/bin/bash

root=/opt/rjb

sed -i "s/^var backend.*/var backend = 'http:\/\/$VIRTUAL_HOST\/backend';/" "$root/public/js/main.js"

config="$root/all.yaml"

sed -i "s/^:path.*/:path: \/opt\/cdda\/data/" $config

sed -i "s/^:background.*/:background: false/" $config

sed -i "s/^:git_pull.*/:git_pull: origin master/" $config

$root/cddarjb.rb $config
