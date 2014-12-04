_                  = require 'lodash'
B                  = require 'backbone'
Imm                = require 'immutable'
Morearty           = require 'morearty'
{Binding, History} = Morearty
linkBinding        = Morearty.Callback.set
imm                = Imm.fromJS

mixOf = (base, mixins...) ->
  class Mixed extends base
  for mixin in mixins by -1 # earlier mixins override later ones
    for name, method of mixin::
      Mixed::[name] = method
  Mixed

# Handle both `"key", value` and `{key: value}` -style arguments.
# (from Backbone.Model.set)
attrsAndOptions = (key, val, options) ->
  attrs = {}
  if typeof key == 'object'
    attrs = key
    options = val
  else
    attrs[key] = val

  attrs: attrs
  options: options || {}

statusMap =
  'create': 'creating'
  'update': 'updating'
  'patch' : 'patching'
  'delete': 'deleting'
  'read'  : 'reading'

validateModel = (ModelOrCollectionClass, BaseClass, type) ->
  if ModelOrCollectionClass != BaseClass
    if !(ModelOrCollectionClass.prototype instanceof BaseClass)
      throw new Error "#{type} should be instance of #{BaseClass.name}"


class SyncMixin
  sharedDefaults:
    trackXhrStatus: true

  sync: (method, model, options = {}) ->
    xhr = B.sync.apply @, arguments

    @setXhrStatus 'xhr', statusMap[method]
    xhr
      .success =>
        @unsetXhrStatus 'error'
      .fail (e, error, errorMessage) =>
        # TODO: merge previous state instead of undo, 'status' and 'error' make binding dirty
        @history?.undo() if options.rollback
        @setXhrStatus 'error', e.responseJSON

      .always => @unsetXhrStatus 'xhr'

  # Write model data to the new binding and point @binding to it
  bindTo: (newBinding) ->
    newBinding.set @binding.get()
    @binding = newBinding

  isPending: ->
    @getStatus 'xhr'

  # TODO: add model level transaction
  setStatus: (key, status, tx) ->
    {attrs, options: tx} = attrsAndOptions key, status, tx
    (if !_.isEmpty tx then tx else @binding.meta()).merge imm(attrs)

  unsetStatus: (key, tx) ->
    (if !_.isEmpty tx then tx else @binding.meta()).delete key

  getStatus: (key) ->
    @binding.meta().get key

  setXhrStatus: (key, status) ->
    if @options.trackXhrStatus
      @setStatus key, status

  unsetXhrStatus: (key) ->
    if @options.trackXhrStatus
      @unsetStatus key

  toJSON: ->
    @binding.toJS()



class SyncModel extends mixOf B.Model, SyncMixin
  ###
  @param {Binding|Object} data - representing the model data. For raw object new binding will be created.
  ###
  constructor: (data, options = {}) ->
    @options = _.extend @sharedDefaults, options

    @binding =
      if data instanceof Binding
        data
      else
        # TODO: For now new binding is created if model is new. In this case binding
        # should be pointed to Vector entry when model data goes to collection.
        # The main question is: leave it as is or do not create own binding
        # for empty model and then strictly bind it to main state?
        data = @parse(data, @options) || {} if @options.parse
        Binding.init imm(data)

    # TODO: rewrite Morearty.History class
    # @_historyBinding = Binding.init()
    # @history = History.init @binding, @_historyBinding

    Object.defineProperties @,
      'id':
        writeable: false
        get: ->
          @get @idAttribute || 'id'

        set: (id) ->
          @set(@idAttribute || 'id', id)

    @initialize.apply @, arguments

  # TODO: return imm object with @binding.get(...)
  get: (key) ->
    @binding.toJS key

  set: (key, val, options) ->
    return @ unless key
    {attrs, options} = attrsAndOptions key, val, options

    # Protect from empty merge which triggers binding listeners
    return if _.isEmpty attrs

    tx = @binding.atomically()

    if options.unset
      tx.delete k for k of attrs
    else
      tx.merge imm(attrs)

    # @setStatus 'saved', false, tx

    # Speculative update: set first, then validate
    validationError = @validate?(@toJSON())

    if validationError
      @setStatus 'validationError', imm(validationError), tx
    else
      @unsetStatus 'validationError', tx

    tx.commit notify: options.silent # should be strictly false to silent listeners

    @

  clear: (path) ->
    @binding.clear path

  unsetIfExists: (key) ->
    @unset key if @get key


