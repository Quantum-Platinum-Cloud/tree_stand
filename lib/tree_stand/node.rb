module TreeStand
  # Wrapper around a TreeSitter node and provides convient
  # methods that are missing on the original node. This class
  # overrides the `method_missing` method to delegate to a nodes
  # named children.
  class Node
    extend Forwardable
    include Enumerable

    # @!method type
    #   @return [Symbol] the type of the node in the tree-sitter grammar.
    # @!method error?
    #   @return [bool] true if the node is an error node.
    def_delegators(
      :@ts_node,
      :type,
      :error?,
    )

    # @return [TreeStand::Tree]
    attr_reader :tree
    # @return [TreeSitter::Node]
    attr_reader :ts_node

    # @!method to_a
    #   @example
    #     node.text # => "3 * 4"
    #     node.to_a.map(&:text) # => ["3", "*", "4"]
    #     node.children.map(&:text) # => ["3", "*", "4"]
    #   @return [Array<TreeStand::Node>]
    alias_method :children, :to_a

    # @api private
    def initialize(tree, ts_node)
      @tree = tree
      @ts_node = ts_node
      @fields = @ts_node.each_field.to_a.map(&:first)
    end

    # TreeSitter uses a `TreeSitter::Cursor` to iterate over matches by calling
    # `curser#next_match` repeatedly until it returns `nil`.
    #
    # This method does all of that for you and collects all of the matches into
    # an array and each corresponding capture into a hash.
    #
    # @example
    #   # This will return a match for each identifier nodes in the tree.
    #   tree_matches = tree.query(<<~QUERY)
    #     (identifier) @identifier
    #   QUERY
    #
    #   # It is equivalent to:
    #   tree.root_node.query(<<~QUERY)
    #     (identifier) @identifier
    #   QUERY
    #
    # @param query_string [String]
    # @return [Array<Hash<String, TreeStand::Node>>]
    def query(query_string)
      ts_query = TreeSitter::Query.new(@tree.parser.ts_language, query_string)
      ts_cursor = TreeSitter::QueryCursor.exec(ts_query, ts_node)
      matches = []
      while ts_match = ts_cursor.next_match
        captures = {}

        ts_match.captures.each do |ts_capture|
          capture_name = ts_query.capture_name_for_id(ts_capture.index)
          captures[capture_name] = TreeStand::Node.new(@tree, ts_capture.node)
        end

        matches << captures
      end
      matches
    end

    # Returns the first captured node that matches the query string or nil if
    # there was no captured node.
    #
    # @example Find the first identifier node.
    #   identifier_node = tree.root_node.find_node("(identifier) @identifier")
    #
    # @see #find_node!
    # @see #query
    # @param query_string [String]
    # @return [TreeStand::Node, nil]
    def find_node(query_string)
      query(query_string).first&.values&.first
    end

    # Like {#find_node}, except that if no node is found, raises an
    # {TreeStand::NodeNotFound} error.
    #
    # @see #find_node
    # @param query_string [String]
    # @return [TreeStand::Node]
    # @raise [TreeStand::NodeNotFound]
    def find_node!(query_string)
      find_node(query_string) || raise(TreeStand::NodeNotFound)
    end

    # @return [TreeStand::Range]
    def range
      TreeStand::Range.new(
        start_byte: @ts_node.start_byte,
        end_byte: @ts_node.end_byte,
        start_point: @ts_node.start_point,
        end_point: @ts_node.end_point,
      )
    end

    # Node includes enumerable so that you can iterate over the child nodes.
    # @example
    #   node.text # => "3 * 4"
    #
    # @example Iterate over the child nodes
    #   node.each do |child|
    #     print child.text
    #   end
    #   # prints: 3*4
    #
    # @example Enumerable methods
    #   node.map(&:text) # => ["3", "*", "4"]
    #
    # @yieldparam child [TreeStand::Node]
    # @return [Enumerator]
    def each(&block)
      Enumerator.new do |yielder|
        @ts_node.each do |child|
          yielder << TreeStand::Node.new(@tree, child)
        end
      end.each(&block)
    end

    # (see TreeStand::Visitors::TreeWalker)
    # Backed by {TreeStand::Visitors::TreeWalker}.
    #
    # @example Check the subtree for error nodes
    #   node.walk.any? { |node| node.type == :error }
    #
    # @yieldparam node [TreeStand::Node]
    # @return [Enumerator]
    #
    # @see TreeStand::Visitors::TreeWalker
    def walk(&block)
      Enumerator.new do |yielder|
        Visitors::TreeWalker.new(self) do |child|
          yielder << child
        end.visit
      end.each(&block)
    end

    # @example
    #   node.text # => "4"
    #   node.parent.text # => "3 * 4"
    #   node.parent.parent.text # => "1 + 3 * 4"
    # @return [TreeStand::Node]
    def parent
      TreeStand::Node.new(@tree, @ts_node.parent)
    end

    # A convience method for getting the text of the node. Each {TreeStand::Node}
    # wraps the parent {TreeStand::Tree #tree} and has access to the source document.
    # @return [String]
    def text
      @tree.document[@ts_node.start_byte...@ts_node.end_byte]
    end

    # This class overrides the `method_missing` method to delegate to the
    # node's named children.
    # @example
    #   node.text          # => "3 * 4"
    #
    #   node.left.text     # => "3"
    #   node.operator.text # => "*"
    #   node.right.text    # => "4"
    #   node.operand       # => NoMethodError
    # @overload method_missing(field_name)
    #   @param name [Symbol, String]
    #   @return [TreeStand::Node] child node for the given field name
    #   @raise [NoMethodError] Raised if the node does not have child with name `field_name`
    #
    # @overload method_missing(method_name, *args, &block)
    #   @raise [NoMethodError]
    def method_missing(method, *args, &block)
      return super unless @fields.include?(method.to_s)
      TreeStand::Node.new(@tree, @ts_node.public_send(method, *args, &block))
    end

    # @param other [Object]
    # @return [bool]
    def ==(other)
      return false unless other.is_a?(TreeStand::Node)

      range == other.range &&
        type == other.type &&
        text == other.text
    end

    # (see TreeStand::Utils::Printer)
    # Backed by {TreeStand::Utils::Printer}.
    #
    # @param pp [PP]
    # @return [void]
    #
    # @see TreeStand::Utils::Printer
    def pretty_print(pp)
      Utils::Printer.new(ralign: 80).print(self, io: pp.output)
    end
  end
end
