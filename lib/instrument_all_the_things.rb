# frozen_string_literal: true

require 'ddtrace'

require 'instrument_all_the_things/version'

require_relative './instrument_all_the_things/helpers'
require_relative './instrument_all_the_things/clients/stat_reporter/datadog'

module InstrumentAllTheThings
  class Error < StandardError; end

  class << self
    attr_accessor :stat_namespace
    attr_writer :logger, :stat_reporter, :tracer

    def logger
      return @logger if defined?(@logger)

      @logger ||= if defined?(Rails)
                    Rails.logger
                  elsif defined?(App) && App.respond_to?(:logger)
                    App.logger
                  else
                    require 'logger'
                    Logger.new($stdout)
                  end
    end

    def stat_reporter
      @stat_reporter ||= Clients::StatReporter::DataDog.new(
        ENV.fetch('DATADOG_HOST', 'localhost'),
        ENV.fetch('DATADOG_PORT', 8125),
        namespace: stat_namespace,
      )
    end

    def tracer
      return @tracer if defined?(@tracer)

      @tracer ||= Datadog.tracer
    end

    %i[
      increment
      decrement
      count
      gauge
      set
      histogram
      distribution
      timing
      time
    ].each do |method_name|
      define_method(method_name) do |*args, &blk|
        return unless stat_reporter

        stat_reporter.public_send(method_name, *args, &blk)
      end
    end
  end

  def self.included(other)
    other.include(Helpers)
  end

  def self.tag_active_span(tag_name, tag_value)
    tracer&.active_span&.set_tags(to_tracer_tags(tag_name => tag_value))
  end

  def self.tag_active_root_span(tag_name, tag_value)
    tracer&.active_span&.set_tags(to_tracer_tags(tag_name => tag_value))
  end

  def self.to_tracer_tags(hsh, prefix = nil)
    hsh.each_with_object({}) do |(hash_key, value), acc|
      key = prefix ? "#{prefix}.#{hash_key}" : hash_key

      case value
      when Hash
        acc.merge!(to_tracer_tags(value, key))
      when Array
        content = value.each_with_index.each_with_object({}) do |(item, index), reformed|
          reformed[index] = item
        end

        acc.merge!(to_tracer_tags(content, key))
      else
        acc[key] = value
      end
    end
  end
end

IATT = InstrumentAllTheThings unless defined?(IATT)
