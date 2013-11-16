module Rouge
  module Lexers
    class JSON < RegexLexer
      desc "JavaScript Object Notation (json.org)"
      tag 'json'
      filenames '*.json'
      mimetypes 'application/json'

      # TODO: is this too much of a performance hit?  JSON is quite simple,
      # so I'd think this wouldn't be too bad, but for large documents this
      # could mean doing two full lexes.
      def self.analyze_text(text)
        return 0.8 if text =~ /\A\s*\{/m && text.lexes_cleanly?(self)
      end

      KEY = / (?> (?: [^\\"]+ | \\. )* ) " \s* : /mx
      state :root do
        rule /\s+/m, Text::Whitespace
        
        rule /"(?=#{KEY})/o, Str::Double, :key
        rule /"/, Str::Double, :string
        
        rule /[:,\[{\]}]/, Punctuation
        
        rule /(?:true|false|null)/, Keyword::Constant
        rule /-?(?:0|[1-9]\d*)\.\d+(?:e[+-]\d+)?/i, Num::Float
        rule /-?(?:0|[1-9]\d*)(?:e[+-]\d+)?/i, Num::Integer
      end
      
      state(:string) { mixin :key_or_string }
      state(:key)    { mixin :key_or_string }
      
      state :key_or_string do
        rule %r/ [^\\"]+ /x, Str::Double
      
        rule %r/ " /x, Str::Double, :pop!
      
        rule %r/ \\ (?: [bfnrt\\"\/] | u[a-fA-F0-9]{4} ) /x, Str::Double
        rule %r/ \\. /mx, Str::Double
        rule %r/ \\ /x, Error, :pop!
      end
    end
  end
end
