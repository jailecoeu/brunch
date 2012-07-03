'use strict'

{exec} = require 'child_process'
coffeescript = require 'coffee-script'
express = require 'express'
fs = require 'fs'
sysPath = require 'path'
logger = require './logger'

exports.startsWith = startsWith = (string, substring) ->
  string.indexOf(substring) is 0

exports.callFunctionOrPass = callFunctionOrPass = (thing) ->
  if typeof thing is 'function' then thing() else thing

exports.ensureArray = ensureArray = (object) ->
  if Array.isArray object
    object
  else
    [object]

# Extends the object with properties from another object.
# Example
#   
#   extend {a: 5, b: 10}, {b: 15, c: 20, e: 50}
#   # => {a: 5, b: 15, c: 20, e: 50}
# 
exports.extend = extend = (object, properties) ->
  Object.keys(properties).forEach (key) ->
    object[key] = properties[key]
  object

recursiveExtend = (object, properties) ->
  Object.keys(properties).forEach (key) ->
    value = properties[key]
    if typeof value is 'object' and value?
      recursiveExtend object[key], properties[key]
    else
      object[key] = properties[key]
  object

exports.deepFreeze = deepFreeze = (object) ->
  Object.keys(Object.freeze(object))
    .map (key) ->
      object[key]
    .filter (value) ->
      typeof value is 'object' and value? and not Object.isFrozen(value)
    .forEach(deepFreeze)
  object

sortAlphabetically = (a, b) ->
  if a < b
    -1
  else if a > b
    1
  else
    0

# If item path starts with 'vendor', it has bigger priority.
sortByVendor = (config, a, b) ->
  aIsVendor = config.vendorConvention a
  bIsVendor = config.vendorConvention b
  if aIsVendor and not bIsVendor
    -1
  else if not aIsVendor and bIsVendor
    1
  else
    # All conditions were false, we don't care about order of
    # these two items.
    sortAlphabetically a, b

# Items wasn't found in config.before, try to find then in
# config.after.
# Item that config.after contains would have lower sorting index.
sortByAfter = (config, a, b) ->
  indexOfA = config.after.indexOf a
  indexOfB = config.after.indexOf b
  [hasA, hasB] = [(indexOfA isnt -1), (indexOfB isnt -1)]
  if hasA and not hasB
    1
  else if not hasA and hasB
    -1
  else if hasA and hasB
    indexOfA - indexOfB
  else
    sortByVendor config, a, b

# Try to find items in config.before.
# Item that config.after contains would have bigger sorting index.
sortByBefore = (config, a, b) ->
  indexOfA = config.before.indexOf a
  indexOfB = config.before.indexOf b
  [hasA, hasB] = [(indexOfA isnt -1), (indexOfB isnt -1)]
  if hasA and not hasB
    -1
  else if not hasA and hasB
    1
  else if hasA and hasB
    indexOfA - indexOfB
  else
    sortByAfter config, a, b

# Sorts by pattern.
# 
# Examples
#
#   sort ['b.coffee', 'c.coffee', 'a.coffee'],
#     before: ['a.coffee'], after: ['b.coffee']
#   # => ['a.coffee', 'c.coffee', 'b.coffee']
# 
# Returns new sorted array.
exports.sortByConfig = (files, config) ->
  if toString.call(config) is '[object Object]'
    cfg =
      before: config.before ? [] 
      after: config.after ? []
      vendorConvention: (config.vendorConvention or -> no)
    files.slice().sort (a, b) -> sortByBefore cfg, a, b
  else
    files

exports.install = install = (rootPath, callback = (->)) ->
  prevDir = process.cwd()
  logger.info 'Installing packages...'
  process.chdir rootPath
  # Install node packages.
  exec 'npm install', (error, stdout, stderr) ->
    process.chdir prevDir
    if error?
      log = stderr.toString()
      logger.error log
      return callback log
    callback null, stdout

startDefaultServer = (port, path, base, callback) ->
  server = express.createServer()
  server.use (request, response, next) ->
    response.header 'Cache-Control', 'no-cache'
    next()
  server.use base, express.static path
  server.all "#{base}/*", (request, response) ->
    response.sendfile sysPath.join path, 'index.html'
  server.listen parseInt port, 10
  server.on 'listening', callback
  server

