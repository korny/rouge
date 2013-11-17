module Rouge
  # @abstract
  # A stateful lexer that uses sets of regular expressions to
  # tokenize a string.  Most lexers are instances of RegexLexer.
  class RegexLexer < Lexer
    # A rule is a tuple of a regular expression to test, and a callback
    # to perform if the test succeeds.
    #
    # @see StateDSL#rule
    class Rule
      attr_reader :callback
      attr_reader :re
      def initialize(re, callback)
        @re = re
        @callback = callback
      end

      # Does the regex start with a ^?
      #
      # Since Regexps are immuntable, this is cached to avoid
      # calling Regexp#source more than once.
      def beginning_of_line?
        return @beginning_of_line if instance_variable_defined?(:@beginning_of_line)

        @beginning_of_line = re.source[0] == ?^
      end

      def inspect
        "#<Rule #{@re.inspect}>"
      end
    end

    # a State is a named set of rules that can be tested for or
    # mixed in.
    #
    # @see RegexLexer.state
    class State
      attr_reader :name, :rules
      def initialize(name, rules)
        @name = name
        @rules = rules
      end

      def inspect
        "#<#{self.class.name} #{@name.inspect}>"
      end
    end

    class StateDSL
      attr_reader :rules
      def initialize(name, &defn)
        @name = name
        @defn = defn
        @rules = []
      end

      def to_state(lexer_class)
        load!
        rules = @rules.map do |rule|
          rule.is_a?(String) ? lexer_class.get_state(rule) : rule
        end
        State.new(@name, rules)
      end

      def prepended(&defn)
        parent_defn = @defn
        StateDSL.new(@name) do
          instance_eval(&defn)
          instance_eval(&parent_defn)
        end
      end

      def appended(&defn)
        parent_defn = @defn
        StateDSL.new(@name) do
          instance_eval(&parent_defn)
          instance_eval(&defn)
        end
      end

    protected
      # Define a new rule for this state.
      #
      # @overload rule(re, token, next_state=nil)
      # @overload rule(re, &callback)
      #
      # @param [Regexp] re
      #   a regular expression for this rule to test.
      # @param [String] tok
      #   the token type to yield if `re` matches.
      # @param [#to_s] next_state
      #   (optional) a state to push onto the stack if `re` matches.
      #   If `next_state` is `:pop!`, the state stack will be popped
      #   instead.
      # @param [Proc] callback
      #   a block that will be evaluated in the context of the lexer
      #   if `re` matches.  This block has access to a number of lexer
      #   methods, including {RegexLexer#push}, {RegexLexer#pop!},
      #   {RegexLexer#token}, and {RegexLexer#delegate}.  The first
      #   argument can be used to access the match groups.
      def rule(re, tok=nil, next_state=nil, &callback)
        callback ||= case next_state
        when :pop!
          proc { token tok; pop! }
        when Symbol
          proc { token tok; push next_state }
        else
          proc { token tok }
        end

        rules << Rule.new(re, callback)
      end

      # Mix in the rules from another state into this state.  The rules
      # from the mixed-in state will be tried in order before moving on
      # to the rest of the rules in this state.
      def mixin(state)
        rules << state.to_s
      end

    private
      def load!
        return if @loaded
        @loaded = true
        instance_eval(&@defn)
      end
    end

    # The states hash for this lexer.
    # @see state
    def self.states
      @states ||= {}
    end

    def self.state_definitions
      @state_definitions ||= InheritableHash.new(superclass.state_definitions)
    end
    @state_definitions = {}

    def self.replace_state(name, new_defn)
      states[name] = nil
      state_definitions[name] = new_defn
    end

    # The routines to run at the beginning of a fresh lex.
    # @see start
    def self.start_procs
      @start_procs ||= InheritableList.new(superclass.start_procs)
    end
    @start_procs = []

    # Specify an action to be run every fresh lex.
    #
    # @example
    #   start { puts "I'm lexing a new string!" }
    def self.start(&b)
      start_procs << b
    end

    # Define a new state for this lexer with the given name.
    # The block will be evaluated in the context of a {StateDSL}.
    def self.state(name, &b)
      name = name.to_s
      state_definitions[name] = StateDSL.new(name, &b)
    end

    def self.prepend(name, &b)
      name = name.to_s
      dsl = state_definitions[name] or raise "no such state #{name.inspect}"
      replace_state(name, dsl.prepended(&b))
    end

    def self.append(state, &b)
      name = name.to_s
      dsl = state_definitions[name] or raise "no such state #{name.inspect}"
      replace_state(name, dsl.appended(&b))
    end

    # @private
    def self.get_state(name)
      return name if name.is_a? State

      name = name.to_s

      states[name] ||= begin
        defn = state_definitions[name] or raise "unknown state: #{name.inspect}"
        defn.to_state(self)
      end
    end

    # @private
    def get_state(state_name)
      self.class.get_state(state_name)
    end

    # The state stack.  This is initially the single state `[:root]`.
    # It is an error for this stack to be empty.
    # @see #state
    def stack
      @stack ||= [get_state(:root)]
    end

    # The current state - i.e. one on top of the state stack.
    #
    # NB: if the state stack is empty, this will throw an error rather
    # than returning nil.
    def state
      stack.last or raise 'empty stack!'
    end

    # reset this lexer to its initial state.  This runs all of the
    # start_procs.
    def reset!
      @stack = nil
      @current_stream = nil

      self.class.start_procs.each do |pr|
        instance_eval(&pr)
      end
    end

    # This implements the lexer protocol, by yielding [token, value] pairs.
    #
    # The process for lexing works as follows, until the stream is empty:
    #
    # 1. We look at the state on top of the stack (which by default is
    #    `[:root]`).
    # 2. Each rule in that state is tried until one is successful.  If one
    #    is found, that rule's callback is evaluated - which may yield
    #    tokens and manipulate the state stack.  Otherwise, one character
    #    is consumed with an `'Error'` token, and we continue at (1.)
    #
    # @see #step #step (where (2.) is implemented)
    def stream_tokens(str, &b)
      stream = StringScanner.new(str)

      @current_stream = stream
      @output_stream  = b

      until stream.eos?
        debug { "lexer: #{self.class.tag}" }
        debug { "stack: #{stack.map(&:name).inspect}" }
        debug { "stream: #{stream.peek(20).inspect}" }
        success = step(get_state(state), stream, &b)

        if !success
          debug { "    no match, yielding Error" }
          b.call(Token::Tokens::Error, stream.getch)
        end
      end
    end

    # Runs one step of the lex.  Rules in the current state are tried
    # until one matches, at which point its callback is called.
    #
    # @return true if a rule was tried successfully
    # @return false otherwise.
    def step(state, stream, &b)
      state.rules.each do |rule|
        case rule
        when Rule
          next if rule.beginning_of_line? && !stream.beginning_of_line?
          debug { "  trying #{rule.inspect}" }
          
          if stream.skip(rule.re)
            debug { "    got #{stream[0].inspect}" }

            # with_output_stream(b) do
              @group_count = 0
              instance_exec(stream, &rule.callback)
            # end

            return true
          end
        when State
          debug { "  entering mixin #{rule.name}" }
          return true if step(rule, stream, &b)
          debug { "  exiting  mixin #{rule.name}" }
        end
      end

      false
    end

    # @private
    def run_callback(stream, callback, &output_stream)
      with_output_stream(output_stream) do
        @group_count = 0
        instance_exec(stream, &callback)
      end
    end

    # The number of successive scans permitted without consuming
    # the input stream.  If this is exceeded, the match fails.
    MAX_NULL_SCANS = 5

    # @private
    def run_rule(rule, scanner)
      # XXX HACK XXX
      # StringScanner's implementation of ^ is b0rken.
      # see http://bugs.ruby-lang.org/issues/7092
      # TODO: this doesn't cover cases like /(a|^b)/, but it's
      # the most common, for now...
      return false if rule.beginning_of_line? && !scanner.beginning_of_line?

      size = scanner.skip(rule.re) or return false

      if size.zero?
        @null_steps ||= 0
        @null_steps += 1
        if @null_steps >= MAX_NULL_SCANS
          debug { "    too many scans without consuming the string!" }
          return false
        end
      else
        @null_steps = 0
      end

      true
    end

    # Yield a token.
    #
    # @param tok
    #   the token type
    # @param val
    #   (optional) the string value to yield.  If absent, this defaults
    #   to the entire last match.
    def token(tok, val=@current_stream[0])
      yield_token(tok, val)
    end

    # Yield a token with the next matched group.  Subsequent calls
    # to this method will yield subsequent groups.
    def group(tok)
      yield_token(tok, @current_stream[@group_count += 1])
    end

    def groups(*tokens)
      tokens.each_with_index do |tok, i|
        yield_token(tok, @current_stream[i+1])
      end
    end

    # Delegate the lex to another lexer.  The #lex method will be called
    # with `:continue` set to true, so that #reset! will not be called.
    # In this way, a single lexer can be repeatedly delegated to while
    # maintaining its own internal state stack.
    #
    # @param [#lex] lexer
    #   The lexer or lexer class to delegate to
    # @param [String] text
    #   The text to delegate.  This defaults to the last matched string.
    def delegate(lexer, text=nil)
      debug { "    delegating to #{lexer.inspect}" }
      text ||= @current_stream[0]

      lexer.lex(text, :continue => true) do |tok, val|
        debug { "    delegated token: #{tok.inspect}, #{val.inspect}" }
        yield_token(tok, val)
      end
    end

    def recurse(text=nil)
      delegate(self.class, text)
    end

    # Push a state onto the stack.  If no state name is given and you've
    # passed a block, a state will be dynamically created using the
    # {StateDSL}.
    def push(state_name=nil, &b)
      push_state = if state_name
        get_state(state_name)
      elsif block_given?
        StateDSL.new(b.inspect, &b).to_state(self.class)
      else
        # use the top of the stack by default
        self.state
      end

      debug { "    pushing #{push_state.name}" }
      stack.push(push_state)
    end

    # Pop the state stack.  If a number is passed in, it will be popped
    # that number of times.
    def pop!(times=1)
      raise 'empty stack!' if stack.empty?

      debug { "    popping stack: #{times}" }

      stack.pop(times)

      nil
    end

    # replace the head of the stack with the given state
    def goto(state_name)
      raise 'empty stack!' if stack.empty?
      stack[-1] = get_state(state_name)
    end

    # reset the stack back to `[:root]`.
    def reset_stack
      debug { '    resetting stack' }
      stack.clear
      stack.push get_state(:root)
    end

    # Check if `state_name` is in the state stack.
    def in_state?(state_name)
      state_name = state_name.to_s
      stack.any? do |state|
        state.name == state_name.to_s
      end
    end

    # Check if `state_name` is the state on top of the state stack.
    def state?(state_name)
      state_name.to_s == state.name
    end

  private
    def with_output_stream(output_stream, &b)
      old_output_stream = @output_stream
      @output_stream = Enumerator::Yielder.new do |tok, val|
        debug { "    yielding #{tok.qualname}, #{val.inspect}" }
        output_stream.call(tok, val)
      end

      yield

    ensure
      @output_stream = old_output_stream
    end

    def yield_token(tok, val)
      return if val.nil? || val.empty?
      @output_stream.call(tok, val)
    end
  end
end
