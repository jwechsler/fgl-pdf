# frozen_string_literal: true

require_relative 'config'
require_relative 'geometry'
require_relative 'fonts'
require_relative 'ticket'
require_relative 'bitmap'
require_relative 'bitmap_decoders'
require_relative 'counter'
require_relative 'lexer'
require_relative 'logo_store'
require_relative 'state'

module FglPdf
  class Error < StandardError; end
  # Raised in strict mode for unknown or malformed commands.
  class StrictError < Error; end

  # Executes FGL tokens, building one Ticket (display list) per print command.
  #
  # Interpretation choices for points the FGL guide leaves open are documented inline;
  # look for "Assumption:".
  class Interpreter
    # Hardware, status and configuration commands with no effect on the printed image.
    IGNORED = %w[
      PP ppe ppd PT pt dpt pl tl dpl td te ta dta DA DB lve taj usbh usbp dpi tme tmd pme pmd
      sph eth epc rtc YNC YC P1 P2 pb md me sb mb ME MD cs DM TT TRE TRD TTCP xe QRV n FGL
      NS ns RO ro SN sn TO to AP ap SA sa CR
    ].freeze
    STATUS = (1..9).flat_map { |i| ["s#{i}", "S#{i}"] }.freeze
    PRINT = %w[p q z].freeze
    HOLD = %w[h r].freeze
    ROTATIONS = %w[NR RR RU RL].freeze
    QR_ECC = { 0 => :m, 1 => :l, 2 => :h, 3 => :q }.freeze
    UNRENDERED_2D = { 'PDF' => 'PDF417', 'DTM' => 'DataMatrix', 'AZ' => 'Aztec' }.freeze
    PLACEHOLDER_2D = { 'PDF' => [300, 100], 'DTM' => [150, 150], 'AZ' => [150, 150] }.freeze
    MISSING_LOGO_SIZE = 100
    MAX_MACRO_DEPTH = 4
    HANDLERS = {
      'RC' => :position, 'SP' => :position, 'F' => :select_resident, 'RTF' => :select_ttf,
      'TTF' => :select_ttf, 'HW' => :scale_command, 'SD' => :divisor_command, 'BS' => :box_size,
      'NR' => :rotation_command, 'RR' => :rotation_command, 'RU' => :rotation_command,
      'RL' => :rotation_command, 'EI' => :flag_command, 'DI' => :flag_command, 'OWE' => :flag_command,
      'OWD' => :flag_command, 'LT' => :thickness_command, 'BX' => :line, 'HX' => :line, 'VX' => :line,
      'CTR' => :field_text, 'RTJ' => :field_text, 'LD' => :logo, 'LO' => :logo, 'ID' => :logo_id_command,
      'DF' => :delete_logo, 'ESCc' => :clear_logos, 'bmp' => :image_format_command,
      'pcx' => :image_format_command, 'G' => :inline_graphics, 'g' => :inline_graphics,
      'PC' => :print_counter, 'TC' => :counter_command, 'X' => :bar_width_command,
      'BI' => :human_readable_command, 'QR' => :qr_code, 'PDF' => :unrendered_2d, 'DTM' => :unrendered_2d,
      'AZ' => :unrendered_2d, 'p' => :print_command, 'q' => :print_command, 'z' => :print_command,
      'h' => :hold_command, 'r' => :hold_command, 'RE' => :copies_command, 'CB' => :clear_buffer,
      'PL' => :page_length
    }.freeze

    attr_reader :config, :logo_store, :counter, :state

    def initialize(config: Config.new, logo_store: LogoStore.new, counter: Counter.new, on_status: nil)
      @config = config
      @logo_store = logo_store
      @counter = counter
      @on_status = on_status
      @next_logo_id = nil
      reset!
    end

    # Feeds bytes; returns the tickets completed by print commands in them.
    def feed(bytes)
      @lexer.feed(bytes).each do |token|
        @raw << token.raw
        handle(token)
      end
      done = @emitted
      @emitted = []
      done
    end

    # True when content has been drawn (or bytes buffered) that no print command has
    # printed yet.
    def pending?
      !@ticket.items.empty? || @lexer.pending_bytesize.positive?
    end

    # Unprinted bytes: everything consumed since the last print command plus bytes the
    # lexer is still buffering.
    def pending_bytesize
      @raw.bytesize + @lexer.pending_bytesize
    end

    def reset!
      @lexer = Lexer.new
      @raw = String.new(encoding: Encoding::BINARY)
      @emitted = []
      @copies = 1
      @macro_depth = 0
      @state = State.defaults(config)
      @ticket = new_ticket
    end

    private

    def new_ticket(items = [])
      Ticket.new(width_dots: config.width_dots, length_dots: config.length_dots,
                 print_width_dots: config.print_width_dots, items: items)
    end

    def warn(message)
      @ticket.warn(message)
      config.logger.warn("fgl_pdf: #{message}")
    end

    def debug(message)
      config.logger.debug("fgl_pdf: #{message}")
    end

    def handle(token)
      case token.kind
      when :text then draw_text(decode(token.text))
      when :newline then newline
      when :print then print_ticket(hold: false)
      when :esc_block then esc_block(token)
      when :command then command(token)
      end
    end

    # ---- commands -----------------------------------------------------------------

    def command(tok)
      name = tok.name
      handler = HANDLERS[name]
      return send(handler, tok) if handler
      return barcode(tok) if Lexer::BARCODE_NAME.match?(name)
      return status(name) if STATUS.include?(name)
      return debug("ignored #{command_text(tok)}") if IGNORED.include?(name)

      unknown(tok)
    end

    def scale_command(tok) = (@state.hw_w, @state.hw_h = positive_args(tok, 2, 1))
    def divisor_command(tok) = (@state.sd = positive_args(tok, 1, 1).first)
    def rotation_command(tok) = (@state.rotation = tok.name.to_sym)
    def thickness_command(tok) = (@state.lt = positive_args(tok, 1, 1).first)
    def logo_id_command(tok) = (@next_logo_id = int_args(tok).first)
    def clear_logos(_tok) = logo_store.clear
    def image_format_command(tok) = (@state.image_format = tok.name.to_sym)
    def print_counter(_tok) = draw_text(counter.to_s)
    def bar_width_command(tok) = (@state.bar_width = positive_args(tok, 1, config.default_bar_width).first)
    def human_readable_command(_tok) = (@state.bi = true)
    def print_command(_tok) = print_ticket(hold: false)
    def hold_command(_tok) = print_ticket(hold: true)
    def copies_command(tok) = (@copies = 1 + (int_args(tok).first || 0).clamp(0, 9999))
    def clear_buffer(_tok) = @ticket.items.clear

    def flag_command(tok)
      case tok.name
      when 'EI', 'DI' then @state.inverse = tok.name == 'EI'
      else @state.overwrite = tok.name == 'OWE'
      end
    end

    def unknown(tok)
      message = "unknown command #{command_text(tok)}"
      raise StrictError, message if config.strict

      warn(message)
    end

    def status(name)
      debug("status query <#{name}>")
      @on_status&.call(name)
    end

    def command_text(tok)
      "<#{tok.name}#{tok.args&.join(',')}>"
    end

    # Integer args; "230.0" is rounded with a warning, blanks are nil.
    def int_args(tok)
      tok.args.map { |a| to_int(a, tok) }
    end

    def to_int(str, tok)
      return nil if str.nil? || str.empty?

      Integer(str, 10)
    rescue ArgumentError
      begin
        value = Float(str)
      rescue ArgumentError
        bad_argument(tok)
        return nil
      end
      warn("non-integer argument in #{command_text(tok)}")
      value.round
    end

    def bad_argument(tok)
      message = "invalid argument in #{command_text(tok)}"
      raise StrictError, message if config.strict

      warn(message)
    end

    def positive_args(tok, count, default)
      values = int_args(tok)
      Array.new(count) do |i|
        v = values[i]
        v.nil? || v < 1 ? default : v
      end
    end

    def position(tok)
      row, col = int_args(tok)
      if row.nil? || col.nil?
        bad_argument(tok)
        return
      end
      @state.move_to(col, row)
    end

    def select_resident(tok)
      id = int_args(tok).first
      font = id && Fonts.resident(id)
      unless font
        warn("unknown resident font #{command_text(tok)}, using font #{Fonts::DEFAULT_ID}")
        font = Fonts.resident(Fonts::DEFAULT_ID)
      end
      @state.font_kind = :resident
      @state.font_id = font.id
      @state.ttf_id = nil
      @state.box_w = font.box_w
      @state.box_h = font.box_h
    end

    def select_ttf(tok)
      id, pt = int_args(tok)
      unless id && config.ttf_path(id)
        warn("unknown TrueType font #{command_text(tok)}, using font 3")
        id = 3
      end
      unless pt&.positive?
        bad_argument(tok)
        pt = 10
      end
      @state.font_kind = :ttf
      @state.ttf_id = id
      @state.ttf_pt = pt
    end

    def box_size(tok)
      w, h = int_args(tok)
      @state.box_w = w if w&.positive?
      @state.box_h = h if h&.positive?
    end

    def counter_command(tok)
      value = int_args(tok).first
      value ? counter.value = value : bad_argument(tok)
    end

    def page_length(tok)
      value = int_args(tok).first
      return bad_argument(tok) unless value&.positive?

      @ticket.length_dots = [@ticket.length_dots, value].min
    end

    # ---- text -----------------------------------------------------------------------

    def decode(bytes)
      bytes.b.delete("\x00-\x1F\x7F".b)
           .force_encoding(Encoding::Windows_1252)
           .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '?')
    end

    def num(value)
      value = value.to_r if value.is_a?(Integer)
      value == value.floor ? value.to_i : value.to_f
    end

    # Text metrics in the current font: Text attributes without position.
    def metrics(string)
      @state.font_kind == :ttf ? ttf_metrics(string) : resident_metrics(string)
    end

    def ttf_metrics(string)
      s = @state
      face = config.ttf_path(s.ttf_id)
      size = num(Rational(s.ttf_pt * config.dpi, 72) * s.hw_h / s.sd)
      warn("<HW#{s.hw_w},#{s.hw_h}> on a TrueType font: width scaled by height") if s.hw_w != s.hw_h
      { font_kind: :ttf, face: face, size: size, glyph_w: nil, glyph_h: nil, cell_w: nil,
        length: ttf_length(face, string, size), height: num(size * 1.2) }
    end

    def resident_metrics(string)
      s = @state
      font = s.resident_font
      cell_w = num(Rational(s.box_w * s.hw_w, s.sd))
      { font_kind: :resident, face: font.face, size: nil,
        glyph_w: num(Rational(font.glyph_w * s.hw_w, s.sd)), glyph_h: num(Rational(font.glyph_h * s.hw_h, s.sd)),
        cell_w: cell_w, length: num(cell_w * string.length), height: num(Rational(s.box_h * s.hw_h, s.sd)) }
    end

    def ttf_length(face, string, size)
      num(Fonts.ttf_width(face, string, size))
    rescue StandardError => e
      warn("cannot measure #{string.inspect} in #{File.basename(face.to_s)}: #{e.message}")
      num(string.length * size * 0.55)
    end

    def line_height
      return num(Rational(8 * @state.hw_h, @state.sd)) if @state.line_graphics

      metrics('')[:height]
    end

    # Draws +string+ at the cursor, offset +offset+ dots along the advance direction,
    # and leaves the cursor at its end.
    def draw_text(string, offset: 0, measured: nil)
      return if string.empty?

      m = measured || metrics(string)
      x, y = Geometry.to_page(@state.x, @state.y, @state.rotation, offset, 0)
      @ticket << Text.new(x: x, y: y, rotation: @state.rotation, string: string,
                          inverse: @state.inverse, overwrite: @state.overwrite, **m)
      advance(offset + m[:length])
    end

    def advance(distance)
      @state.x, @state.y = Geometry.to_page(@state.x, @state.y, @state.rotation, distance, 0)
    end

    def newline
      dx, dy = Geometry.down(@state.rotation)
      h = line_height
      @state.move_to(@state.line_x + (dx * h), @state.line_y + (dy * h))
    end

    # Room from the cursor to the ticket edge along the advance direction.
    def room_ahead
      case @state.rotation
      when :NR then @ticket.length_dots - @state.x
      when :RR then @ticket.width_dots - @state.y
      when :RU then @state.x
      else @state.y
      end
    end

    # <CTR#>~text~ centers and <RTJ#>~text~ right-justifies in a field # dots long
    # (clipped to the ticket edge); text longer than the field is left-justified.
    def field_text(tok)
      field = int_args(tok).first
      if tok.data.nil?
        warn("#{command_text(tok)} without ~text~")
        return
      end
      string = decode(tok.data)
      return if string.empty?

      field = [field || 0, room_ahead].min
      m = metrics(string)
      spare = field - m[:length]
      offset = if spare.negative? then 0
               elsif tok.name == 'CTR' then num(spare/2r)
               else num(spare)
               end
      draw_text(string, offset: offset, measured: m)
    end

    # ---- lines ----------------------------------------------------------------------

    # <BXr,c> box, <HXn> horizontal line, <VXn> vertical line, all unrotated. LT is
    # one-shot. Assumption: an HX line's thickness builds UP from the cursor row
    # (rows row-LT … row). Sample orders draw full-width stub bars with
    # <RC600,…><LT600><HX5> on 600-row stock, which only print if HX grows upward.
    # VX thickness builds right, BX strokes grow inward.
    def line(tok)
      n, m = int_args(tok)
      return bad_argument(tok) if n.nil? || (tok.name == 'BX' && m.nil?)

      lt = @state.lt
      x = @state.x
      y = @state.y
      @ticket << case tok.name
                 when 'BX' then BoxOutline.new(x: x, y: y, w: m, h: n, thickness: lt, overwrite: @state.overwrite)
                 when 'HX' then Rect.new(x: x, y: y - lt, w: n, h: lt, overwrite: @state.overwrite)
                 else Rect.new(x: x, y: y, w: lt, h: n, overwrite: @state.overwrite)
                 end
      @state.lt = 1
    end

    # ---- printing -------------------------------------------------------------------

    # Emits the current ticket. <h>/<r> keep its images as the start of the next one.
    def print_ticket(hold:)
      ticket = @ticket
      ticket.raw = @raw
      ticket.copies = @copies
      ticket.off_page_items.each do |item|
        box = visible_bbox(item)
        ticket.warn(off_page_message(item, box, ticket)) unless ticket.inside?(box)
      end
      ticket.past_print_width_items.each do |item|
        box = visible_bbox(item)
        ticket.warn(past_print_width_message(item, box, ticket)) if box[3] > ticket.print_width_dots
      end
      @emitted << ticket
      @copies.times { counter.increment! }
      kept = hold ? ticket.items.grep(Image) : []
      @raw = String.new(encoding: Encoding::BINARY)
      @copies = 1
      @state = State.defaults(config)
      @ticket = new_ticket(kept)
    end

    # Trailing blanks (common in padded receipt columns) print nothing, so they do not
    # count as running off the ticket.
    def visible_bbox(item)
      return item.bbox unless item.is_a?(Text) && item.string.match?(/\s\z/)

      visible = item.string.rstrip
      length = if item.font_kind == :ttf then ttf_length(item.face, visible, item.size)
               else item.cell_w * visible.length
               end
      Geometry.bbox(item.x, item.y, item.rotation, length, item.height)
    end

    def off_page_message(item, box, ticket)
      min_x, min_y, max_x, max_y = box
      parts = []
      parts << "x #{fmt(min_x)}..#{fmt(max_x)} > #{ticket.length_dots}" if max_x > ticket.length_dots
      parts << "x #{fmt(min_x)}..#{fmt(max_x)} < 0" if min_x.negative?
      parts << "y #{fmt(min_y)}..#{fmt(max_y)} > #{ticket.width_dots}" if max_y > ticket.width_dots
      parts << "y #{fmt(min_y)}..#{fmt(max_y)} < 0" if min_y.negative?
      "#{describe(item)} extends off the ticket (#{parts.join(', ')})"
    end

    def past_print_width_message(item, box, ticket)
      "#{describe(item)} extends past the print width " \
        "(y #{fmt(box[1])}..#{fmt(box[3])} > #{ticket.print_width_dots})"
    end

    def fmt(value)
      rounded = value.round(1)
      rounded == rounded.round ? rounded.round.to_s : rounded.to_s
    end

    def describe(item)
      case item
      when Text then %(Text "#{item.string}")
      when Barcode then %(Barcode #{item.symbology} "#{item.data}")
      when Image then "Image #{item.bitmap.width}x#{item.bitmap.height}"
      when Matrix2D then 'QR code'
      when Placeholder then "Placeholder #{item.label}"
      when BoxOutline then 'Box'
      else 'Line'
      end
    end
  end

  class Interpreter
    # Logo downloads, logo placement and inline graphics.
    module Logos
      private

      # ---- logos and graphics ---------------------------------------------------------

      def scale
        [num(Rational(@state.hw_w, @state.sd)), num(Rational(@state.hw_h, @state.sd))]
      end

      def place_image(bitmap)
        scale_w, scale_h = scale
        @ticket << Image.new(x: @state.x, y: @state.y, rotation: @state.rotation, bitmap: bitmap,
                             scale_w: scale_w, scale_h: scale_h, overwrite: @state.overwrite)
      end

      def placeholder(length, height, label)
        @ticket << Placeholder.new(x: @state.x, y: @state.y, rotation: @state.rotation,
                                   length: length, height: height, label: label)
      end

      def logo(tok)
        slot = int_args(tok).first
        return bad_argument(tok) unless slot

        if tok.name == 'LO'
          warn("factory logo #{slot} not available")
          return placeholder(MISSING_LOGO_SIZE, MISSING_LOGO_SIZE, "LOGO #{slot}")
        end
        case (entry = logo_store.fetch(slot))
        when Bitmap then place_image(entry)
        when LogoStore::Macro then replay(entry.bytes, slot)
        else
          warn("logo #{slot} not loaded")
          placeholder(MISSING_LOGO_SIZE, MISSING_LOGO_SIZE, "LOGO #{slot}")
        end
      end

      # Runs a stored macro at the current state. Its bytes are not part of ticket raw.
      def replay(bytes, slot)
        return warn("logo #{slot}: macro nesting too deep") if @macro_depth >= MAX_MACRO_DEPTH

        @macro_depth += 1
        begin
          Lexer.tokenize(bytes).each { |t| handle(t) }
        ensure
          @macro_depth -= 1
        end
      end

      def delete_logo(tok)
        slot = int_args(tok).first
        slot ? logo_store.delete(slot) : bad_argument(tok)
      end

      # ESC … ESC: a logo download. <bmp>/<pcx> + <G n> payload → bitmap; <G#> bands
      # (each CR moves down 8 rows) → bitmap; anything else → macro replayed by <LD#>.
      # The slot is the preceding (or contained) <ID#>, else the store's implicit slot.
      def esc_block(tok)
        warn('unterminated ESC block (logo download)') if tok.error
        kids = tok.children.reject { |t| %i[ignored transparent].include?(t.kind) }
        kids.each { |t| @next_logo_id = to_int(t.args.first, t) if t.kind == :command && t.name == 'ID' }
        logo = esc_logo(kids, tok)
        return unless logo

        slot = @next_logo_id || logo_store.take_implicit_slot
        @next_logo_id = nil
        logo_store.store(slot, logo)
        debug("stored logo #{slot} (#{logo.class.name.split('::').last})")
      rescue Bitmap::DecodeError => e
        @next_logo_id = nil
        warn("logo download failed: #{e.message}")
      end

      def esc_logo(kids, tok)
        format = nil
        kids.each do |t|
          next unless t.kind == :command

          format = t.name.to_sym if %w[bmp pcx].include?(t.name)
          return decode_image(format, payload_bytes(t)) if format && %w[G g].include?(t.name)
        end
        band_logo(kids) || LogoStore::Macro.new(macro_bytes(tok))
      end

      def macro_bytes(tok)
        inner = tok.raw.byteslice(1..)
        inner = inner.byteslice(0, inner.bytesize - 1) unless tok.error
        inner
      end

      def band_logo(kids)
        allowed = kids.all? do |t|
          t.kind == :newline || (t.kind == :command && %w[G g RC SP ID].include?(t.name))
        end
        return nil unless allowed && kids.any? { |t| t.kind == :command && %w[G g].include?(t.name) }

        lines = [String.new(encoding: Encoding::BINARY)]
        kids.each do |t|
          if t.kind == :newline then lines << String.new(encoding: Encoding::BINARY)
          elsif %w[G g].include?(t.name) then lines.last << payload_bytes(t)
          end
        end
        lines.pop while lines.size > 1 && lines.last.empty?
        Bitmap.stack_bands(lines.map { |l| Bitmap.from_columns(l) })
      end

      def payload_bytes(tok)
        payload = tok.payload || ''.b
        return payload unless tok.name == 'g'

        hex = payload.b.delete('^0-9A-Fa-f')
        hex = hex.byteslice(0, hex.bytesize - 1) if hex.bytesize.odd?
        [hex].pack('H*')
      end

      def decode_image(format, bytes)
        format == :pcx ? Bitmap.from_pcx(bytes) : Bitmap.from_bmp(bytes)
      end

      # Inline graphics. After <bmp>/<pcx> the payload is an image file printed at the
      # cursor. Otherwise <G#>/<g#> is column data (8 dots tall). Assumption: graphics
      # follow the current rotation like text, advance the cursor by their length, and a
      # CR after graphics moves down 8 dots (× HW/SD) instead of a font line.
      def inline_graphics(tok)
        warn("#{command_text(tok)} payload truncated") if tok.error
        bytes = payload_bytes(tok)
        if @state.image_format
          format = @state.image_format
          @state.image_format = nil
          begin
            place_image(decode_image(format, bytes))
          rescue Bitmap::DecodeError => e
            warn("#{format} image not rendered: #{e.message}")
          end
          return
        end
        return if bytes.empty?

        bitmap = Bitmap.from_columns(bytes)
        place_image(bitmap)
        advance(bitmap.width * scale.first)
        @state.line_graphics = true
      end
    end

    # Linear barcodes and 2D codes.
    module Codes
      private

      # ---- barcodes ---------------------------------------------------------------------

      # <aB#>: a = type (lowercase follows the current rotation), optional X = 3:1 ratio,
      # B = P(icket fence, along x) / L(adder, across), # = height in 8-dot units.
      def barcode(tok)
        type, ratio, orient = Lexer::BARCODE_NAME.match(tok.name).captures
        rotation = barcode_rotation(type, orient)
        units = positive_args(tok, 1, @state.bar_height).first
        human = @state.bi
        @state.bi = false
        warn("#{command_text(tok)}: 3:1 ratio not supported, drawn with standard ratio") unless ratio.empty?
        return barcode_failed(tok, rotation, units, 'no data') if tok.data.nil?

        data = decode(tok.data)
        result = symbology.linear(type.upcase, data)
        item = Barcode.new(x: @state.x, y: @state.y, rotation: rotation, symbology: symbology_name(type),
                           data: data, modules: result[:modules], module_w: @state.bar_width,
                           bar_height: units * 8, human_text: human ? result[:human_text] : nil)
        @ticket << item
      rescue StrictError
        raise
      rescue StandardError => e
        barcode_failed(tok, rotation, units, e.message)
      end

      def barcode_rotation(type, orient)
        upper = type == type.upcase
        if orient == 'P'
          !upper && @state.rotation == :RU ? :RU : :NR
        else
          !upper && @state.rotation == :RL ? :RL : :RR
        end
      end

      def barcode_failed(tok, rotation, units, reason)
        warn("barcode #{command_text(tok)} not rendered: #{reason}")
        @ticket << Placeholder.new(x: @state.x, y: @state.y, rotation: rotation || :NR, length: 200,
                                   height: (units || 4) * 8, label: "BARCODE #{tok.name}")
      end

      def symbology
        raise Error, 'barcode support (FglPdf::Symbology) not loaded' unless defined?(FglPdf::Symbology)

        FglPdf::Symbology
      end

      def symbology_name(type)
        names = defined?(FglPdf::Symbology::NAMES) ? FglPdf::Symbology::NAMES : {}
        names.fetch(type.upcase, type.upcase)
      end

      # <QRpt,tilde,mode,ecc>{data}; pt = module size in dots (default 6).
      def qr_code(tok)
        pt, _tilde, _mode, ecc = int_args(tok)
        size = pt&.positive? ? pt : 6
        return qr_failed(tok, size, 'no {data}') if tok.data.nil?

        data = decode(tok.data)
        matrix = symbology.qr_matrix(data, ecc: QR_ECC.fetch(ecc || 0, :m))
        @ticket << Matrix2D.new(x: @state.x, y: @state.y, rotation: @state.rotation, symbology: 'QR',
                                data: data, matrix: matrix, module_size: size)
      rescue StrictError
        raise
      rescue StandardError => e
        qr_failed(tok, size || 6, e.message)
      end

      def qr_failed(tok, size, reason)
        warn("QR code #{command_text(tok)} not rendered: #{reason}")
        placeholder(size * 25, size * 25, 'QR')
      end

      def unrendered_2d(tok)
        name = UNRENDERED_2D.fetch(tok.name)
        warn("#{name} not rendered")
        length, height = PLACEHOLDER_2D.fetch(tok.name)
        placeholder(length, height, name)
      end
    end

    include Logos
    include Codes
  end
end
