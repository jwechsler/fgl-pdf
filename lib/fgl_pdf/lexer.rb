# frozen_string_literal: true

module FglPdf
  # Streaming FGL tokenizer.
  #
  # #feed returns the tokens completed so far and buffers anything incomplete (a command
  # split across TCP chunks, a graphics payload still arriving, a text run whose end has
  # not been seen yet). A token is only emitted once enough bytes have arrived to make
  # the same decision the lexer would make with the whole stream, so the token sequence
  # is independent of how the input is chunked.
  #
  # Token kinds:
  #   :command     name, args (raw strings), plus +data+ (CTR/RTJ field text, barcode or
  #                2D data, delimiters removed) or +payload+ (<G#>/<g#> graphics bytes)
  #   :text        +text+ = the bytes (Windows-1252)
  #   :newline     CR
  #   :print       FF (name 'p') or 0x1D (name 'q')
  #   :esc_block   ESC … ESC; +children+ = tokens lexed from the inner bytes
  #   :transparent <t> … <n> (content dropped)
  #   :ignored     LF, <FGL> prefixes, and stray <n>
  # Every token carries +raw+, its exact source bytes.
  class Lexer
    Token = Struct.new(:kind, :name, :args, :raw, :text, :data, :payload, :children, :error,
                       keyword_init: true)

    ESC = 0x1B
    CR = 0x0D
    LF = 0x0A
    FF = 0x0C
    GS = 0x1D
    LT = 0x3C # <
    GT = 0x3E # >

    TEXT_STOP = [LT, CR, LF, FF, GS, ESC].freeze
    CMD_STOP = [LT, CR, LF, FF, ESC].freeze
    MAX_COMMAND = 256  # longest <…> accepted as a command
    MAX_FIELD = 4096   # longest delimited field (~text~, barcode data, {2D data})

    # Command names that are not "leading letters + numeric args".
    EXACT_NAMES = (1..9).flat_map { |i| ["s#{i}", "S#{i}"] }.push('P1', 'P2').freeze

    # <aB#>: barcode type letter, optional X (3:1 ratio), P(icket)/L(adder).
    BARCODE_NAME = /\A([UEFNCOuefnco])(X?)([PL])\z/
    TWO_D_NAMES = %w[QR PDF DTM AZ].freeze
    FIELD_NAMES = %w[CTR RTJ].freeze

    def initialize
      @buf = String.new(encoding: Encoding::BINARY)
    end

    def feed(bytes)
      @buf << bytes.b
      drain(final: false)
    end

    # Ends the stream: incomplete constructs become text / truncated tokens.
    def flush
      drain(final: true)
    end

    def pending_bytes
      @buf.dup
    end

    def pending_bytesize
      @buf.bytesize
    end

    def reset!
      @buf = String.new(encoding: Encoding::BINARY)
    end

    # Splits "RC10,230.0" into ["RC", ["10", "230.0"]].
    def self.split_command(body)
      return [body, []] if EXACT_NAMES.include?(body)

      m = body.match(/\A([A-Za-z]+)(.*)\z/m)
      return ['', [body]] unless m

      rest = m[2].strip
      [m[1], rest.empty? ? [] : rest.split(',', -1).map(&:strip)]
    end

    # Lexes all of +bytes+ at once (no buffering).
    def self.tokenize(bytes)
      lexer = new
      lexer.feed(bytes) + lexer.flush
    end

    private

    def drain(final:)
      tokens = []
      pos = 0
      while pos < @buf.bytesize
        tok, npos = lex_one(@buf, pos, final, in_esc: false)
        break unless tok

        tokens << tok
        pos = npos
      end
      @buf = @buf.byteslice(pos..) || String.new(encoding: Encoding::BINARY)
      tokens
    end

    # Returns [token, next_pos], or nil when more bytes are needed.
    def lex_one(buf, pos, final, in_esc:)
      case buf.getbyte(pos)
      when ESC then in_esc ? nil : lex_esc(buf, pos, final)
      when CR then [tok(:newline, buf, pos, 1), pos + 1]
      when LF then [tok(:ignored, buf, pos, 1), pos + 1]
      when FF then [tok(:print, buf, pos, 1, name: 'p'), pos + 1]
      when GS then [tok(:print, buf, pos, 1, name: 'q'), pos + 1]
      when LT then lex_command(buf, pos, final)
      else lex_text(buf, pos, final)
      end
    end

    def tok(kind, buf, pos, len, **attrs)
      Token.new(kind: kind, raw: buf.byteslice(pos, len), **attrs)
    end

    def lex_text(buf, pos, final, first_len = 0)
      j = pos + first_len
      j += 1 while j < buf.bytesize && !TEXT_STOP.include?(buf.getbyte(j))
      return nil if j >= buf.bytesize && !final

      bytes = buf.byteslice(pos, j - pos)
      [Token.new(kind: :text, raw: bytes, text: bytes), j]
    end

    # A '<' that does not start a command is a one-byte text token.
    def lone_lt(buf, pos)
      [Token.new(kind: :text, raw: buf.byteslice(pos, 1), text: buf.byteslice(pos, 1)), pos + 1]
    end

    def lex_command(buf, pos, final)
      j = pos + 1
      while j < buf.bytesize
        b = buf.getbyte(j)
        break if b == GT
        return lone_lt(buf, pos) if CMD_STOP.include?(b) || j - pos > MAX_COMMAND

        j += 1
      end
      return (final ? lone_lt(buf, pos) : nil) if j >= buf.bytesize

      body = buf.byteslice(pos + 1, j - pos - 1)
      name, args = self.class.split_command(body)
      finish_command(buf, pos, j + 1, name, args, final)
    end

    def finish_command(buf, pos, after, name, args, final)
      case name
      when 'G' then with_payload(buf, pos, after, name, args, final, count_arg(args, 7))
      when 'g' then with_payload(buf, pos, after, name, args, final, count_arg(args, 0))
      when 't' then transparent(buf, pos, after, final)
      when 'FGL' then [Token.new(kind: :ignored, name: name, args: args, raw: buf.byteslice(pos, after - pos)), after]
      when *FIELD_NAMES then with_delimited(buf, pos, after, name, args, final) { |b, start| tilde_field(b, start) }
      when *TWO_D_NAMES then with_delimited(buf, pos, after, name, args, final) { |b, start| brace_field(b, start) }
      when BARCODE_NAME
        type = Regexp.last_match(1).upcase
        with_delimited(buf, pos, after, name, args, final) { |b, start| barcode_field(type, b, start) }
      else command(buf, pos, after, name, args)
      end
    end

    def command(buf, pos, after, name, args, **attrs)
      [Token.new(kind: :command, name: name, args: args, raw: buf.byteslice(pos, after - pos), **attrs), after]
    end

    def count_arg(args, default)
      return default if args.empty? || args.first.empty?

      Integer(args.first, 10)
    rescue ArgumentError
      default
    end

    def with_payload(buf, pos, after, name, args, final, count)
      available = buf.bytesize - after
      if available < count
        return nil unless final

        return command(buf, pos, buf.bytesize, name, args, payload: buf.byteslice(after, available),
                                                           error: :truncated)
      end
      command(buf, pos, after + count, name, args, payload: buf.byteslice(after, count))
    end

    def transparent(buf, pos, after, final)
      close = buf.index('<n>', after)
      if close.nil?
        return nil unless final

        close = buf.bytesize - 3
      end
      stop = close + 3
      [Token.new(kind: :transparent, name: 't', args: [], raw: buf.byteslice(pos, stop - pos)), stop]
    end

    # The block returns [data, end_pos] (field found), :none (no field follows) or :more.
    def with_delimited(buf, pos, after, name, args, final)
      return (final ? command(buf, pos, after, name, args) : nil) if after >= buf.bytesize

      result = yield(buf, after)
      case result
      when :none then command(buf, pos, after, name, args)
      when :more then final ? command(buf, pos, after, name, args, error: :unterminated) : nil
      else
        data, stop = result
        command(buf, pos, stop, name, args, data: data)
      end
    end

    def tilde_field(buf, start)
      return :none unless buf.getbyte(start) == 0x7E

      closing_field(buf, start + 1, '~')
    end

    def brace_field(buf, start)
      return :none unless buf.getbyte(start) == 0x7B

      closing_field(buf, start + 1, '}')
    end

    # Finds +close+ after +start+; returns [content, pos after close], :more or :none.
    def closing_field(buf, start, close)
      idx = buf.index(close, start)
      if idx.nil? || idx - start > MAX_FIELD
        return buf.bytesize - start > MAX_FIELD ? :none : :more
      end

      [buf.byteslice(start, idx - start), idx + 1]
    end

    def barcode_field(type, buf, start)
      case type
      when 'N' then simple_delimited(buf, start, '*')
      when 'F' then simple_delimited(buf, start, ':')
      when 'O' then simple_delimited(buf, start, '^')
      when 'C' then codabar_field(buf, start)
      else upc_field(buf, start)
      end
    end

    def simple_delimited(buf, start, delim)
      return :none unless buf.getbyte(start) == delim.ord

      closing_field(buf, start + 1, delim)
    end

    # Codabar data runs from a start char A–D to the next stop char A–D. Both are kept:
    # they are part of the symbol (Symbology.codabar encodes them).
    def codabar_field(buf, start)
      return :none unless 'ABCDabcd'.include?(buf.byteslice(start, 1))

      j = start + 1
      while j < buf.bytesize
        return [buf.byteslice(start, j - start + 1), j + 1] if 'ABCDabcd'.include?(buf.byteslice(j, 1))
        return :none if TEXT_STOP.include?(buf.getbyte(j)) || j - start > MAX_FIELD

        j += 1
      end
      :more
    end

    # UPC/EAN: optional parity/number-system digit, then J…K…L (markers removed).
    # A bare run of digits is also accepted.
    def upc_field(buf, start)
      j = start
      j += 1 while j < buf.bytesize && digit?(buf.getbyte(j))
      return :more if j >= buf.bytesize
      unless buf.getbyte(j) == 'J'.ord && j - start <= 1
        return j > start ? [buf.byteslice(start, j - start), j] : :none
      end

      close = buf.index('L', j)
      return (buf.bytesize - j > 64 ? :none : :more) unless close
      return :none if close - j > 64

      [buf.byteslice(start, close - start).delete('JK'), close + 1]
    end

    def digit?(byte)
      byte.between?(0x30, 0x39)
    end

    # ESC … ESC. Inner tokens are lexed normally so graphics payloads (which may contain
    # ESC) are length-honored. "ESC c" is the clear-downloads command, not a block.
    def lex_esc(buf, pos, final)
      return (final ? lex_text(buf, pos, final, 1) : nil) if pos + 1 >= buf.bytesize
      if buf.getbyte(pos + 1) == 'c'.ord
        return [Token.new(kind: :command, name: 'ESCc', args: [], raw: buf.byteslice(pos, 2)), pos + 2]
      end

      children = []
      j = pos + 1
      loop do
        if j >= buf.bytesize
          return nil unless final

          return [Token.new(kind: :esc_block, raw: buf.byteslice(pos..), children: children,
                            error: :unterminated), buf.bytesize]
        end
        if buf.getbyte(j) == ESC
          return [Token.new(kind: :esc_block, raw: buf.byteslice(pos, j - pos + 1), children: children), j + 1]
        end

        child, j = lex_one(buf, j, final, in_esc: true)
        return nil unless child

        children << child
      end
    end
  end
end
