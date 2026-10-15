# frozen_string_literal: true

require 'prawn'
require 'stringio'
require_relative '../config'
require_relative '../geometry'
require_relative '../ticket'

# Non-WinAnsi characters are replaced before reaching the AFM fonts.
Prawn::Fonts::AFM.hide_m17n_warning = true

module FglPdf
  module Renderer
    # Draws a Ticket's display list onto a PDF page (Prawn), one page per ticket.
    #
    # All drawing happens in a "local frame" set up by #in_frame: inside the block one unit
    # is one printer dot, Prawn x = local u (advance) and Prawn y = -v (v grows down), so a
    # point drawn at [u, -v] lands at Geometry.to_page(x, y, rotation, u, v).
    class Pdf
      BLACK = '000000'
      WHITE = 'FFFFFF'
      GRID = 'D0D0D0'
      GRID_LABEL = 'A0A0A0'
      WARNING = 'D00000'

      # Fallback cap-height / em for AFM faces whose metrics we cannot read.
      DEFAULT_CAP_HEIGHT = 0.7
      # Horizontal scale clamp for resident glyphs.
      MIN_SCALE = 0.2
      MAX_SCALE = 5.0
      # Human-readable barcode text: cap height in dots.
      HUMAN_TEXT_DOTS = 8
      INVERSE_PAD = 2
      PLACEHOLDER_STROKE = 2
      GRID_STEP = 50
      GRID_LABEL_STEP = 100
      MAX_ANNOTATED_WARNINGS = 4

      attr_reader :config

      def initialize(config = Config.new)
        @config = config
        @cap_heights = {}
        @ref_widths = {}
        @em_fractions = {}
      end

      # PDF bytes (String) with one page for +ticket+.
      def render(ticket)
        render_many([ticket])
      end

      # PDF bytes (String) with one page per ticket, in order.
      def render_many(tickets)
        doc = Prawn::Document.new(skip_page_creation: true, margin: 0,
                                  info: { Creator: 'fgl_pdf', Producer: 'fgl_pdf' })
        tickets.each { |ticket| draw_page(doc, ticket) }
        doc.start_new_page(size: page_size_pt(nil), margin: 0) if tickets.empty?
        doc.render
      end

      private

      attr_reader :pdf

      def k
        config.pt_per_dot
      end

      def page_size_pt(ticket)
        length = ticket&.length_dots || config.length_dots
        width = ticket&.width_dots || config.width_dots
        [length * k, width * k]
      end

      def draw_page(doc, ticket)
        @pdf = doc
        size = page_size_pt(ticket)
        @page_h = size[1]
        doc.start_new_page(size: size, margin: 0)
        draw_grid(ticket) if config.debug_grid
        ticket.items.each { |item| draw_item(item) }
        draw_annotations(ticket) if config.annotate && !ticket.warnings.empty?
      ensure
        @pdf = nil
      end

      def draw_item(item)
        case item
        when Text then draw_text_item(item)
        when Rect then draw_rect(item)
        when BoxOutline then draw_box_outline(item)
        when Image then draw_image(item)
        when Barcode then draw_barcode(item)
        when Matrix2D then draw_matrix(item)
        when Placeholder then draw_placeholder(item)
        else config.logger.warn("fgl_pdf: cannot render #{item.class}")
        end
      end

      # --- frame helpers ----------------------------------------------------------------

      # Sets up a local frame anchored at page dots (x, y) with the given rotation; inside
      # the block draw with Prawn coordinates [u, -v] in dots.
      def in_frame(x, y, rotation = :NR, &)
        ax, ay = Geometry.advance(rotation)
        dx, dy = Geometry.down(rotation)
        pdf.save_graphics_state do
          pdf.transformation_matrix(k * ax, -k * ay, -k * dx, k * dy, k * x, @page_h - (k * y))
          yield
        end
      end

      # Filled rectangle in local dots: top-left (u, v), size w × h.
      def local_fill(u, v, w, h, color = BLACK)
        return if w <= 0 || h <= 0

        pdf.fill_color color
        pdf.fill_rectangle([u, -v], w, h)
      end

      def with_fill(color)
        pdf.fill_color color
        yield
      ensure
        pdf.fill_color BLACK
      end

      # --- drawables ---------------------------------------------------------------------

      def draw_rect(item)
        in_frame(item.x, item.y) do
          local_fill(0, 0, item.w, item.h, WHITE) if item.overwrite
          local_fill(0, 0, item.w, item.h)
        end
      end

      def draw_box_outline(item)
        w = item.w
        h = item.h
        t = [item.thickness.to_f, 0].max
        in_frame(item.x, item.y) do
          local_fill(0, 0, w, h, WHITE) if item.overwrite
          if t * 2 >= w || t * 2 >= h
            local_fill(0, 0, w, h)
          else
            local_fill(0, 0, w, t)
            local_fill(0, h - t, w, t)
            local_fill(0, t, t, h - (2 * t))
            local_fill(w - t, t, t, h - (2 * t))
          end
        end
      end

      def draw_text_item(item)
        string = item.string.to_s
        return if string.empty?

        in_frame(item.x, item.y, item.rotation) do
          length = item.length.to_f
          height = item.height.to_f
          if item.inverse
            local_fill(-INVERSE_PAD, -INVERSE_PAD, length + (2 * INVERSE_PAD), height + (2 * INVERSE_PAD))
          elsif item.overwrite
            local_fill(0, 0, length, height, WHITE)
          end
          with_fill(item.inverse ? WHITE : BLACK) do
            item.font_kind == :ttf ? draw_ttf_text(item, string) : draw_resident_text(item, string)
          end
        end
      end

      def draw_ttf_text(item, string)
        size = item.size.to_f
        return if size <= 0

        ascender, = em_fractions(item.face)
        pdf.font(item.face, size: size) do
          pdf.draw_text(string, at: [0, -(ascender * size)])
        end
      end

      # Each character is drawn in its own cell: cap height scaled to glyph_h, width scaled
      # uniformly so that 'H' spans glyph_w (wider glyphs are squeezed to glyph_w), centred
      # in the glyph box, top of capitals at v = 0 and baseline at v = glyph_h.
      def draw_resident_text(item, string)
        face = item.face || 'Helvetica'
        glyph_h = item.glyph_h.to_f
        glyph_w = item.glyph_w.to_f
        cell_w = (item.cell_w || glyph_w).to_f
        return if glyph_h <= 0 || glyph_w <= 0

        size = glyph_h / cap_height(face)
        base_scale = (glyph_w / (ref_width(face) * size)).clamp(MIN_SCALE, MAX_SCALE)
        pdf.font(face, size: size) do
          text = winansi(string)
          if face.start_with?('Courier')
            draw_monospace_run(text, size, cell_w, glyph_w, glyph_h, base_scale)
          else
            text.each_char.with_index do |char, i|
              next if char.strip.empty?

              draw_resident_char(char, i * cell_w, size, glyph_w, glyph_h, base_scale)
            end
          end
        end
      end

      # Monospaced faces: one text run whose character spacing makes each advance exactly
      # cell_w (keeps the string intact for text extraction).
      def draw_monospace_run(text, size, cell_w, glyph_w, glyph_h, scale)
        advance = ref_width(pdf.font.name) * size
        offset = (glyph_w - (advance * scale)) / 2.0
        pdf.horizontal_text_scaling(scale * 100) do
          pdf.character_spacing((cell_w / scale) - advance) do
            pdf.draw_text(text, at: [offset, -glyph_h])
          end
        end
      end

      def draw_resident_char(char, cell_u, size, glyph_w, glyph_h, base_scale)
        width = pdf.width_of(char, size: size)
        return if width <= 0

        scale = [base_scale, glyph_w / width].min
        offset = (glyph_w - (width * scale)) / 2.0
        pdf.horizontal_text_scaling(scale * 100) do
          pdf.draw_text(char, at: [cell_u + offset, -glyph_h])
        end
      end

      def draw_image(item)
        bitmap = item.bitmap
        return if bitmap.nil? || bitmap.width.zero? || bitmap.height.zero?

        w = item.length
        h = item.height
        in_frame(item.x, item.y, item.rotation) do
          local_fill(0, 0, w, h, WHITE) if item.overwrite
          pdf.image(StringIO.new(bitmap.to_png_blob), at: [0, 0], width: w, height: h)
        end
      end

      def draw_barcode(item)
        mw = item.module_w.to_f
        bar_h = item.bar_height.to_f
        in_frame(item.x, item.y, item.rotation) do
          item.modules.to_s.scan(/1+|0+/).each_with_object([0]) do |run, pos|
            local_fill(pos[0] * mw, 0, run.length * mw, bar_h) if run.start_with?('1')
            pos[0] += run.length
          end
          draw_label(item.human_text, 0, bar_h + 2, HUMAN_TEXT_DOTS) if item.human_text && !item.human_text.empty?
        end
      end

      def draw_matrix(item)
        m = item.module_size.to_f
        in_frame(item.x, item.y, item.rotation) do
          pdf.fill_color BLACK
          item.matrix.each_with_index do |row, j|
            row.each_with_index do |dark, i|
              pdf.rectangle([i * m, -j * m], m, m) if dark
            end
          end
          pdf.fill
        end
      end

      def draw_placeholder(item)
        len = item.length.to_f
        hgt = item.height.to_f
        s = PLACEHOLDER_STROKE
        in_frame(item.x, item.y, item.rotation) do
          pdf.stroke_color BLACK
          pdf.line_width = s
          pdf.stroke_rectangle([s / 2.0, -s / 2.0], len - s, hgt - s)
          pdf.stroke_line([0, 0], [len, -hgt])
          pdf.stroke_line([0, -hgt], [len, 0])
          draw_placeholder_label(item.label.to_s, len, hgt)
        end
      end

      def draw_placeholder_label(label, len, hgt)
        return if label.empty? || len < 12 || hgt < 12

        cap = (hgt / 4.0).clamp(6, 24)
        size = cap / cap_height('Helvetica')
        with_fill(BLACK) do
          pdf.font('Helvetica', size: size) do
            box_w = len - 8
            fit = pdf.width_of(winansi(label))
            size *= box_w / fit if fit > box_w
            pdf.draw_text(winansi(label), at: [4, -(4 + cap)], size: size)
          end
        end
      end

      # Helvetica text with cap height +cap_dots+, top at local (u, v).
      def draw_label(text, u, v, cap_dots, color = BLACK)
        size = cap_dots / cap_height('Helvetica')
        with_fill(color) do
          pdf.font('Helvetica', size: size) { pdf.draw_text(winansi(text), at: [u, -(v + cap_dots)]) }
        end
      end

      # --- debug overlays ---------------------------------------------------------------

      def draw_grid(ticket)
        length = ticket.length_dots || config.length_dots
        width = ticket.width_dots || config.width_dots
        in_frame(0, 0) do
          pdf.stroke_color GRID
          pdf.line_width = 0.5
          (0..length).step(GRID_STEP) { |x| pdf.stroke_line([x, 0], [x, -width]) }
          (0..width).step(GRID_STEP) { |y| pdf.stroke_line([0, -y], [length, -y]) }
          pdf.stroke_color BLACK
          (0..length).step(GRID_LABEL_STEP) { |x| draw_label(x.to_s, x + 2, 2, 7, GRID_LABEL) }
          (GRID_LABEL_STEP..width).step(GRID_LABEL_STEP) { |y| draw_label(y.to_s, 2, y + 2, 7, GRID_LABEL) }
        end
      end

      def draw_annotations(ticket)
        cap = [config.dpi / 30.0, 6].max
        in_frame(0, 0) do
          ticket.warnings.first(MAX_ANNOTATED_WARNINGS).each_with_index do |warning, i|
            draw_label("! #{warning}", 4, 4 + (i * cap * 1.6), cap, WARNING)
          end
          extra = ticket.warnings.size - MAX_ANNOTATED_WARNINGS
          draw_label("(+#{extra} more)", 4, 4 + (MAX_ANNOTATED_WARNINGS * cap * 1.6), cap, WARNING) if extra.positive?
        end
      end

      # --- font metrics -----------------------------------------------------------------

      # Cap height as a fraction of the em for a built-in AFM face.
      def cap_height(face)
        @cap_heights[face] ||= begin
          attrs = measure(face) { |doc| doc.font.instance_variable_get(:@attributes) } || {}
          value = attrs['capheight'] || attrs['CapHeight']
          value ? value.to_f / 1000.0 : DEFAULT_CAP_HEIGHT
        rescue StandardError
          DEFAULT_CAP_HEIGHT
        end
      end

      # Advance width of 'H' as a fraction of the em.
      def ref_width(face)
        @ref_widths[face] ||= measure(face) { |doc| doc.width_of('H', size: 1000) / 1000.0 }
      end

      # [ascender, descender] of a TrueType face as fractions of the em.
      def em_fractions(path)
        @em_fractions[path] ||= measure(path) do |doc|
          size = doc.font_size.to_f
          [doc.font.ascender / size, doc.font.descender.abs / size]
        end
      end

      # Runs the block with +face+ selected on the current (or a scratch) document and
      # returns the block's value (Prawn's #font returns the font, not the block value).
      def measure(face)
        doc = pdf_or_measure
        result = nil
        doc.font(face) { result = yield doc }
        result
      end

      def pdf_or_measure
        pdf || (@measure ||= Prawn::Document.new(margin: 0))
      end

      # Prawn's AFM fonts only take Windows-1252; replace anything else with '?'.
      def winansi(string)
        string.to_s
              .encode('Windows-1252', invalid: :replace, undef: :replace, replace: '?')
              .encode('UTF-8')
              .gsub(/[\x00-\x1F\x7F]/, '?')
      end
    end
  end
end
