_       = require 'underscore'
logging = require './logging'
require './string'

defaults =
  depends: []
  test_depends: []
  sources: []
  depends_folder: 'requires'
  test_build_source_file: 'auto-source.js'
  test_build_test_file: 'auto-test.js'
  spec_folder: 'specs'
  source_folder: 'src'

  build_output: 'output.js'

###
@description Represents an instance of a Package, which is the basic
  unit in Jspackle.  All tasks are executed against a single package.
  Provides public methods to execute the basic tasks that Jspackle
  allows on itself.

@name Package
@class
###
class Package

  ###
  Load any methods or libraries that interact with the outside
    system as properties on this class. Allows for them to be easily
    stubbed in our specs so that it can be tested in complete isolation.
  ###
  flow:    require 'flow'
  fs:      require 'fs'
  coffee:  require 'coffee-script'
  exec:    require('child_process').exec
  readDir: require './readdir'
  yaml:    require 'pyyaml'
  exit:    process.exit

  ###
  @description Use the settings provided in ``opts`` (command line options
    for the entire Jspackle process) as well as the settings in ``cmd``
    (command line options specific for the sub-command that is going to be
    executed to define the ``@opts`` for this Package instance.

    Extend objects in reverse precedence:  overwrite previously set
    properties, giving the last item the highest precedence.

      1. Default settings                      (Lowest precedence)
      2. Config file settings
      3. Commandline options
      4. Command specific command-line options (Highest precedence)

  @param   {Object} opts Commandline options for jspackle
  @param   {Object} cmd  Commandline options specific to jspackle subcommand
  @returns {void}

  @public
  @function
  @constructor
  @memberOf Package.prototype
  ###
  constructor: (opts={}, cmd={})->
    configs = @loadConfigs opts
    @opts = []
    _.extend @opts, defaults, configs, opts, cmd


  ###
  @description Using the base options provided to Jspackle, load the
    Jspackle config file that defines this package.

  @param   {Object} opts Commandline options for jspackle
  @returns {Object} Config files parsed from the JSON config-file

  @public
  @function
  @memberOf Package.prototype
  ###
  loadConfigs: (opts)->
    path = opts.root+opts.path
    logging.debug "Parsing jspackle file: #{path}"
    try
      JSON.parse @fs.readFileSync path
    catch e
      logging.critical "ERROR opening config file '#{path}'"
      @exit 1


  ###
  @description Defines the standard behavior of when an error is
    encountered. Logs the error and ends the process with an error
    code.

  @param {mixed} e Error.  Regardless of type, it is passed to the
    logging module where it co-erced to a string.
  @param {integer} code Error code to exit this process with. Defaults
    to 1 (standard error).
  @returns {void}

  @public
  @function
  @memberOf Package.prototype
  ###
  error: (e, code=1)->
    logging.warn e
    @exit code

  build: ->
    _this = this
    sources = []

    # Asyncronously read sources into memory and cache them
    # the sources object.  Register it as an async multi-step
    # flow command
    loadSources = ->
      flow = this
      for index, src of _this.sources

        # Execute in a closure so that i is local to this
        # loop, so that it doesn't change by the time our
        # callback is executed.
        do ->
          i = index
          registered = flow.MULTI()

          # Read the file, cache the source, and mark this portion of
          # the multi-step as complete
          _this.fs.readFile _this.opts.root+src, (err, src)->
            _this.error err if err
            sources[i] = src
            registered()

    # Once all our registered multi-steps have completed, join
    # the ordered sources with new lines and write the output
    # to our build file.
    processSources = ->
      _this.fs.writeFile _this.opts.root+_this.opts.build_output, sources.join "\n", this

    # End the program, returning the correct error code based on if
    # writing finished or not.
    finish = (err)->
      _this.exit if err then 1 else 0

    @flow.exec loadSources, processSources, finish



  ###
  @description The ``test`` task.  Create test config file, execute
    tests, and clean up after itself.

  @returns {void}

  @public
  @function
  @memberOf Package.prototype
  ###
  test: ->
    try
      @_createJsTestDriverFile (err)=>
        if err
          return @error err
        @_executeTests (code)=>
          if err
            return @error err
          @clean()
          if code
            logging.critical 'An error occurred while running tests'
          @exit code
    catch e
      @error e
      logging.warn e
      process.exit 1

  ###
  @description Cleans up after a task.  Unlinks any temporary files that
    were created as part of its process.

  @returns {void}

  @public
  @function
  @memberOf Package.prototype
  ###
  clean: ->
    @fs.unlink "#{@opts.root}JsTestDriver.conf"
    @fs.unlink @opts.test_build_source_file
    @fs.unlink @opts.test_build_test_file

  ### ------ Private Methods ------- ###

  _executeTests: (callback)->
    logging.debug "Executing tests: #{@testCmd}"
    @exec @testCmd, (err, stdout, stderr)->
      msg =  """

Output:

#{stdout}
"""
      if err
        logging.warn msg
        code = err.code
      else
        logging.info msg
        code = 0
      callback code

  _createJsTestDriverFile: (callback)->
    configs =
      server: @opts.test_server
      timeout: @opts.test_timeout

    configs.load = @depends.concat(@testDepends).concat(@sources)
    configs.test = @tests

    logging.info "Executing #{configs.test.length} specs"

    path = "#{@opts.root}JsTestDriver.conf"
    logging.debug "Dumping configs to: #{path}"
    @yaml.dump configs, path, callback

  _coffeeCompile: (sources, path)->
    logging.info "Compiling coffee-script to '#{path}'"
    compiled = []
    paths = []
    for src in sources
      if src.isHTTP()
        paths.push src
      else
        compiled.push @coffee.compile @fs.readFileSync(src).toString()
    @fs.writeFileSync path, compiled.join "\n"
    paths.push path
    return paths

  _findTests: ->
    found = @readDir @opts.root+@opts.spec_folder
    tests = []
    for file in found.files
      if file.isScript()
        logging.debug "Discovered test: '#{file}'"
        tests.push(file.replace(@opts.root+@opts.spec_folder+'/', ''))
    tests

  _process: (option, folder, compile=false)->
    root = folder+'/'
    sources = []
    if typeof option == 'string'
      paths = @opts[option]
    else
      paths = option

    for path in paths
      if path.isHTTP()
        sources.push path
      else
        sources.push root+path
    return sources if not (compile and @opts.coffee)
    @_coffeeCompile sources, compile

###
Read only properties
--------------------

Defines read-only properties on the Package object using  v8's
``__defineGetter__`` syntax.  These properties expand arguments that
are provided as part of the configuration into fleshed out properties.
###
Package.prototype.__defineGetter__ 'sources', ->
  @_process 'sources', @opts.source_folder, @opts.test_build_source_file

Package.prototype.__defineGetter__ 'depends', ->
  @_process 'depends', @opts.depends_folder

Package.prototype.__defineGetter__ 'testDepends', ->
  @_process 'test_depends', @opts.depends_folder

Package.prototype.__defineGetter__ 'tests', ->
  @_process @_findTests(), @opts.spec_folder, @opts.test_build_test_file

Package.prototype.__defineGetter__ 'testCmd', ->
  "js-test-driver --config ./JsTestDriver.conf --tests all #{@opts.test_args}"

module.exports = Package