# -----------------------------------------------------------------------
class SyncCollection extends mixOf B.Collection, SyncMixin
  model: SyncModel

  constructor: (@binding, options = {}) ->
    if !(@binding.get() instanceof Imm.List ||
        @binding.get() instanceof Imm.Set ||
        @binding.get() instanceof Imm.Stack)
      throw new Error 'SyncCollection binding should point to Immutable.IndexedIterable (List, Set, etc.)'

    @options = _.extend @sharedDefaults, options
    @initialize.apply @, arguments
    validateModel @model, SyncModel, 'SyncCollection.model'

  # TODO: try to store objects in the Map
  get: (id) ->
    item = @binding.get().find (x) -> x.get('id') == id
    new @model(item) if item

  set: (models, options = {}) ->
    models = this.parse(models, options) if options.parse
    models = imm(models);

    # TODO: add merge and delete
    if options.reset
      @binding.set models
    else
      @binding.update (v) -> v.concat models

  reset: (models, options) ->
    @set models, options

  at: (index) ->
    new @model @binding.sub(index)


# -----------------------------------------------------------------------

MoreartySync =
  SyncModel: SyncModel
  SyncCollection: SyncCollection

  createContext: ({state, modelMapping, configuration}) ->
    Ctx = Morearty.createContext state, configuration
    Ctx._modelMap = {}
    Ctx._modelMapRegExps = []
    Ctx._modelInstances = {}

    for {path, model} in modelMapping
      # validateModel ModelOrCollection, SyncModel, 'model'
      # validateModel ModelOrCollection, SyncCollection, 'collection'
      ModelOrCollection = model

      # just split by reg-exps and normal paths
      if path instanceof RegExp
        Ctx._modelMapRegExps.push pathRegExp: path, model: ModelOrCollection
      else
        Ctx._modelMap[path] = ModelOrCollection

    Ctx

  Mixin:
    ###
    Lazy model retrieval
    @param {Binding|String} binding - binding instance or an absolute binding path
    @param {Morearty.Context} ctx - morearty context
    ###
    model: (binding = @getDefaultBinding(), ctx = @context.morearty) ->
      {binding, path} =
        if binding instanceof Binding
          binding: binding
          path: Binding.asStringPath(binding._path)
        else
          path = binding
          binding: ctx.getBinding().sub path
          path: path

      model =
        if m = ctx._modelInstances[path]
          m
        else if ModelOrCollection = ctx._modelMap[path]
          ctx._modelInstances[path] = new ModelOrCollection binding
        else if matched = path.match /(.*)\.(\d+)/
          # check if path is a vector item: some.list.x
          [__, vectorPath, itemIndex] = matched
          collection = ctx._modelInstances[vectorPath]
          model = collection?.at itemIndex
        else
          # check in regexps
          MClass =
            (ctx._modelMapRegExps.filter (rx) ->
              path.match rx.pathRegExp
            )[0]?.model

          ctx._modelInstances[path] = new MClass binding if MClass

    collection: (binding, ctx) ->
      @model binding, ctx

    linkModel: (model, path, {beforeEdit, afterEdit}) ->
      beforeEdit ||= _.identity
      afterEdit  ||= _.noop

      (domEvent) ->
        {value} = domEvent.target
        model.binding.set path, beforeEdit(value)
        afterEdit value


module.exports = MoreartySync
