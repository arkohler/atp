module ATP
  # Implements the main user API for building and interacting
  # with an abstract test program
  class Flow
    attr_reader :program, :name

    attr_accessor :source_file, :source_line_number, :description

    include ATP::AST::Factories

    CONDITION_KEYS = {
      if_enabled:        :if_enabled,
      if_enable:         :if_enabled,
      enabled:           :if_enabled,
      enable_flag:       :if_enabled,
      enable:            :if_enabled,

      unless_enabled:    :unless_enabled,
      not_enabled:       :unless_enabled,
      disabled:          :unless_enabled,
      disable:           :unless_enabled,
      unless_enable:     :unless_enabled,

      if_failed:         :if_failed,
      unless_passed:     :if_failed,
      failed:            :if_failed,

      if_passed:         :if_passed,
      unless_failed:     :if_passed,
      passed:            :if_passed,

      if_any_failed:     :if_any_failed,
      unless_all_passed: :if_any_failed,

      if_all_failed:     :if_all_failed,
      unless_any_passed: :if_all_failed,

      if_any_passed:     :if_any_passed,
      unless_all_failed: :if_any_passed,

      if_all_passed:     :if_all_passed,
      unless_any_failed: :if_all_passed,

      if_ran:            :if_ran,
      if_executed:       :if_ran,

      unless_ran:        :unless_ran,
      unless_executed:   :unless_ran,

      job:               :if_job,
      jobs:              :if_job,
      if_job:            :if_job,
      if_jobs:           :if_job,

      unless_job:        :unless_job,
      unless_jobs:       :unless_job,

      if_flag:           :if_flag,

      unless_flag:       :unless_flag,

      group:             :group
    }

    CONDITION_NODE_TYPES = CONDITION_KEYS.values.uniq

    def initialize(program, name = nil, options = {})
      name, options = nil, name if name.is_a?(Hash)
      extract_meta!(options)
      @program = program
      @name = name
      @pipeline = [n(:flow, n(:name, name))]
    end

    # @api private
    def marshal_dump
      [@name, @program, Processors::Marshal.new.process(raw)]
    end

    # @api private
    def marshal_load(array)
      @name, @program, raw = array
      @pipeline = [raw]
    end

    # Returns the raw AST
    def raw
      n = nil
      @pipeline.reverse_each do |node|
        if n
          n = node.updated(nil, node.children + [n])
        else
          n = node
        end
      end
      n
    end

    # Returns a processed/optimized AST, this is the one that should be
    # used to build and represent the given test flow
    def ast(options = {})
      options = {
        apply_relationships: true,
        # Supply a unique ID to append to all IDs
        unique_id:           nil,
        # Set to :smt, or :igxl
        optimization:        nil,
        # Adds IDs to all nodes, you would only want to turn this off in a test scenario
        # where you know that you don't need it
        add_ids:             true,
        # When set to true, only one test will be allowed to set a given flag based on its
        # result, additional flags will be inserted to give the same logical result.
        one_flag_per_test:   false,
        optimize_flags:      true
      }.merge(options)
      ###############################################################################
      ## Common pre-processing and validation
      ###############################################################################
      ast = Processors::PreCleaner.new.run(raw)
      Validators::DuplicateIDs.new(self).run(ast)
      Validators::MissingIDs.new(self).run(ast)
      Validators::Jobs.new(self).run(ast)
      # Ensure everything has an ID, this helps later if condition nodes need to be generated
      ast = Processors::AddIDs.new.run(ast) if options[:add_ids]
      ast = Processors::FlowID.new.run(ast, options[:unique_id]) if options[:unique_id]

      ###############################################################################
      ## Optimization for a C-like flow target, e.g. V93K
      ###############################################################################
      if options[:optimization] == :smt
        # This applies all the relationships by setting flags in the referenced test and
        # changing all if_passed/failed type nodes to if_flag type nodes
        ast = Processors::Relationship.new.run(ast) if options[:apply_relationships]
        ast = Processors::Condition.new.run(ast)
        ast = Processors::FlagOptimizer.new.run(ast) if options[:optimize_flags]
        ast = Processors::AdjacentIfCombiner.new.run(ast)

      ###############################################################################
      ## Optimization for a row-based target, e.g. UltraFLEX
      ###############################################################################
      elsif options[:optimization] == :igxl
        # Un-nest everything embedded in else nodes
        ast = Processors::ElseRemover.new.run(ast)
        # Un-nest everything embedded in on_pass/fail nodes except for binning and
        # flag setting
        ast = Processors::OnPassFailRemover.new.run(ast)
        # This applies all the relationships by setting flags in the referenced test and
        # changing all if_passed/failed type nodes to if_flag type nodes
        ast = Processors::Relationship.new.run(ast) if options[:apply_relationships]
        ast = Processors::Condition.new.run(ast)
        ast = Processors::ApplyPostGroupActions.new.run(ast)
        ast = Processors::OneFlagPerTest.new.run(ast) if options[:one_flag_per_test]
        ast = Processors::RedundantConditionRemover.new.run(ast)

      ###############################################################################
      ## Not currently used, more of a test case
      ###############################################################################
      elsif options[:optimization] == :flat
        # Un-nest everything embedded in else nodes
        ast = Processors::ElseRemover.new.run(ast)
        # Un-nest everything embedded in on_pass/fail nodes except for binning and
        # flag setting
        ast = Processors::OnPassFailRemover.new.run(ast)
        ast = Processors::Condition.new.run(ast)
        ast = Processors::Flattener.new.run(ast)

      ###############################################################################
      ## Default Optimization
      ###############################################################################
      else
        ast = Processors::Condition.new.run(ast)
      end

      ###############################################################################
      ## Common cleanup
      ###############################################################################
      # Removes any empty on_pass and on_fail branches
      ast = Processors::EmptyBranchRemover.new.run(ast)
      ast
    end

    # Indicate the that given flags should be considered volatile (can change at any time), which will
    # prevent them from been touched by the optimization algorithms
    def volatile(*flags)
      options = flags.pop if flags.last.is_a?(Hash)
      flags = flags.flatten
      @pipeline[0] = add_volatile_flags(@pipeline[0], flags)
    end

    # Group all tests generated within the given block
    #
    # @example
    #   flow.group "RAM Tests" do
    #     flow.test ...
    #     flow.test ...
    #   end
    def group(name, options = {})
      extract_meta!(options)
      apply_conditions(options) do
        children = [n(:name, name)]
        children << id(options[:id]) if options[:id]
        children << on_fail(options[:on_fail]) if options[:on_fail]
        children << on_pass(options[:on_pass]) if options[:on_pass]
        g = n(:group, *children)
        append_to(g) { yield }
      end
    end

    # Add a test line to the flow
    #
    # @param [String, Symbol] the name of the test
    # @param [Hash] options a hash to describe the test's attributes
    # @option options [Symbol] :id A unique test ID
    # @option options [String] :description A description of what the test does, usually formatted in markdown
    # @option options [Hash] :on_fail What action to take if the test fails, e.g. assign a bin
    # @option options [Hash] :on_pass What action to take if the test passes
    # @option options [Hash] :conditions What conditions must be met to execute the test
    def test(instance, options = {})
      extract_meta!(options)
      apply_conditions(options) do
        # Allows any continue, bin, or soft bin argument passed in at the options top-level to be assumed
        # to be the action to take if the test fails
        if b = options.delete(:bin)
          options[:on_fail] ||= {}
          options[:on_fail][:bin] = b
        end
        if b = options.delete(:bin_description)
          options[:on_fail] ||= {}
          options[:on_fail][:bin_description] = b
        end
        if b = options.delete(:softbin) || b = options.delete(:sbin) || b = options.delete(:soft_bin)
          options[:on_fail] ||= {}
          options[:on_fail][:softbin] = b
        end
        if b = options.delete(:softbin_description) || options.delete(:sbin_description) || options.delete(:soft_bin_description)
          options[:on_fail] ||= {}
          options[:on_fail][:softbin_description] = b
        end
        if options.delete(:continue)
          options[:on_fail] ||= {}
          options[:on_fail][:continue] = true
        end
        if f = options.delete(:flag_pass)
          options[:on_pass] ||= {}
          options[:on_pass][:set_flag] = f
        end
        if f = options.delete(:flag_fail)
          options[:on_fail] ||= {}
          options[:on_fail][:set_flag] = f
        end

        children = [n(:object, instance)]

        name = (options[:name] || options[:tname] || options[:test_name])
        unless name
          [:name, :tname, :test_name].each do |m|
            name ||= instance.respond_to?(m) ? instance.send(m) : nil
          end
        end
        children << n(:name, name) if name

        num = (options[:number] || options[:num] || options[:tnum] || options[:test_number])
        unless num
          [:number, :num, :tnum, :test_number].each do |m|
            num ||= instance.respond_to?(m) ? instance.send(m) : nil
          end
        end
        children << number(num) if num

        children << id(options[:id]) if options[:id]

        if levels = options[:level] || options[:levels]
          levels = [levels] unless levels.is_a?(Array)
          levels.each do |l|
            children << level(l[:name], l[:value], l[:unit] || l[:units])
          end
        end

        if lims = options[:limit] || options[:limits]
          lims = [lims] unless lims.is_a?(Array)
          lims.each do |l|
            children << limit(l[:value], l[:rule], l[:unit] || l[:units])
          end
        end

        if pins = options[:pin] || options[:pins]
          pins = [pins] unless pins.is_a?(Array)
          pins.each do |p|
            if p.is_a?(Hash)
              children << pin(p[:name])
            else
              children << pin(p)
            end
          end
        end

        if pats = options[:pattern] || options[:patterns]
          pats = [pats] unless pats.is_a?(Array)
          pats.each do |p|
            if p.is_a?(Hash)
              children << pattern(p[:name], p[:path])
            else
              children << pattern(p)
            end
          end
        end

        if options[:meta]
          attrs = []
          options[:meta].each { |k, v| attrs << attribute(k, v) }
          children << n(:meta, *attrs)
        end

        if subs = options[:sub_test] || options[:sub_tests]
          subs = [subs] unless subs.is_a?(Array)
          subs.each do |s|
            children << s.updated(:sub_test, nil)
          end
        end

        children << on_fail(options[:on_fail]) if options[:on_fail]
        children << on_pass(options[:on_pass]) if options[:on_pass]

        n(:test, *children)
      end
    end

    # Equivalent to calling test, but returns a sub_test node instead of adding it to the flow.
    #
    # This is a helper to create sub_tests for inclusion in a top-level test node.
    def sub_test(instance, options = {})
      temp = append_to(n0(:temp)) { test(instance, options) }
      temp.children.first.updated(:sub_test, nil)
    end

    def bin(number, options = {})
      if number.is_a?(Hash)
        fail 'The bin number must be passed as the first argument'
      end
      options[:bin_description] ||= options.delete(:description)
      extract_meta!(options)
      apply_conditions(options) do
        options[:type] ||= :fail
        options[:bin] = number
        options[:softbin] ||= options[:soft_bin] || options[:sbin]
        set_result(options[:type], options)
      end
    end

    def pass(number, options = {})
      if number.is_a?(Hash)
        fail 'The bin number must be passed as the first argument'
      end
      options[:type] = :pass
      bin(number, options)
    end

    def cz(instance, cz_setup, options = {})
      extract_meta!(options)
      apply_conditions(options) do
        node = n(:cz, cz_setup)
        append_to(node) { test(instance, options) }
      end
    end
    alias_method :characterize, :cz

    # Append a log message line to the flow
    def log(message, options = {})
      extract_meta!(options)
      apply_conditions(options) do
        n(:log, message.to_s)
      end
    end

    # Enable a flow control variable
    def enable(var, options = {})
      extract_meta!(options)
      apply_conditions(options) do
        n(:enable, var)
      end
    end

    # Disable a flow control variable
    def disable(var, options = {})
      extract_meta!(options)
      apply_conditions(options) do
        n(:disable, var)
      end
    end

    def set_flag(flag)
      extract_meta!(options)
      apply_conditions(options) do
        set_flag_node(flag)
      end
    end

    # Insert explicitly rendered content in to the flow
    def render(str, options = {})
      extract_meta!(options)
      apply_conditions(options) do
        n(:render, str)
      end
    end

    def continue(options = {})
      extract_meta!(options)
      apply_conditions(options) do
        n0(:continue)
      end
    end

    # Execute the given flow in the console
    def run(options = {})
      Formatters::Datalog.run_and_format(ast, options)
      nil
    end

    # Returns true if the test context generated from the supplied options + existing condition
    # wrappers, is different from that which was applied to the previous test.
    def context_changed?(options)
      false
    end

    # Define handlers for all of the flow control block methods, unless a custom one has already
    # been defined above
    CONDITION_KEYS.keys.each do |method|
      define_method method do |*flags, &block|
        if flags.last.is_a?(Hash)
          options = flags.pop
        else
          options = {}
        end
        flags = flags.first if flags.size == 1
        # Legacy option provided by OrigenTesters that permits override of a block enable method by passing
        # an :or option with a true value
        if (CONDITION_KEYS[method] == :if_enabled || CONDITION_KEYS[method] || :unless_enabled) && options[:or]
          block.call
        else
          flow_control_method(CONDITION_KEYS[method], flags, options, &block)
        end
      end unless method_defined?(method)
    end

    private

    def flow_control_method(name, flag, options = {}, &block)
      extract_meta!(options)
      if flag.is_a?(Array)
        if name == :if_passed
          fail 'if_passed only accepts one ID, use if_any_passed or if_all_passed for multiple IDs'
        end
        if name == :if_failed
          fail 'if_failed only accepts one ID, use if_any_failed or if_all_failed for multiple IDs'
        end
      end
      apply_conditions(options) do
        if block
          node = n(name, flag)
          node = append_to(node) { block.call }
        else
          unless options[:then] || options[:else]
            fail "You must supply a :then or :else option when calling #{name} like this!"
          end
          node = n(name, flag)
          if options[:then]
            node = append_to(node) { options[:then].call }
          end
          if options[:else]
            e = n0(:else)
            e = append_to(e) { options[:else].call }
            node = node.updated(nil, node.children + [e])
          end
        end
        node
      end
    end

    def apply_conditions(options, node = nil)
      # Applying the current context, means to append to the same node as the last time, this
      # means that the next node will pick up the exact same condition context as the previous one
      if options[:context] == :current
        node = yield
        @pipeline = @pipeline.map { |parent| Processors::AppendTo.new.run(parent, node, @last_append.id) }
        node
      else
        conditions = extract_conditions(options)
        node = yield

        update_last_append = !condition_node?(node)

        conditions.each do |key, value|
          if key == :group
            node = n(key, n(:name, value.to_s), node)
          else
            node = n(key, value, node)
          end
          if update_last_append
            @last_append = node
            update_last_append = false
          end
        end

        append(node)
        node
      end
    end

    def extract_conditions(options)
      conditions = {}
      options.each do |key, value|
        if CONDITION_KEYS[key]
          options.delete(key)
          key = CONDITION_KEYS[key]
          if conditions[key]
            fail "Multiple values assigned to flow condition #{key}"
          else
            conditions[key] = value
          end
        end
      end
      conditions
    end

    def append(node)
      @last_append = @pipeline.last unless condition_node?(node)
      n = @pipeline.pop
      @pipeline << n.updated(nil, n.children + [node])
      @pipeline.last
    end

    # Append all nodes generated within the given block to the given node
    # instead of the top-level flow node
    def append_to(node)
      @pipeline << node
      yield
      @pipeline.pop
    end

    def condition_node?(node)
      !!CONDITION_KEYS[node.type]
    end

    def extract_meta!(options)
      self.source_file = options.delete(:source_file)
      self.source_line_number = options.delete(:source_line_number)
      self.description = options.delete(:description)
    end

    def id(name)
      n(:id, name)
    end

    def on_fail(options = {})
      if options.is_a?(Proc)
        node = n0(:on_fail)
        append_to(node) { options.call }
      else
        children = []
        if options[:bin] || options[:softbin]
          fail_opts = { bin: options[:bin], softbin: options[:softbin] }
          fail_opts[:bin_description] = options[:bin_description] if options[:bin_description]
          fail_opts[:softbin_description] = options[:softbin_description] if options[:softbin_description]
          children << set_result(:fail, fail_opts)
        end
        if options[:set_run_flag] || options[:set_flag]
          children << set_flag_node(options[:set_run_flag] || options[:set_flag])
        end
        children << n0(:continue) if options[:continue]
        children << render(options[:render]) if options[:render]
        n(:on_fail, *children)
      end
    end

    def on_pass(options = {})
      if options.is_a?(Proc)
        node = n0(:on_pass)
        append_to(node) { options.call }
      else
        children = []
        if options[:bin] || options[:softbin]
          pass_opts = { bin: options[:bin], softbin: options[:softbin] }
          pass_opts[:bin_description] = options[:bin_description] if options[:bin_description]
          pass_opts[:softbin_description] = options[:softbin_description] if options[:softbin_description]
          children << set_result(:pass, pass_opts)
        end
        if options[:set_run_flag] || options[:set_flag]
          children << set_flag_node(options[:set_run_flag] || options[:set_flag])
        end
        children << n0(:continue) if options[:continue]
        children << render(options[:render]) if options[:render]
        n(:on_pass, *children)
      end
    end

    def pattern(name, path = nil)
      if path
        n(:pattern, name, path)
      else
        n(:pattern, name)
      end
    end

    def attribute(name, value)
      n(:attribute, name, value)
    end

    def level(name, value, units = nil)
      if units
        n(:level, name, value, units)
      else
        n(:level, name, value)
      end
    end

    def limit(value, rule, units = nil)
      if units
        n(:limit, value, rule, units)
      else
        n(:limit, value, rule)
      end
    end

    def pin(name)
      n(:pin, name)
    end

    def set_result(type, options = {})
      children = []
      children << type
      if options[:bin] && options[:bin_description]
        children << n(:bin, options[:bin], options[:bin_description])
      else
        children << n(:bin, options[:bin]) if options[:bin]
      end
      if options[:softbin] && options[:softbin_description]
        children << n(:softbin, options[:softbin], options[:softbin_description])
      else
        children << n(:softbin, options[:softbin]) if options[:softbin]
      end
      n(:set_result, *children)
    end

    def number(val)
      n(:number, val.to_i)
    end

    def set_flag_node(flag)
      n(:set_flag, flag)
    end

    # Ensures the flow ast has a volatile node, then adds the
    # given flags to it
    def add_volatile_flags(node, flags)
      name, *nodes = *node
      if nodes[0] && nodes[0].type == :volatile
        v = nodes.shift
      else
        v = n0(:volatile)
      end
      existing = v.children.map { |f| f.type == :flag ? f.value : nil }.compact
      new = []
      flags.each do |flag|
        new << n(:flag, flag) unless existing.include?(flag)
      end
      v = v.updated(nil, v.children + new)
      node.updated(nil, [name, v] + nodes)
    end
  end
end
