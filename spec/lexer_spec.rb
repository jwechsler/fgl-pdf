# frozen_string_literal: true

RSpec.describe FglPdf::Lexer do
  def lex(bytes)
    described_class.tokenize(bytes.b)
  end

  def commands(tokens)
    tokens.select { |t| t.kind == :command }
  end

  sample_fixtures = %w[order_general_admission.fgl order_reserved_seats.fgl order_reprint.fgl
                       logo_download.fgl].freeze

  describe 'chunking independence' do
    sample_fixtures.each do |name|
      it "lexes the #{name} sample identically when split at every byte boundary" do
        bytes = fixture(name)
        whole = described_class.new.feed(bytes)
        expect(whole.map(&:raw).join).to eq(bytes)
        (1...bytes.bytesize).each do |cut|
          lexer = described_class.new
          tokens = lexer.feed(bytes.byteslice(0, cut)) + lexer.feed(bytes.byteslice(cut..))
          expect(tokens).to eq(whole), "split at #{cut}"
          expect(lexer.pending_bytesize).to eq(0)
        end
      end

      it "lexes the #{name} sample identically when fed one byte at a time" do
        bytes = fixture(name)
        lexer = described_class.new
        tokens = bytes.each_byte.flat_map { |b| lexer.feed(b.chr) }
        expect(tokens).to eq(described_class.new.feed(bytes))
      end
    end

    it 'buffers an incomplete command' do
      lexer = described_class.new
      expect(lexer.feed('<RC10,')).to eq([])
      expect(lexer.pending_bytes).to eq('<RC10,')
      tokens = lexer.feed('20>')
      expect(tokens.map(&:name)).to eq(['RC'])
      expect(tokens.first.args).to eq(%w[10 20])
    end
  end

  describe 'commands' do
    {
      '<RC10,230.0>' => ['RC', %w[10 230.0]],
      '<RTF4,16>' => ['RTF', %w[4 16]],
      '<TTF1,12>' => ['TTF', %w[1 12]],
      '<HW2,2>' => ['HW', %w[2 2]],
      '<F13>' => ['F', %w[13]],
      '<LD1>' => ['LD', %w[1]],
      '<X2>' => ['X', %w[2]],
      '<QRV2>' => ['QRV', %w[2]],
      '<s1>' => ['s1', []],
      '<S3>' => ['S3', []],
      '<P1>' => ['P1', []],
      '<dpi300>' => ['dpi', %w[300]],
      '<p>' => ['p', []],
      '<OWE>' => ['OWE', []]
    }.each do |source, (name, args)|
      it "splits #{source} into #{name} #{args.inspect}" do
        token = lex(source).first
        expect([token.kind, token.name, token.args, token.raw]).to eq([:command, name, args, source.b])
      end
    end

    it 'treats a stray < as text' do
      tokens = lex("a < b\r")
      expect(tokens.map(&:kind)).to eq(%i[text text text newline])
      expect(tokens.first(3).map(&:text).join).to eq('a < b')
    end
  end

  describe 'control bytes' do
    it 'maps CR, LF, FF and GS' do
      tokens = lex("AB\r\n\f\x1D")
      expect(tokens.map(&:kind)).to eq(%i[text newline ignored print print])
      expect(tokens.last(2).map(&:name)).to eq(%w[p q])
    end
  end

  describe 'binary payloads' do
    it 'reads exactly # bytes after <G#>, even < > ESC and CR' do
      payload = "<p>\e\r\x0C>".b
      tokens = lex("<G#{payload.bytesize}>#{payload}<p>")
      expect(tokens.map(&:kind)).to eq(%i[command command])
      expect(tokens.first.payload).to eq(payload)
      expect(tokens.last.name).to eq('p')
    end

    it 'reads 7 bytes after a bare <G>' do
      expect(lex("<G>1234567X\r").first.payload).to eq('1234567')
    end

    it 'reads # hex characters after <g#>' do
      expect(lex('<g4>FF00<p>').first.payload).to eq('FF00')
    end

    it 'waits for the whole payload' do
      lexer = described_class.new
      expect(lexer.feed('<G4>ab')).to eq([])
      expect(lexer.feed("cd\r").map(&:kind)).to eq(%i[command newline])
    end
  end

  describe 'ESC blocks' do
    it 'honors <bmp><G n> lengths inside the logo download block' do
      bytes = fixture('logo_download.fgl')
      tokens = lex(bytes)
      expect(tokens.map(&:kind)).to eq(%i[command esc_block])
      block = tokens.last
      expect(block.children.map(&:name)).to eq(%w[bmp G])
      bmp = fixture('logo_240x120.bmp')
      expect(block.children.last.payload).to eq(bmp)
      expect(block.raw.bytesize).to eq(bytes.bytesize - '<SP10,10>'.bytesize)
    end

    it 'does not end the block at ESC bytes inside a payload' do
      payload = "BM\e\e<>\r".b
      tokens = lex("\e<ID3><bmp><G#{payload.bytesize}>#{payload}\e<p>")
      expect(tokens.map(&:kind)).to eq(%i[esc_block command])
      expect(tokens.first.children.map(&:name)).to eq(%w[ID bmp G])
      expect(tokens.first.children.last.payload).to eq(payload)
    end

    it 'lexes ESC c as a command' do
      expect(lex("\ec<p>").map(&:name)).to eq(%w[ESCc p])
    end

    it 'flushes an unterminated block with an error' do
      lexer = described_class.new
      expect(lexer.feed("\e<RC1,1>abc")).to eq([])
      token = lexer.flush.first
      expect([token.kind, token.error]).to eq(%i[esc_block unterminated])
    end
  end

  describe 'fields' do
    it 'attaches ~text~ to <CTR#> and <RTJ#>' do
      tokens = lex('<CTR530>~Sample Theatre~<RTJ100>~$ 5.00~')
      expect(tokens.map(&:data)).to eq(['Sample Theatre', '$ 5.00'])
      expect(tokens.map(&:raw).join).to eq('<CTR530>~Sample Theatre~<RTJ100>~$ 5.00~')
    end

    it 'waits for the byte after <CTR#> to decide whether a field follows' do
      lexer = described_class.new
      expect(lexer.feed('<CTR530>')).to eq([])
      expect(lexer.feed('~Hi')).to eq([])
      expect(lexer.feed('~').first.data).to eq('Hi')
    end

    it 'leaves data nil when no field follows' do
      tokens = lex('<CTR530>plain')
      expect(tokens.first.data).to be_nil
      expect(tokens.last.text).to eq('plain')
    end
  end

  describe 'barcode data' do
    {
      '<NP4>*ABC-123*' => %w[NP ABC-123],
      '<NXP4>*ABC*' => %w[NXP ABC],
      '<FL6>:1234567890:' => %w[FL 1234567890],
      '<OL8>^Code 128!^' => ['OL', 'Code 128!'],
      '<oP3>^x^' => %w[oP x],
      '<CP4>A1234B' => %w[CP A1234B],
      '<UP4>J01234K56789L' => %w[UP 0123456789],
      '<EP4>9J014561K780128L' => %w[EP 9014561780128]
    }.each do |source, (name, data)|
      it "delimits #{source}" do
        tokens = lex("#{source}<p>")
        expect(tokens.map(&:name)).to eq([name, 'p'])
        expect(tokens.first.data).to eq(data)
        expect(tokens.first.raw).to eq(source.b)
      end
    end

    it 'consumes {data} after 2D commands but not after <QRV#>' do
      tokens = lex('<QRV2><QR6,0,0,0>{https://example.org/t?id=1}<PDF8,3,0>{x}')
      expect(tokens.map(&:name)).to eq(%w[QRV QR PDF])
      expect(tokens.map(&:data)).to eq([nil, 'https://example.org/t?id=1', 'x'])
    end
  end

  describe 'transparent mode and prefixes' do
    it 'drops <t> … <n> content in one token' do
      tokens = lex("<t>junk <RC1,1>\r<n>A")
      expect(tokens.map(&:kind)).to eq(%i[transparent text])
      expect(tokens.first.raw).to eq("<t>junk <RC1,1>\r<n>")
    end

    it 'ignores <FGL> prefixes' do
      expect(lex("<FGL><RC1,1>\r").map(&:kind)).to eq(%i[ignored command newline])
    end
  end
end
