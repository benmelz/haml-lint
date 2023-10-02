# frozen_string_literal: true

# rubocop:disable Metrics
module HamlLint::RubyExtraction
  # Extracts "chunks" of the haml file into instances of subclasses of HamlLint::RubyExtraction::BaseChunk.
  #
  # This is the first step of generating Ruby code from a HAML file to then be processed by RuboCop.
  # See HamlLint::RubyExtraction::BaseChunk for more details.
  class ChunkExtractor
    include HamlLint::HamlVisitor

    attr_reader :script_output_prefix

    HAML_PARSER_INSTANCE = if Haml::VERSION >= '5.0.0'
                             ::Haml::Parser.new({})
                           else
                             ::Haml::Parser.new('', {})
                           end

    def initialize(document, script_output_prefix:)
      @document = document
      @script_output_prefix = script_output_prefix
    end

    def extract
      raise 'Already extracted' if @ruby_chunks

      prepare_extract

      visit(@document.tree)
      @ruby_chunks
    end

    # Useful for tests
    def prepare_extract
      @ruby_chunks = []
      @original_haml_lines = @document.source_lines
    end

    def visit_root(_node)
      yield # Collect lines of code from children
    end

    # Visiting lines like `  Some raw text to output`
    def visit_plain(node)
      indent = @original_haml_lines[node.line - 1].index(/\S/)
      @ruby_chunks << PlaceholderMarkerChunk.new(node, 'plain', indent: indent)
    end

    # Visiting lines like `  -# Some commenting!`
    def visit_haml_comment(node)
      # We want to preserve leading whitespace if it exists, but add a leading
      # whitespace if it doesn't exist so that RuboCop's LeadingCommentSpace
      # doesn't complain
      line_index = node.line - 1
      lines = @original_haml_lines[line_index..(line_index + node.text.count("\n"))].dup
      indent = lines.first.index(/\S/)
      # Remove only the -, the # will align with regular code
      #  -# comment
      #  - foo()
      # becomes
      #  # comment
      #  foo()
      lines[0] = lines[0].sub('-', '')

      # Adding a space before the comment if its missing
      # We can't fix those, so make sure not to generate warnings for them.
      lines[0] = lines[0].sub(/\A(\s*)#(\S)/, '\\1# \\2')

      HamlLint::Utils.map_after_first!(lines) do |line|
        # Since the indent/spaces of the extra line comments isn't exactly in the haml,
        # it's not RuboCop's job to fix indentation, so just make a reasonable indentation
        # to avoid offenses.
        ' ' * indent + line.sub(/^\s*/, '# ').rstrip
      end

      # Using Placeholder instead of script because we can't revert back to the
      # exact original comment since multiple syntax lead to the exact same comment.
      @ruby_chunks << HamlCommentChunk.new(node, lines, end_marker_indent: indent)
    end

    # Visiting comments which are output to HTML. Lines looking like
    #   `  / This will be in the HTML source!`
    def visit_comment(node)
      line = @original_haml_lines[node.line - 1]
      indent = line.index(/\S/)
      @ruby_chunks << PlaceholderMarkerChunk.new(node, 'comment', indent: indent)
    end

    # Visit a script which outputs. Lines looking like `  = foo`
    def visit_script(node, &block)
      raw_first_line = @original_haml_lines[node.line - 1]

      # ==, !, !==, &, &== means interpolation (was needed before HAML 2.2... it's still supported)
      # =, !=, &= mean actual ruby code is coming
      # Anything else is interpolation
      # The regex lists the case for Ruby Code. The 3 cases and making sure they are not followed by another = sign

      match = raw_first_line.match(/\A\s*(=|!=|&=)(?!=)/)
      unless match
        # The line doesn't start with a - or a =, this is actually a "plain"
        # that contains interpolation.
        indent = raw_first_line.index(/\S/)
        @ruby_chunks << PlaceholderMarkerChunk.new(node, 'interpolation', indent: indent)
        lines = extract_piped_plain_multilines(node.line - 1)
        add_interpolation_chunks(node, lines.join("\n"), node.line - 1, indent: indent)
        return
      end

      script_prefix = match[1]
      _first_line_offset, lines = extract_raw_ruby_lines(node.script, node.line - 1)
      # We want the actual indentation and prefix for the first line
      first_line = lines[0] = @original_haml_lines[node.line - 1].rstrip
      process_multiline!(first_line)

      lines[0] = lines[0].sub(/(#{script_prefix}[ \t]?)/, '')
      line_indentation = Regexp.last_match(1).size

      raw_code = lines.join("\n")

      if lines[0][/\S/] == '#'
        # a "=" script that only contains a comment... No need for the "HL.out = " prefix,
        # just treat it as comment which will turn into a "-" comment
      else
        lines[0] = HamlLint::Utils.insert_after_indentation(lines[0], script_output_prefix)
      end

      indent_delta = script_output_prefix.size - line_indentation
      HamlLint::Utils.map_after_first!(lines) do |line|
        HamlLint::Utils.indent(line, indent_delta)
      end

      prev_chunk = @ruby_chunks.last
      if prev_chunk.is_a?(ScriptChunk) &&
          prev_chunk.node.type == :script &&
          prev_chunk.node == node.parent
        # When an outputting script is nested under another outputting script,
        # we want to block them from being merged together by rubocop, because
        # this doesn't make sense in HAML.
        # Example:
        #   = if this_is_short
        #     = this_is_short_too
        # Could become (after RuboCop):
        #   HL.out = (HL.out = this_is_short_too if this_is_short)
        # Or in (broken) HAML style:
        #   = this_is_short_too = if this_is_short
        # By forcing this to start a chunk, there will be extra placeholders which
        # blocks rubocop from merging the lines.
        must_start_chunk = true
      elsif script_prefix != '='
        # In the few cases where &= and != are used to start the script,
        # We need to remember and put it back in the final HAML. Fusing scripts together
        # would make that basically impossible. Instead, a script has a "first_output_prefix"
        # field for this specific case
        must_start_chunk = true
      end

      finish_visit_any_script(node, lines, raw_code: raw_code, must_start_chunk: must_start_chunk,
                              first_output_prefix: script_prefix, &block)
    end

    # Visit a script which doesn't output. Lines looking like `  - foo`
    def visit_silent_script(node, &block)
      _first_line_offset, lines = extract_raw_ruby_lines(node.script, node.line - 1)
      # We want the actual indentation and prefix for the first line
      first_line = lines[0] = @original_haml_lines[node.line - 1].rstrip
      process_multiline!(first_line)

      lines[0] = lines[0].sub(/(-[ \t]?)/, '')
      nb_to_deindent = Regexp.last_match(1).size

      HamlLint::Utils.map_after_first!(lines) do |line|
        line.sub(/^ {1,#{nb_to_deindent}}/, '')
      end

      finish_visit_any_script(node, lines, &block)
    end

    # Code common to both silent and outputting scripts
    #
    # raw_code is the code before we do transformations, such as adding the `HL.out = `
    def finish_visit_any_script(node, lines, raw_code: nil, must_start_chunk: false, first_output_prefix: '=')
      raw_code ||= lines.join("\n")
      start_nesting = self.class.start_nesting_after?(raw_code)

      lines = add_following_empty_lines(node, lines)

      my_indent = lines.first.index(/\S/)
      indent_after = indent_after_line_index(node.line - 1 + lines.size - 1) || 0
      indent_after = [my_indent, indent_after].max

      @ruby_chunks << ScriptChunk.new(node, lines,
                                      end_marker_indent: indent_after,
                                      must_start_chunk: must_start_chunk,
                                      previous_chunk: @ruby_chunks.last,
                                      first_output_haml_prefix: first_output_prefix)

      yield

      if start_nesting
        if node.children.empty?
          raise "Line #{node.line} should be followed by indentation. This might actually" \
                " work in Haml, but it's almost a bug that it does. haml-lint cannot process."
        end

        last_child = node.children.last
        if last_child.is_a?(HamlLint::Tree::SilentScriptNode) && last_child.keyword == 'end'
          # This is allowed in Haml 5, gotta handle it!
          # No need for the implicit end chunk since there is an explicit one
        else
          @ruby_chunks << ImplicitEndChunk.new(node, [' ' * my_indent + 'end'],
                                               haml_line_index: @ruby_chunks.last.haml_end_line_index,
                                               end_marker_indent: my_indent)
        end
      end
    end

    # Visiting a tag. Lines looking like `  %div`
    def visit_tag(node)
      indent = @original_haml_lines[node.line - 1].index(/\S/)

      # We don't want to use a block because assignments in a block are local to that block,
      # so the semantics of the extracted ruby would be different from the one generated by
      # Haml. Those differences can make some cops, such as UselessAssignment, have false
      # positives
      code = 'begin'
      @ruby_chunks << AdHocChunk.new(node,
                                     [' ' * indent + code])
      indent += 2

      tag_chunk = PlaceholderMarkerChunk.new(node, 'tag', indent: indent)
      @ruby_chunks << tag_chunk

      current_line_index = visit_tag_attributes(node, indent: indent)
      visit_tag_script(node, line_index: current_line_index, indent: indent)

      yield

      indent -= 2

      if @ruby_chunks.last.equal?(tag_chunk)
        # So there is nothing going "in" the tag, remove the wrapping "begin" and replace the PlaceholderMarkerChunk
        # by one less indented
        @ruby_chunks.pop
        @ruby_chunks.pop
        @ruby_chunks << PlaceholderMarkerChunk.new(node, 'tag', indent: indent)
      else
        @ruby_chunks << AdHocChunk.new(node,
                                       [' ' * indent + 'ensure', ' ' * indent + '  HL.noop', ' ' * indent + 'end'],
                                       haml_line_index: @ruby_chunks.last.haml_end_line_index)
      end
    end

    # (Called manually form visit_tag)
    # Visiting the attributes of a tag. Lots of different examples below in the code.
    # A common syntax is: `%div{style: 'yes_please'}`
    #
    # Returns the new line_index we reached, useful to handle the script that follows
    def visit_tag_attributes(node, indent:)
      final_line_index = node.line - 1
      additional_attributes = node.dynamic_attributes_sources

      attributes_code = additional_attributes.first
      if !attributes_code && node.hash_attributes? && node.dynamic_attributes_sources.empty?
        # No idea why .foo{:bar => 123} doesn't get here, but .foo{:bar => '123'} does...
        # The code we get for the latter is {:bar => '123'}.
        # We normalize it by removing the { } so that it matches wha we normally get
        attributes_code = node.dynamic_attributes_source[:hash][1...-1]
      end

      if attributes_code&.start_with?('{')
        # Looks like the .foo(bar = 123) case. Ignoring.
        attributes_code = nil
      end

      return final_line_index unless attributes_code
      # Attributes have different ways to be given to us:
      #   .foo{bar: 123} => "bar: 123"
      #   .foo{:bar => 123} => ":bar => 123"
      #   .foo{:bar => '123'} => "{:bar => '123'}" # No idea why this is different
      #   .foo(bar = 123) => '{"bar" => 123,}'
      #   .foo{html_attrs('fr-fr')} => html_attrs('fr-fr')
      #
      # The (bar = 123) case is extra painful to autocorrect (so is ignored up there).
      # #raw_ruby_from_haml  will "detect" this case by not finding the code.
      #
      # We wrap the result in a method to have a valid syntax for all 3 ways
      # without having to differentiate them.
      first_line_offset, raw_attributes_lines = extract_raw_tag_attributes_ruby_lines(attributes_code,
                                                                                      node.line - 1)
      return final_line_index unless raw_attributes_lines

      final_line_index += raw_attributes_lines.size - 1

      # Since .foo{bar: 123} => "bar: 123" needs wrapping (Or it would be a syntax error) and
      # .foo{html_attrs('fr-fr')} => html_attrs('fr-fr') doesn't care about being
      # wrapped, we always wrap to place them to a similar offset to how they are in the haml.
      wrap_by = first_line_offset - indent
      if wrap_by < 2
        # Need 2 minimum, for "W(". If we have less, we must indent everything for the difference
        extra_indent = 2 - wrap_by
        HamlLint::Utils.map_after_first!(raw_attributes_lines) do |line|
          HamlLint::Utils.indent(line, extra_indent)
        end
        wrap_by = 2
      end
      raw_attributes_lines = wrap_lines(raw_attributes_lines, wrap_by)
      raw_attributes_lines[0] = ' ' * indent + raw_attributes_lines[0]

      @ruby_chunks << TagAttributesChunk.new(node, raw_attributes_lines,
                                             end_marker_indent: indent,
                                             indent_to_remove: extra_indent)

      final_line_index
    end

    # Visiting the script besides tag. The part to the right of the equal sign of
    # lines looking like `  %div= foo(bar)`
    def visit_tag_script(node, line_index:, indent:)
      return if node.script.nil? || node.script.empty?
      # We ignore scripts which are just a comment
      return if node.script[/\S/] == '#'

      first_line_offset, script_lines = extract_raw_ruby_lines(node.script, line_index)

      if script_lines.nil?
        # This is a string with interpolation after a tag
        # ex: %tag hello #{world}
        # Sadly, the text with interpolation is escaped from the original, but this code
        # needs the original.

        interpolation_original = @document.unescape_interpolation_to_original_cache[node.script]
        line_start_index = @original_haml_lines[node.line - 1].rindex(interpolation_original)
        if line_start_index.nil?
          raw_lines = extract_piped_plain_multilines(node.line - 1)
          equivalent_haml_code = "#{raw_lines.first} #{raw_lines[1..].map(&:lstrip).join(' ')}"
          line_start_index = equivalent_haml_code.rindex(interpolation_original)

          interpolation_original = raw_lines.join("\n")
        end
        add_interpolation_chunks(node, interpolation_original, node.line - 1,
                                 line_start_index: line_start_index, indent: indent)
      else
        script_lines[0] = "#{' ' * indent}#{script_output_prefix}#{script_lines[0]}"
        indent_delta = script_output_prefix.size - first_line_offset + indent
        HamlLint::Utils.map_after_first!(script_lines) do |line|
          HamlLint::Utils.indent(line, indent_delta)
        end

        @ruby_chunks << TagScriptChunk.new(node, script_lines,
                                           haml_line_index: line_index,
                                           end_marker_indent: indent)
      end
    end

    # Visiting a HAML filter. Lines looking like `  :javascript` and the following lines
    # that are nested.
    def visit_filter(node)
      # For unknown reasons, haml doesn't escape interpolations in filters.
      # So we can rely on \n to split / get the number of lines.
      filter_name_indent = @original_haml_lines[node.line - 1].index(/\S/)
      if node.filter_type == 'ruby'
        # The indentation in node.text is normalized, so that at least one line
        # is indented by 0.
        lines = node.text.split("\n")
        lines.map! do |line|
          if line !~ /\S/
            # whitespace or empty
            ''
          else
            ' ' * filter_name_indent + line
          end
        end

        @ruby_chunks << RubyFilterChunk.new(node, lines,
                                            haml_line_index: node.line, # it's one the next line, no need for -1
                                            start_marker_indent: filter_name_indent,
                                            end_marker_indent: filter_name_indent)
      elsif node.text.include?('#')
        name_indentation = ' ' * @original_haml_lines[node.line - 1].index(/\S/)
        # TODO: HAML_LINT_FILTER could be in the string and mess things up
        lines = ["#{name_indentation}#{script_output_prefix}<<~HAML_LINT_FILTER"]
        lines.concat @original_haml_lines[node.line..(node.line + node.text.count("\n") - 1)]
        lines << "#{name_indentation}HAML_LINT_FILTER"
        @ruby_chunks << NonRubyFilterChunk.new(node, lines,
                                               end_marker_indent: filter_name_indent)
      # Those could be interpolation. We treat them as a here-doc, which is nice since we can
      # keep the indentation as-is.
      else
        @ruby_chunks << PlaceholderMarkerChunk.new(node, 'filter', indent: filter_name_indent,
                                                   nb_lines: 1 + node.text.count("\n"))
      end
    end

    # Adds chunks for the interpolation within the given code
    def add_interpolation_chunks(node, code, haml_line_index, indent:, line_start_index: 0)
      HamlLint::Utils.handle_interpolation_with_indexes(code) do |scanner, line_index, line_char_index|
        escapes = scanner[2].size
        next if escapes.odd?
        char = scanner[3] # '{', '@' or '$'
        if Gem::Version.new(Haml::VERSION) >= Gem::Version.new('5') && (char != '{')
          # Before Haml 5, scanner didn't have a scanner[3], it only handled `#{}`
          next
        end

        line_start_char_index = line_char_index
        line_start_char_index += line_start_index if line_index == 0
        code_start_char_index = scanner.charpos

        # This moves the scanner
        Haml::Util.balance(scanner, '{', '}', 1)

        # Need to manually get the code now that we have positions so that all whitespace is present,
        # because Haml::Util.balance does a strip...
        interpolated_code = code[code_start_char_index...scanner.charpos - 1]

        if interpolated_code.include?("\n")
          # We can't correct multiline interpolation.
          # Finding meaningful code to generate and then transfer back is pretty complex

          # Since we can't fix it, strip around the code to reduce RuboCop lints that we won't be able to fix.
          interpolated_code = interpolated_code.strip
          interpolated_code = "#{' ' * indent}#{script_output_prefix}#{interpolated_code}"

          placeholder_code = interpolated_code.gsub(/\s*\n\s*/, ' ').rstrip
          unless parse_ruby(placeholder_code)
            placeholder_code = interpolated_code.gsub(/\s*\n\s*/, '; ').rstrip
          end
          @ruby_chunks << AdHocChunk.new(node, [placeholder_code],
                                         haml_line_index: haml_line_index + line_index)
        else
          interpolated_code = "#{' ' * indent}#{script_output_prefix}#{interpolated_code}"
          @ruby_chunks << InterpolationChunk.new(node, [interpolated_code],
                                                 haml_line_index: haml_line_index + line_index,
                                                 start_char_index: line_start_char_index,
                                                 end_marker_indent: indent)
        end
      end
    end

    def process_multiline!(line)
      if HAML_PARSER_INSTANCE.send(:is_multiline?, line)
        line.chop!.rstrip!
        true
      else
        false
      end
    end

    def process_plain_multiline!(line)
      if line&.end_with?(' |')
        line[-2..] = ''
        true
      else
        false
      end
    end

    # Returns the raw lines from the haml for the given index.
    # Multiple lines are returned when a line ends with a comma as that is the only
    # time HAMLs allows Ruby lines to be split.

    # Haml's line-splitting rules (allowed after comma in scripts and attributes) are handled
    # at the parser level, so Haml doesn't provide the code as it is actually formatted in the Haml
    # file. #raw_ruby_from_haml extracts the ruby code as it is exactly in the Haml file.
    # The first and last lines may not be the complete lines from the Haml, only the Ruby parts
    # and the indentation between the first and last list.

    # HAML transforms the ruby code in many ways as it parses a document. Often removing lines and/or
    # indentation. This is quite annoying for us since we want the exact layout of the code to analyze it.
    #
    # This function receives the code as haml provides it and the line where it starts. It returns
    # the actual code as it is in the haml file, keeping breaks and indentation for the following lines.
    # In addition, the start position of the code in the first line.
    #
    # The rules for handling multiline code in HAML are as follow:
    # * if the line being processed ends with a space and a pipe, then append to the line (without
    #   newlines) every following lines that also end with a space and a pipe. This means the last line of
    #   the "block" also needs a pipe at the end.
    # * after processing the pipes, when dealing with ruby code (and not in tag attributes' hash), if the line
    #   (which maybe span across multiple lines) ends with a comma, add the next line to the current piece of code.
    #
    # @return [first_line_offset, ruby_lines]
    def extract_raw_ruby_lines(haml_processed_ruby_code, first_line_index)
      haml_processed_ruby_code = haml_processed_ruby_code.strip
      first_line = @original_haml_lines[first_line_index]

      char_index = first_line.index(haml_processed_ruby_code)

      if char_index
        return [char_index, [haml_processed_ruby_code]]
      end

      cur_line_index = first_line_index
      cur_line = first_line.rstrip
      lines = []

      # The pipes must also be on the last line of the multi-line section
      while cur_line && process_multiline!(cur_line)
        lines << cur_line
        cur_line_index += 1
        cur_line = @original_haml_lines[cur_line_index].rstrip
      end

      if lines.empty?
        lines << cur_line
      else
        # The pipes must also be on the last line of the multi-line section. So cur_line is not the next line.
        # We want to go back to check for commas
        cur_line_index -= 1
        cur_line = lines.last
      end

      while HAML_PARSER_INSTANCE.send(:is_ruby_multiline?, cur_line)
        cur_line_index += 1
        cur_line = @original_haml_lines[cur_line_index].rstrip
        lines << cur_line
      end

      joined_lines = lines.join("\n")

      if haml_processed_ruby_code.include?("\n")
        haml_processed_ruby_code = haml_processed_ruby_code.gsub("\n", ' ')
      end

      haml_processed_ruby_code.split(/[, ]/)

      regexp = HamlLint::Utils.regexp_for_parts(haml_processed_ruby_code.split(/,\s*|\s+/), '(?:,\\s*|\\s+)')

      match = joined_lines.match(regexp)
      # This can happen when pipes are used as marker for multiline parts, and when tag attributes change lines
      # without ending by a comma. This is quite a can of worm and is probably not too frequent, so for now,
      # these cases are not supported.
      return if match.nil?

      raw_ruby = match[0]
      ruby_lines = raw_ruby.split("\n")
      first_line_offset = match.begin(0)

      [first_line_offset, ruby_lines]
    end

    def extract_piped_plain_multilines(first_line_index)
      lines = []

      cur_line = @original_haml_lines[first_line_index].rstrip
      cur_line_index = first_line_index

      # The pipes must also be on the last line of the multi-line section
      while cur_line && process_plain_multiline!(cur_line)
        lines << cur_line
        cur_line_index += 1
        cur_line = @original_haml_lines[cur_line_index].rstrip
      end

      if lines.empty?
        lines << cur_line
      end
      lines
    end

    # Tag attributes actually handle multiline differently than scripts.
    # The basic system basically keeps considering more lines until it meets the closing braces, but still
    # processes pipes too (same as extract_raw_ruby_lines).
    def extract_raw_tag_attributes_ruby_lines(haml_processed_ruby_code, first_line_index)
      haml_processed_ruby_code = haml_processed_ruby_code.strip
      first_line = @original_haml_lines[first_line_index]

      char_index = first_line.index(haml_processed_ruby_code)

      if char_index
        return [char_index, [haml_processed_ruby_code]]
      end

      min_non_white_chars_to_add = haml_processed_ruby_code.scan(/\S/).size

      regexp = HamlLint::Utils.regexp_for_parts(haml_processed_ruby_code.split(/\s+/), '\\s+')

      joined_lines = first_line.rstrip
      process_multiline!(joined_lines)

      cur_line_index = first_line_index + 1
      while @original_haml_lines[cur_line_index] && min_non_white_chars_to_add > 0
        new_line = @original_haml_lines[cur_line_index].rstrip
        process_multiline!(new_line)

        min_non_white_chars_to_add -= new_line.scan(/\S/).size
        joined_lines << "\n"
        joined_lines << new_line
        cur_line_index += 1
      end

      match = joined_lines.match(regexp)

      return if match.nil?

      first_line_offset = match.begin(0)
      raw_ruby = match[0]
      ruby_lines = raw_ruby.split("\n")

      [first_line_offset, ruby_lines]
    end

    def wrap_lines(lines, wrap_depth)
      lines = lines.dup
      wrapping_prefix = 'W' * (wrap_depth - 1) + '('
      lines[0] = wrapping_prefix + lines[0]
      lines[-1] = lines[-1] + ')'
      lines
    end

    # Adds empty lines that follow the lines (Used for scripts), so that
    # RuboCop can receive them too. Some cops are sensitive to empty lines.
    def add_following_empty_lines(node, lines)
      first_line_index = node.line - 1 + lines.size
      extra_lines = []

      extra_lines << '' while HamlLint::Utils.is_blank_line?(@original_haml_lines[first_line_index + extra_lines.size])

      if @original_haml_lines[first_line_index + extra_lines.size].nil?
        # Since we reached the end of the document without finding content,
        # then we don't add those lines.
        return lines
      end

      lines + extra_lines
    end

    def parse_ruby(source)
      @ruby_parser ||= HamlLint::RubyParser.new
      @ruby_parser.parse(source)
    end

    def indent_after_line_index(line_index)
      (line_index + 1..@original_haml_lines.size - 1).each do |i|
        indent = @original_haml_lines[i].index(/\S/)
        return indent if indent
      end
      nil
    end

    def self.start_nesting_after?(code)
      anonymous_block?(code) || start_block_keyword?(code)
    end

    def self.anonymous_block?(code)
      # Don't start with a comment and end with a `do`
      # Definetly not perfect for the comment handling, but otherwise a more advanced parsing system is needed.
      # Move the comment to its own line if it's annoying.
      code !~ /\A\s*#/ &&
        code =~ /\bdo\s*(\|[^|]*\|\s*)?(#.*)?\z/
    end

    START_BLOCK_KEYWORDS = %w[if unless case begin for until while].freeze
    def self.start_block_keyword?(code)
      START_BLOCK_KEYWORDS.include?(block_keyword(code))
    end

    LOOP_KEYWORDS = %w[for until while].freeze
    def self.block_keyword(code)
      # Need to handle 'for'/'while' since regex stolen from HAML parser doesn't
      if (keyword = code[/\A\s*([^\s]+)\s+/, 1]) && LOOP_KEYWORDS.include?(keyword)
        return keyword
      end

      return unless keyword = code.scan(Haml::Parser::BLOCK_KEYWORD_REGEX)[0]
      keyword[0] || keyword[1]
    end
  end
end

# rubocop:enable Metrics