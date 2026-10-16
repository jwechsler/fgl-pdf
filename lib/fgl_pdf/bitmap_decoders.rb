# frozen_string_literal: true

require_relative 'bitmap'

module FglPdf
  # Decoders for the logo/graphics formats an FGL stream can carry.
  class Bitmap
    class DecodeError < StandardError; end

    class << self
      # Windows BMP (BITMAPINFOHEADER and later, or OS/2 BITMAPCOREHEADER), uncompressed.
      # 1-bit pixels print the way the Boca prints them: bit 0 is black, bit 1 is white,
      # whatever the palette says (a logo whose palette is reversed prints correctly on
      # the real printer). 4/8-bit pixels are black when their palette color's luminance
      # is < 128; 24/32-bit pixels use the same threshold on their own color.
      def from_bmp(bytes)
        bytes = bytes.b
        raise DecodeError, 'not a BMP (missing BM signature)' unless bytes.bytesize >= 26 && bytes.start_with?('BM')

        data_offset = bytes.byteslice(10, 4).unpack1('V')
        dib_size = bytes.byteslice(14, 4).unpack1('V')
        width, height, bpp, compression, palette = bmp_header(bytes, dib_size)
        raise DecodeError, "unsupported BMP compression #{compression}" unless [0, 3].include?(compression)
        raise DecodeError, "unsupported BMP depth #{bpp}" unless [1, 4, 8, 24, 32].include?(bpp)

        top_down = height.negative?
        height = height.abs
        row_size = (((bpp * width) + 31) / 32) * 4
        raise DecodeError, 'BMP pixel data truncated' if data_offset + (row_size * height) > bytes.bytesize

        rows = Array.new(height) do |r|
          src_row = top_down ? r : height - 1 - r
          bmp_row(bytes.byteslice(data_offset + (src_row * row_size), row_size), width, bpp, palette)
        end
        new(width, height, rows)
      end

      # ZSoft PCX, RLE: 1-bit monochrome, 8-bit paletted, or 24-bit (3 planes).
      def from_pcx(bytes)
        bytes = bytes.b
        raise DecodeError, 'not a PCX file' unless bytes.bytesize > 128 && bytes.getbyte(0) == 0x0A

        bpp = bytes.getbyte(3)
        xmin, ymin, xmax, ymax = bytes.byteslice(4, 8).unpack('v4')
        planes = bytes.getbyte(65)
        bpl = bytes.byteslice(66, 2).unpack1('v')
        width = xmax - xmin + 1
        height = ymax - ymin + 1
        raise DecodeError, 'invalid PCX dimensions' unless width.positive? && height.positive?

        scan = pcx_rle(bytes, 128, planes * bpl * height, bytes.getbyte(2) == 1)
        black = pcx_black_test(bytes, bpp, planes)
        rows = Array.new(height) do |y|
          line = scan.byteslice(y * planes * bpl, planes * bpl).bytes
          Array.new(width) { |x| black.call(line, x, bpl) }
        end
        new(width, height, rows)
      end

      # FGL <G#> graphics: each byte is one column of 8 vertical dots, MSB at the top;
      # successive bytes are successive columns. The result is 8 dots tall.
      def from_columns(bytes)
        cols = bytes.b.bytes
        rows = Array.new(8) do |r|
          mask = 0x80 >> r
          cols.map { |c| c.anybits?(mask) }
        end
        new(cols.size, 8, rows)
      end

      # Stacks bitmaps (graphics bands) top to bottom, left-aligned.
      def stack_bands(bands)
        width = bands.map(&:width).max || 0
        rows = bands.flat_map do |band|
          band.rows.map { |row| row + Array.new(width - row.size, false) }
        end
        new(width, rows.size, rows)
      end

      private

      def bmp_header(bytes, dib_size)
        if dib_size == 12
          width, height, _planes, bpp = bytes.byteslice(18, 8).unpack('v4')
          compression = 0
          entry = 3
          colors = 0
        else
          width, height, _planes, bpp, compression = bytes.byteslice(18, 16).unpack('Vl<vvV')
          colors = bytes.bytesize >= 50 ? bytes.byteslice(46, 4).unpack1('V') : 0
          entry = 4
        end
        palette = []
        if bpp <= 8
          colors = 1 << bpp if colors.zero?
          start = 14 + dib_size
          palette = Array.new(colors) do |i|
            b, g, r = bytes.byteslice(start + (i * entry), 3)&.unpack('C3')
            dark?(r.to_i, g.to_i, b.to_i)
          end
        end
        [width, height, bpp, compression, palette]
      end

      def bmp_row(row, width, bpp, palette)
        b = row.bytes
        case bpp
        when 1 then Array.new(width) { |x| (b[x >> 3] >> (7 - (x & 7))).nobits?(1) }
        when 4 then Array.new(width) { |x| palette[(b[x >> 1] >> (x.even? ? 4 : 0)) & 0x0F] || false }
        when 8 then Array.new(width) { |x| palette[b[x]] || false }
        else
          step = bpp / 8
          Array.new(width) { |x| dark?(b[(x * step) + 2], b[(x * step) + 1], b[x * step]) }
        end
      end

      def dark?(red, green, blue)
        ((0.299 * red) + (0.587 * green) + (0.114 * blue)) < 128
      end

      def pcx_rle(bytes, pos, total, rle)
        return bytes.byteslice(pos, total) unless rle

        out = String.new(capacity: total, encoding: Encoding::BINARY)
        while out.bytesize < total && pos < bytes.bytesize
          b = bytes.getbyte(pos)
          pos += 1
          if b.allbits?(0xC0)
            value = bytes.getbyte(pos) || 0
            pos += 1
            out << (value.chr * (b & 0x3F))
          else
            out << b.chr
          end
        end
        out << ("\x00".b * (total - out.bytesize)) if out.bytesize < total
        out
      end

      def pcx_mono_test(bytes)
        pal = bytes.byteslice(16, 6).unpack('C6')
        # Most monochrome PCX files leave the header palette zeroed: 0 = black, 1 = white.
        zero_black = pal.all?(&:zero?) || dark?(*pal[0, 3])
        one_black = !pal.all?(&:zero?) && dark?(*pal[3, 3])
        lambda do |line, x, _bpl|
          bit = (line[x >> 3] >> (7 - (x & 7))) & 1
          bit.zero? ? zero_black : one_black
        end
      end

      # Returns a lambda (line_bytes, x, bytes_per_line) -> black?
      def pcx_black_test(bytes, bpp, planes)
        if bpp == 1 && planes == 1
          pcx_mono_test(bytes)
        elsif bpp == 8 && planes == 1
          pal_bytes = bytes.bytesize > 769 && bytes.getbyte(-769) == 0x0C ? bytes.byteslice(-768, 768) : nil
          raise DecodeError, '8-bit PCX without palette' unless pal_bytes

          dark = pal_bytes.unpack('C*').each_slice(3).map { |r, g, b| dark?(r, g, b) }
          ->(line, x, _bpl) { dark[line[x]] }
        elsif bpp == 8 && planes == 3
          ->(line, x, bpl) { dark?(line[x], line[bpl + x], line[(2 * bpl) + x]) }
        else
          raise DecodeError, "unsupported PCX format (#{bpp} bpp, #{planes} planes)"
        end
      end
    end
  end
end
