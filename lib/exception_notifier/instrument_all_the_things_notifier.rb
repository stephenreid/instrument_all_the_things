require 'exception_notifier'
module ExceptionNotifier
  class InstrumentAllTheThingsNotifier < BaseNotifier
    def call(exception, options = {})
      message = ""

      send_notice(exception, options, message) do |msg, _|
        InstrumentAllTheThings::Exception.register(exception)
      end
    end
  end
end
