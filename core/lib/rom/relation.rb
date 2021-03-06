require 'dry/core/class_attributes'

require 'rom/initializer'
require 'rom/relation/class_interface'

require 'rom/pipeline'
require 'rom/mapper_registry'
require 'rom/mapper_compiler'

require 'rom/relation/loaded'
require 'rom/relation/curried'
require 'rom/relation/composite'
require 'rom/relation/graph'
require 'rom/relation/materializable'
require 'rom/association_set'

require 'rom/types'
require 'rom/schema'

require 'rom/relation/combine'
require 'rom/relation/wrap'

module ROM
  # Base relation class
  #
  # Relation is a proxy for the dataset object provided by the gateway. It
  # can forward methods to the dataset, which is why the "native" interface of
  # the underlying gateway is available in the relation. This interface,
  # however, is considered private and should not be used outside of the
  # relation instance.
  #
  # Individual adapters sets up their relation classes and provide different APIs
  # depending on their persistence backend.
  #
  # Vanilla Relation class doesn't have APIs that are specific to ROM container setup.
  # When adapter Relation class inherits from this class, these APIs are added automatically,
  # so that they can be registered within a container.
  #
  # @see ROM::Relation::ClassInterface
  #
  # @api public
  class Relation
    # Default no-op output schema which is called in `Relation#each`
    NOOP_OUTPUT_SCHEMA = -> tuple { tuple }.freeze

    extend Initializer
    extend ClassInterface

    include Combine
    include Wrap

    extend Dry::Core::ClassAttributes
    defines :schema_class, :schema_inferrer, :schema_dsl

    schema_dsl Schema::DSL
    schema_class Schema
    schema_inferrer Schema::DEFAULT_INFERRER

    include Dry::Equalizer(:name, :dataset)
    include Materializable
    include Pipeline

    # @!attribute [r] dataset
    #   @return [Object] dataset used by the relation provided by relation's gateway
    #   @api public
    param :dataset

    # @!attribute [r] schema
    #   @return [Schema] relation schema, defaults to class-level canonical
    #                    schema (if it was defined) and sets an empty one as
    #                    the fallback
    #   @api public
    option :schema, default: -> { self.class.default_schema(self) }

    # @!attribute [r] input_schema
    #   @return [Object#[]] tuple processing function, uses schema or defaults to Hash[]
    #   @api private
    option :input_schema, default: -> { schema? ? schema.to_input_hash : Hash }

    # @!attribute [r] output_schema
    #   @return [Object#[]] tuple processing function, uses schema or defaults to NOOP_OUTPUT_SCHEMA
    #   @api private
    option :output_schema, default: -> {
      schema.any?(&:read?) ? schema.to_output_hash : NOOP_OUTPUT_SCHEMA
    }

    # @!attribute [r] mappers
    #   @return [MapperRegistry] an optional mapper registry (empty by default)
    option :mappers, default: -> { MapperRegistry.new }

    # @!attribute [r] auto_struct
    #   @return [TrueClass,FalseClass] Whether or not tuples should be auto-mapped to structs
    #   @api private
    option :auto_struct, reader: true, default: -> { false }

    # @!attribute [r] auto_map
    #   @return [TrueClass,FalseClass] Whether or not a relation and its compositions should be auto-mapped
    #   @api private
    option :auto_map, reader: true, default: -> { false }

    # @!attribute [r] mapper_compiler
    #   @return [MapperCompiler] A mapper compiler instance for auto-struct mapping
    #   @api private
    option :mapper_compiler, reader: true, default: -> { ROM::MapperCompiler.new }

    # @!attribute [r] meta
    #   @return [Hash] Meta data stored in a hash
    #   @api private
    option :meta, reader: true, default: -> { EMPTY_HASH }

    # Return schema attribute
    #
    # @example accessing canonical attribute
    #   users[:id]
    #   # => #<ROM::SQL::Attribute[Integer] primary_key=true name=:id source=ROM::Relation::Name(users)>
    #
    # @example accessing joined attribute
    #   tasks_with_users = tasks.join(users).select_append(tasks[:title])
    #   tasks_with_users[:title, :tasks]
    #   # => #<ROM::SQL::Attribute[String] primary_key=false name=:title source=ROM::Relation::Name(tasks)>
    #
    # @return [Schema::Attribute]
    #
    # @api public
    def [](name)
      schema[name]
    end

    # Yields relation tuples
    #
    # Every tuple is processed through Relation#output_schema, it's a no-op by default
    #
    # @yield [Hash]
    #
    # @return [Enumerator] if block is not provided
    #
    # @api public
    def each(&block)
      return to_enum unless block

      if auto_struct?
        mapper.(dataset.map { |tuple| output_schema[tuple] }).each { |struct| yield(struct) }
      else
        dataset.each { |tuple| yield(output_schema[tuple]) }
      end
    end

    # Composes with other relations
    #
    # @param [Array<Relation>] others The other relation(s) to compose with
    #
    # @return [Relation::Graph]
    #
    # @api public
    def graph(*others)
      Graph.build(self, others)
    end

    # Loads relation
    #
    # @return [Relation::Loaded]
    #
    # @api public
    def call
      Loaded.new(self)
    end

    # Materializes a relation into an array
    #
    # @return [Array<Hash>]
    #
    # @api public
    def to_a
      to_enum.to_a
    end

    # Returns if this relation is curried
    #
    # @return [false]
    #
    # @api private
    def curried?
      false
    end

    # Returns if this relation is a graph
    #
    # @return [false]
    #
    # @api private
    def graph?
      false
    end

    # Returns true if a relation has schema defined
    #
    # @return [TrueClass, FalseClass]
    #
    # @api private
    def schema?
      ! schema.empty?
    end

    # Return a new relation with provided dataset and additional options
    #
    # Use this method whenever you need to use dataset API to get a new dataset
    # and you want to return a relation back. Typically relation API should be
    # enough though. If you find yourself using this method, it might be worth
    # to consider reporting an issue that some dataset functionality is not available
    # through relation API.
    #
    # @example with a new dataset
    #   users.new(users.dataset.some_method)
    #
    # @example with a new dataset and options
    #   users.new(users.dataset.some_method, other: 'options')
    #
    # @param [Object] dataset
    # @param [Hash] new_opts Additional options
    #
    # @api public
    def new(dataset, new_opts = EMPTY_HASH)
      if new_opts.empty?
        opts = options
      elsif new_opts.key?(:schema)
        opts = options.reject { |k, _| k == :input_schema || k == :output_schema }.merge(new_opts)
      else
        opts = options.merge(new_opts)
      end

      self.class.new(dataset, opts)
    end

    # Returns a new instance with the same dataset but new options
    #
    # @example
    #   users.with(output_schema: -> tuple { .. })
    #
    # @param new_options [Hash]
    #
    # @return [Relation]
    #
    # @api private
    def with(new_options)
      new(dataset, options.merge(new_options))
    end

    # Return all registered relation schemas
    #
    # This holds all schemas defined via `view` DSL
    #
    # @return [Hash<Symbol=>Schema>]
    #
    # @api public
    def schemas
      @schemas ||= self.class.schemas
    end

    # Return schema's association set (empty by default)
    #
    # @return [AssociationSet] Schema's association set (empty by default)
    #
    # @api public
    def associations
      @associations ||= schema.associations
    end

    # Returns AST for the wrapped relation
    #
    # @return [Array]
    #
    # @api public
    def to_ast
      @__ast__ ||= [:relation, [name.relation, meta_ast, [:header, attr_ast + wraps_ast]]]
    end

    # @api private
    def attr_ast
      if meta[:wrap]
        schema.wrap.map { |attr| [:attribute, attr] }
      else
        schema.reject(&:wrapped?).map { |attr| [:attribute, attr] }
      end
    end

    # @api private
    def wraps_ast
      wraps.map(&:to_ast)
    end

    # @api private
    def meta_ast
      meta = self.meta.merge(dataset: name.dataset)
      meta.update(model: false) unless auto_struct? || meta[:model]
      meta.delete(:wraps)
      meta
    end

    # @api private
    def auto_map?
      (auto_map || auto_struct) && !meta[:combine_type]
    end

    # @api private
    def auto_struct?
      auto_struct && !meta[:combine_type]
    end

    # @api private
    def mapper
      mapper_compiler[to_ast]
    end

    # @api private
    def wraps
      @__wraps__ ||= meta.fetch(:wraps, EMPTY_ARRAY)
    end

    # Maps the wrapped relation with other mappers available in the registry
    #
    # @overload map_with(model)
    #   Map tuples to the provided custom model class
    #
    #   @example
    #     users.as(MyUserModel)
    #
    #   @param [Class>] model Your custom model class
    #
    # @overload map_with(*mappers)
    #   Map tuples using registered mappers
    #
    #   @example
    #     users.map_with(:my_mapper, :my_other_mapper)
    #
    #   @param [Array<Symbol>] mappers A list of mapper identifiers
    #
    # @overload map_with(*mappers, auto_map: true)
    #   Map tuples using auto-mapping and custom registered mappers
    #
    #   If `auto_map` is enabled, your mappers will be applied after performing
    #   default auto-mapping. This means that you can compose complex relations
    #   and have them auto-mapped, and use much simpler custom mappers to adjust
    #   resulting data according to your requirements.
    #
    #   @example
    #     users.map_with(:my_mapper, :my_other_mapper, auto_map: true)
    #
    #   @param [Array<Symbol>] mappers A list of mapper identifiers
    #
    # @return [RelationProxy] A new relation proxy with pipelined relation
    #
    # @api public
    def map_with(*names, **_opts)
      if names.size == 1 && names[0].is_a?(Class)
        with(meta: meta.merge(model: names[0]))
      elsif names.size > 1 && names.any? { |name| name.is_a?(Class) }
        raise ArgumentError, 'using custom mappers and a model is not supported'
      else
        super(*names)
      end
    end
    alias_method :as, :map_with

    # @return [Symbol] The wrapped relation's adapter identifier ie :sql or :http
    #
    # @api private
    def adapter
      self.class.adapter
    end

    private

    # Hook used by `Pipeline` to get the class that should be used for composition
    #
    # @return [Class]
    #
    # @api private
    def composite_class
      Relation::Composite
    end
  end
end
