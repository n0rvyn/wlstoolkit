# wlstoolkit

## This script is used for creating domain&server for Weblogic

USAGE:
  $file_name [ options ] [ action ]

for example:
  $file_name -D domain01 -S server01:8001 -S server02:8002 -c

Options:
  -D DOMAIN         name of domain to be create
  -S SERVER:PORT    name and port of managed server

  -i IP ADDRESS     ip address be listened by weblogic console and provide service, default: 0.0.0.0
  -o [true|false]   whether to allow an existing domain to be overwritten, 'false' by default
  -m [dev | prod]   domain start mode production or development, default: 'prod'
  -p PORT           domain console port, default: '7001'
  -P PORT           domain console ssl port, default: '7002'
  -u                whether to grant command systemctl the executing permission to user 'weblogic', default: 'true'
  -n                name of wls admin server
  -h                home of user 'weblogic', default: '/home/weblogic'

Actions:
  -c                create domain and server, MUST be running as user 'weblogic'

  -b                setup service on boot for admin[managed] server
                    root permission necessary
