fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mz_shellstudio'
author 'MZ Framework'
description 'Editor procedural de shells Legacy com projetos server-side'
version '0.3.0'

ui_page 'web/dist/index.html'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua',
  'shared/project.lua'
}

client_script 'client/main.lua'
server_script 'server/main.lua'

files {
  'web/dist/index.html',
  'web/dist/assets/**',
  'data/projects.json',
  'data/exports/README.md'
}

dependencies {
  'ox_lib',
  'mz_core'
}
