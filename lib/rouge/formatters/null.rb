module Rouge
  module Formatters
    # Does nothing.
    class Null < Formatter
      tag 'null'
      
      def initialize(opts={})
      end
      
      def stream(tokens, &b)
        tokens.each do |tok, val|
        end
      end
    end
  end
end
