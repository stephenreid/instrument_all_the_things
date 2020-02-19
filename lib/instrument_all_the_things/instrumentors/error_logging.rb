# frozen_string_literal: true

require_relative './tracing'
require_relative './error_logging'

module InstrumentAllTheThings
  module Instrumentors
    DEFAULT_ERROR_LOGGING_OPTIONS = {
      exclude_bundle_path: true,
      rescue_class: StandardError,
    }.freeze

    ERROR_LOGGER = lambda do |exception, backtrace_cleaner|
    end

    ERROR_LOGGING_WRAPPER = lambda do |opts, context|
      opts = if opts == true
               DEFAULT_ERROR_LOGGING_OPTIONS
             else
               DEFAULT_ERROR_LOGGING_OPTIONS.merge(opts)
             end

      backtrace_cleaner = if opts[:exclude_bundle_path ] && defined?(Bundler)
                            bundle_path = Bundler.bundle_path.to_s
                            ->(trace) { trace.reject{|p| p.start_with?(bundle_path)} }
                          else
                            ->(trace) { trace }
                          end

      lambda do |klass, next_blk, actual_code|
        next_blk.call(klass, actual_code)
      rescue opts[:rescue_class] => e
        val = e.instance_variable_get(:@_logged_by_iatt)
        raise if val
        val = e.instance_variable_set(:@_logged_by_iatt, true)

        IATT.logger&.error("An error occurred in #{context.trace_name(klass)}")
        IATT.logger&.error(e.message)

        callstack = backtrace_cleaner.call(e.backtrace || [])

        callstack.each{|path| IATT.logger&.error(path) }

        raise
      end
    end
  end
end