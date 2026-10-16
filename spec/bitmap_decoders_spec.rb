# frozen_string_literal: true

RSpec.describe FglPdf::Bitmap do
  # Builds an uncompressed BMP from rows of booleans (true = black). 1-bit black is bit 0,
  # as the Boca prints it, with a matching palette unless one is given.
  def build_bmp(rows, bpp: 1, top_down: false, palette: [[0, 0, 0], [255, 255, 255]])
    width = rows.first.size
    height = rows.size
    row_size = (((bpp * width) + 31) / 32) * 4
    pal = bpp <= 8 ? palette.map { |r, g, b| [b, g, r, 0].pack('C4') }.join : ''
    offset = 14 + 40 + pal.bytesize
    ordered = top_down ? rows : rows.reverse
    pixels = ordered.map do |row|
      bytes = if bpp == 1
                [row.map { |on| on ? '0' : '1' }.join].pack('B*')
              else
                row.map { |on| on ? "\x00\x00\x00".b : "\xFF\xFF\xFF".b }.join
              end
      bytes.b.ljust(row_size, "\x00")
    end.join
    header = ['BM', offset + pixels.bytesize, 0, 0, offset].pack('a2VvvV')
    info = [40, width, top_down ? -height : height, 1, bpp, 0, pixels.bytesize, 2835, 2835,
            bpp <= 8 ? palette.size : 0, 0].pack('Vl<l<vvVVl<l<VV')
    header + info + pal + pixels
  end

  let(:pattern) do
    [
      [true, false, false, true, true, false, false, false, false, true],
      [false, true, false, false, false, false, false, false, true, false],
      [false, false, true, true, true, true, true, true, false, false]
    ]
  end

  describe '.from_bmp' do
    it 'decodes the sample 240x120 1-bit logo' do
      bitmap = described_class.from_bmp(fixture('logo_240x120.bmp'))
      expect([bitmap.width, bitmap.height]).to eq([240, 120])
      black = bitmap.rows.flatten.count(true)
      expect(black).to be > 0
      expect(black).to be < 240 * 120
      # The sample has a border: the corners are black.
      expect([bitmap[0, 0], bitmap[239, 0], bitmap[0, 119], bitmap[239, 119]]).to all(be(true))
    end

    it 'decodes bottom-up rows with row padding' do
      expect(described_class.from_bmp(build_bmp(pattern)).rows).to eq(pattern)
    end

    it 'decodes top-down rows' do
      expect(described_class.from_bmp(build_bmp(pattern, top_down: true)).rows).to eq(pattern)
    end

    it 'prints 1-bit bit 0 as black whatever the palette says, like the Boca' do
      reversed_palette = build_bmp(pattern, palette: [[255, 255, 255], [0, 0, 0]])
      expect(described_class.from_bmp(reversed_palette).rows).to eq(pattern)
    end

    it 'thresholds 24-bit pixels' do
      expect(described_class.from_bmp(build_bmp(pattern, bpp: 24)).rows).to eq(pattern)
    end

    it 'rejects non-BMP data' do
      expect { described_class.from_bmp('GIF89a....................') }.to raise_error(FglPdf::Bitmap::DecodeError)
    end
  end

  describe '.from_pcx' do
    def build_pcx(rows)
      width = rows.first.size
      bpl = ((width + 15) / 16) * 2
      header = [0x0A, 5, 1, 1, 0, 0, width - 1, rows.size - 1, 72, 72].pack('C4v6')
      header += ("\x00".b * 48) + [0, 1, bpl, 1].pack('CCvv')
      header = header.ljust(128, "\x00")
      # 1 = white in monochrome PCX; RLE-encode each byte as a run of one (0xC1, value).
      data = rows.map do |row|
        [row.map { |on| on ? '0' : '1' }.join.ljust(bpl * 8, '1')].pack('B*')
      end.join
      header + data.bytes.map { |b| [0xC1, b].pack('C2') }.join
    end

    it 'decodes 1-bit RLE data' do
      expect(described_class.from_pcx(build_pcx(pattern)).rows).to eq(pattern)
    end
  end

  describe '.from_columns' do
    it 'maps each byte to an 8-dot column, MSB at the top' do
      bitmap = described_class.from_columns("\x80\x01\xFF".b)
      expect([bitmap.width, bitmap.height]).to eq([3, 8])
      expect(bitmap.rows.map { |r| r.map { |on| on ? 1 : 0 }.join }).to eq(
        %w[101 001 001 001 001 001 001 011]
      )
    end
  end

  describe '.stack_bands' do
    it 'stacks bands top to bottom, padding narrow ones' do
      bitmap = described_class.stack_bands([described_class.from_columns("\xFF\xFF".b),
                                            described_class.from_columns("\x80".b)])
      expect([bitmap.width, bitmap.height]).to eq([2, 16])
      expect(bitmap[1, 8]).to be(false)
      expect(bitmap[0, 8]).to be(true)
    end
  end
end
