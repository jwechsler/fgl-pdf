# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'fgl_pdf/symbology'

RSpec.describe FglPdf::Symbology do
  def ean_check_digit(digits12)
    sum = digits12.chars.each_with_index.sum { |d, i| d.to_i * (i.odd? ? 3 : 1) }
    (10 - (sum % 10)) % 10
  end

  describe '.linear' do
    it 'encodes Code39 with the * start/stop pattern' do
      result = described_class.linear('N', 'ABC')
      star = '100101101101' # '*' = bwbWBwBwb with narrow 1 / wide 2 modules
      expect(result[:modules]).to start_with(star)
      expect(result[:modules]).to end_with(star)
      expect(result[:human_text]).to eq('*ABC*')
    end

    it 'falls back to extended Code39 for lowercase' do
      expect(described_class.linear('N', 'abc')[:modules]).to match(/\A[01]+\z/)
    end

    it 'encodes EAN13 with J/K/L markers and recomputes the check digit' do
      result = described_class.linear('E', '9J014561K780120L')
      expect(result[:human_text]).to eq("901456178012#{ean_check_digit('901456178012')}")
      expect(result[:modules].length).to eq(95)
      expect(result[:modules]).to start_with('101').and end_with('101')
    end

    it 'encodes UPC-A (11 or 12 digits) as EAN13 with a leading 0' do
      result = described_class.linear('U', '03600029145')
      expect(result[:human_text]).to eq('036000291452')
      expect(result[:modules].length).to eq(95)
      expect(described_class.linear('U', '036000291459')[:human_text]).to eq('036000291452')
    end

    it 'encodes EAN8 for 7–8 digit U data' do
      result = described_class.linear('U', '9638507')
      expect(result[:modules].length).to eq(67)
      expect(result[:human_text]).to eq('96385074')
    end

    it 'pads odd-length Interleaved 2 of 5 with a leading zero' do
      result = described_class.linear('F', '123')
      expect(result[:human_text]).to eq('0123')
      expect(result[:modules]).to eq(described_class.linear('F', '0123')[:modules])
    end

    it 'encodes Codabar including start/stop letters' do
      result = described_class.linear('C', 'A1234B')
      expect(result[:modules]).to match(/\A1[01]*1\z/)
      expect(result[:human_text]).to eq('A1234B')
    end

    it 'encodes Code128 with auto charset (11 modules per symbol + 13-module stop)' do
      %w[Order-12345 12345678 abcDEF].each do |data|
        modules = described_class.linear('O', data)[:modules]
        expect((modules.length - 13) % 11).to eq(0)
        expect(modules).to end_with('1100011101011')
      end
      # 'ABC' in set B: start + 3 chars + checksum + stop
      expect(described_class.linear('O', 'ABC')[:modules].length).to eq((5 * 11) + 13)
    end

    it 'raises Unsupported for unknown types' do
      expect { described_class.linear('Q', '123') }.to raise_error(FglPdf::Symbology::Unsupported)
    end

    it 'raises InvalidData (an Unsupported) for bad data' do
      expect { described_class.linear('E', '12AB') }.to raise_error(FglPdf::Symbology::InvalidData)
      expect { described_class.linear('U', '12345') }.to raise_error(FglPdf::Symbology::Unsupported)
      expect { described_class.linear('C', '1234') }.to raise_error(FglPdf::Symbology::Unsupported)
    end
  end

  describe '.qr_matrix' do
    it 'returns a square boolean matrix, 21 modules for short data' do
      matrix = described_class.qr_matrix('hello')
      expect(matrix.length).to eq(21)
      expect(matrix).to all(have_attributes(length: 21))
      expect(matrix.flatten.uniq).to contain_exactly(true, false)
      expect(matrix[0][0..6]).to all(be(true)) # finder pattern
    end

    it 'grows for longer data and honours ecc' do
      expect(described_class.qr_matrix('x' * 100).length).to be > 21
      expect(described_class.qr_matrix('hello', ecc: :h).length).to eq(21)
    end
  end
end
