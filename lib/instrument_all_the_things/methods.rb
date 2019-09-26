require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/hash'

module InstrumentAllTheThings
  module Methods
    class IntrumentedMethod
      include HelperMethods

      attr_accessor :meth, :options, :klass, :type

      def initialize(meth, options, klass, type)
        self.meth = meth
        self.options = options
        self.options[:trace] = {} if self.options[:trace] == true
        self.klass = klass
        self.type = type
      end

      def call(context, args, &blk)
        with_tags(tags_for_method(args, context)) do
          instrument_method(context, args, &blk)
        end
      end

      def tags_for_method(args, context)
        [
          "method:#{_naming_for_method(meth)}",
          "method_class:#{normalize_class_name(self.klass)}"
        ].concat(user_defined_tags(args, context))
      end

      def user_defined_tags(args, context)
        if options[:tags].respond_to?(:call)
          tag_proc = options[:tags]

          if tag_proc.arity.zero?
            tag_proc.call
          elsif tag_proc.arity == -2 && (tag_proc.parameters.detect {|p| p[0] == :keyreq})
            context_param = (tag_proc.parameters.detect {|p| p[0] == :keyreq})[1]
            tag_proc.call(*args, context_param => context)            
          else
            tag_proc.call(*args)
          end
        elsif options[:tags].is_a?(Array)
          options[:tags]
        else
          []
        end
      end

      def instrument_method(context, args, &blk)
        instrumentation_increment("#{instrumentation_key(context)}.count")

        instrumentation_time("#{instrumentation_key(context)}.timing") do
          capture_exception(as: instrumentation_key(context)) do

            instrument_allocations(instrumentation_key(context)) do
              execute_method(context,args, &blk).tap {
                instrumentation_increment("#{instrumentation_key(context)}.success.count")
              }
            end
          end
        end
      end

      def execute_method(context, args, &blk)
        if traced?
          _trace_method(context, args, &blk)
        else
          context.send("_#{meth}_without_instrumentation", *args, &blk)
        end
      end

      def _trace_method(context, args, &blk)
        if tracing_availiable?
          tracer.trace(trace_name(context), trace_options(context)) do |span|
            ret_value, allocations, pages = measure_memory_impact do
              context.send("_#{meth}_without_instrumentation", *args, &blk)
            end

            span.set_tag('allocation_increase', allocations)
            span.set_tag('page_increase', pages)

            ret_value
          end
        else
          InstrumentAllTheThings.config.logger.warn do
            "Requested tracing on #{meth} but no tracer configured"
          end
          context.send("_#{meth}_without_instrumentation", *args, &blk)
        end
      end

      def instrumentation_key(context)
        as = options[:as]
        prefix = options[:prefix]
        key = nil
        if as.respond_to?(:call)
          if as.arity == 0
            key = as.call
          else
            key = as.call(context)
          end
        elsif as
          key = as
        else
          key = [context.base_instrumentation_key, self.type, meth].join('.')
        end

        if prefix
          "#{prefix}.#{key}"
        else
          key
        end
      end

      def _naming_for_method(meth)
        if self.type == :instance
          "##{meth}"
        else
          ".#{meth}"
        end
      end

      private

      def trace_name(context)
        return unless options[:trace]
        if options[:trace].is_a?(Hash) && options[:trace][:as]
          options[:trace][:as]
        else
          'method.execution'
        end
      end

      def resource_name(context)
        if context.is_a?(Class)
          context.to_s + _naming_for_method(self.meth)
        else
          context.class.to_s + _naming_for_method(self.meth)
        end
      end

      def tracer
        InstrumentAllTheThings.config.tracer
      end

      def tracing_availiable?
        !!tracer
      end

      def traced?
        !!options[:trace]
      end

      def trace_options(context)
        base_options = (self.options[:trace] || {}).merge(tags: tracer_tags)
        base_options[:resource] ||= resource_name(context)
        base_options
      end

      def tracer_tags
        base = if self.options[:trace].fetch(:include_parent_tags, false)
                 Hash[InstrumentAllTheThings.active_tags.map{|t| t.split(':')}]
               else
                 {}
               end.with_indifferent_access

       base.merge(self.options[:trace].fetch( :tags, {}))
      end
    end

    def self.included(other_klass)
      other_klass.extend(ClassMethods)
      other_klass.include(HelperMethods)
    end

    def base_instrumentation_key
      self.class.base_instrumentation_key
    end

    module ClassMethods
      include HelperMethods

      def base_instrumentation_key
        to_s.underscore.tr('/','.')
      end

      def instrument(options = {})
        @options_for_next_method = options
      end

      def _instrumentors
        @_instrumentors ||= {}
      end

      def method_added(meth)
        return unless @options_for_next_method

        options = @options_for_next_method
        @options_for_next_method = nil

        alias_method "_#{meth}_without_instrumentation", meth

        _instrumentors["##{meth}"] = IntrumentedMethod.new(meth, options, self, :instance)
        instrumentor = _instrumentors["##{meth}"]

        define_method(meth) do |*args, &blk|
          instrumentor.call(self, args, &blk)
        end
      end

      def singleton_method_added(meth)
        return unless @options_for_next_method

        options = @options_for_next_method
        @options_for_next_method = nil

        define_singleton_method("_#{meth}_without_instrumentation", method(meth))

        _instrumentors[".#{meth}"] = IntrumentedMethod.new(meth, options, self, :class)
        instrumentor = _instrumentors[".#{meth}"]

        define_singleton_method(meth) do |*args, &blk|
          instrumentor.call(self, args, &blk)
        end
      end
    end
  end
end