exports.startServer = (config, callback = (->)) ->
  onListening = ->
    logger.info "application started on http://localhost:#{config.server.port}/"
    callback()
  if config.server.path
    try
      server = require sysPath.resolve config.server.path
      server.startServer config.server.port, config.paths.public, onListening
    catch error
      logger.error "couldn\'t load server #{config.server.path}: #{error}"
  else
    startDefaultServer config.server.port, config.paths.public, config.server.base, onListening

exports.replaceSlashes = replaceSlashes = (config) ->
  changePath = (string) -> string.replace(/\//g, '\\')
  files = config.files or {}
  Object.keys(files).forEach (language) ->
    lang = files[language] or {}
    order = lang.order or {}

    # Modify order.
    Object.keys(order).forEach (orderKey) ->
      lang.order[orderKey] = lang.order[orderKey].map(changePath)

    # Modify join configuration.
    switch toString.call(lang.joinTo)
      when '[object String]'
        lang.joinTo = changePath lang.joinTo
      when '[object Object]'
        newJoinTo = {}
        Object.keys(lang.joinTo).forEach (joinToKey) ->
          newJoinTo[changePath joinToKey] = lang.joinTo[joinToKey]
        lang.joinTo = newJoinTo
  config

exports.setConfigDefaults = setConfigDefaults = (config, configPath) ->
  join = (parent, name) =>
    sysPath.join config.paths[parent], name

  joinRoot = (name) ->
    join 'root', name

  paths                = config.paths     ?= {}
  paths.root          ?= config.rootPath  ? '.'
  paths.public        ?= config.buildPath ? joinRoot 'public'

  paths.app           ?= joinRoot 'app'
  paths.generators    ?= joinRoot 'generators'
  paths.test          ?= joinRoot 'test'
  paths.vendor        ?= joinRoot 'vendor'

  paths.assets        ?= join('app', 'assets')
  paths.ignored       ?= (path) -> startsWith sysPath.basename(path), '_'

  paths.config         = configPath       ? joinRoot 'config'
  paths.packageConfig ?= joinRoot 'package.json'

  # TODO: Add regex etc support.
  conventions          = config.conventions  ?= {}
  conventions.assets  ?= (path) -> /assets(\/|\\)/.test(path)
  conventions.tests   ?= (path) -> /_test\.\w+$/.test(path)
  conventions.vendor  ?= (path) -> /vendor(\/|\\)/.test(path)

  config.server       ?= {}
  config.server.base  ?= ''
  config.server.port  ?= 3333
  config.server.run   ?= no

  ensureNotArray = (name) ->
    if Array.isArray config.paths[name]
      logger.error "config.paths.#{name} can't be an array"

  ensureNotArray 'assets'
  ensureNotArray 'test'
  ensureNotArray 'vendor'

  replaceSlashes config if process.platform is 'win32'
  config

exports.loadConfig = (configPath = 'config', options = {}) ->
  fullPath = sysPath.resolve configPath
  delete require.cache[fullPath]
  try
    {config} = require fullPath
  catch error
    throw new Error("couldn\'t load config #{configPath}. #{error}")
  setConfigDefaults config, fullPath
  recursiveExtend config, options
  deepFreeze config
  config

exports.loadPackages = (rootPath, callback) ->
  rootPath = sysPath.resolve rootPath
  nodeModules = "#{rootPath}/node_modules"
  fs.readFile sysPath.join(rootPath, 'package.json'), (error, data) ->
    return callback error if error?
    json = JSON.parse(data)
    deps = Object.keys(extend(json.devDependencies ? {}, json.dependencies))
    try
      plugins = deps.map (dependency) -> require "#{nodeModules}/#{dependency}"
    catch err
      error = err
    callback error, plugins

exports.getPlugins = (packages, config) ->
  packages
    .filter (plugin) ->
      (plugin::)? and plugin::brunchPlugin
    .map (plugin) ->
      new plugin config

getTestFiles = (config) ->
  isTestFile = (generatedFile) ->
    exports.startsWith(generatedFile, sysPath.normalize('test/')) and
    generatedFile.lastIndexOf('vendor') is -1

  joinPublic = (generatedFile) ->
    sysPath.join(config.paths.public, generatedFile)

  joinTo = config.files.javascripts.joinTo
  files = if typeof joinTo is 'string' then [joinTo] else Object.keys(joinTo)
  files.filter(isTestFile).map(joinPublic)

cachedTestFiles = null

exports.findTestFiles = (config) ->
  cachedTestFiles ?= getTestFiles config
