# frozen_string_literal: true

RSpec.describe FglPdf::Interpreter do
  let(:config) { FglPdf::Config.new }
  let(:logo_store) { FglPdf::LogoStore.new }
  let(:counter) { FglPdf::Counter.new(100) }
  let(:statuses) { [] }
  let(:interpreter) do
    described_class.new(config: config, logo_store: logo_store, counter: counter,
                        on_status: ->(name) { statuses << name })
  end

  def run(bytes)
    interpreter.feed(bytes.b)
  end

  def ticket(bytes)
    tickets = run(bytes)
    expect(tickets.size).to eq(1)
    tickets.first
  end

  def texts(ticket)
    ticket.items.grep(FglPdf::Text)
  end

  def logo_download
    fixture('logo_download.fgl')
  end

  describe 'text placement' do
    it 'places resident text at the cursor with font metrics' do
      text = texts(ticket('<RC10,100><F3>AB<p>')).first
      expect(text.to_h.slice(:x, :y, :rotation, :string, :font_kind, :face)).to eq(
        x: 100, y: 10, rotation: :NR, string: 'AB', font_kind: :resident, face: 'Helvetica'
      )
      expect([text.cell_w, text.glyph_w, text.glyph_h, text.length, text.height]).to eq([20, 17, 31, 40, 33])
    end

    it 'scales by HW and divides by SD' do
      text = texts(ticket('<F3><HW4,2><SD2>AB<p>')).first
      expect([text.cell_w, text.glyph_w, text.glyph_h, text.length, text.height]).to eq([40, 34, 31, 80, 33])
    end

    it 'uses <BS> to override the cell size' do
      text = texts(ticket('<F3><BS30,40>AB<p>')).first
      expect([text.cell_w, text.length, text.height]).to eq([30, 60, 40])
    end

    it 'advances along +x for NR' do
      first, second = texts(ticket('<RC10,100>AB<F3>CD<p>'))
      expect([first.x, second.x, second.y]).to eq([100, 140, 10])
    end

    it 'advances along +y for RR text runs' do
      first, second = texts(ticket('<RC10,100><RR>AB<F3>CD<p>'))
      expect([first.x, first.y, first.rotation]).to eq([100, 10, :RR])
      expect([second.x, second.y]).to eq([100, 50])
    end

    it 'advances along -x for RU and -y for RL' do
      _, ru = texts(ticket('<RC300,500><RU>AB<F3>CD<p>'))
      _, rl = texts(ticket('<RC300,500><RL>AB<F3>CD<p>'))
      expect([ru.x, ru.y]).to eq([460, 300])
      expect([rl.x, rl.y]).to eq([500, 260])
    end

    it 'moves to the next line on CR (line anchor + down vector * line height)' do
      nr = texts(ticket("<RC10,100>AB\rC\rD<p>"))
      expect(nr.map { |t| [t.x, t.y] }).to eq([[100, 10], [100, 43], [100, 76]])
      rr = texts(ticket("<RC10,100><RR><F4><HW2,2>AB\rC<p>"))
      expect(rr.map { |t| [t.x, t.y] }).to eq([[100, 10], [78, 10]])
    end

    it 'uses TrueType metrics for <RTF>' do
      text = texts(ticket('<RTF3,8>Hi<p>')).first
      expect(text.font_kind).to eq(:ttf)
      expect(text.face).to eq(config.ttf_path(3))
      expect(text.size).to be_within(0.01).of(8 * 300 / 72.0)
      expect(text.height).to be_within(0.01).of(text.size * 1.2)
      expect(text.length).to be_within(0.01).of(FglPdf::Fonts.ttf_width(config.ttf_path(3), 'Hi', text.size))
    end

    it 'falls back to TrueType font 3 for unknown ids' do
      t = ticket('<RTF42,8>Hi<p>')
      expect(texts(t).first.face).to eq(config.ttf_path(3))
      expect(t.warnings).to include('unknown TrueType font <RTF42,8>, using font 3')
    end

    it 'decodes text as Windows-1252' do
      expect(texts(ticket("Caf\xE9 \x80<p>")).first.string).to eq('Café €')
    end

    it 'sets inverse and overwrite flags' do
      a, b = texts(ticket('<EI><OWE>A<DI><OWD>B<p>'))
      expect([a.inverse, a.overwrite, b.inverse, b.overwrite]).to eq([true, true, false, false])
    end
  end

  describe 'justified fields' do
    it 'centers <CTR#> text in the field' do
      text = texts(ticket('<RC10,100><CTR100>~AB~<p>')).first
      expect(text.x).to eq(130)
    end

    it 'right-justifies <RTJ#> text' do
      text = texts(ticket('<RC10,100><RTJ100>~AB~<p>')).first
      expect(text.x).to eq(160)
    end

    it 'clips the field at the ticket edge' do
      text = texts(ticket('<RC10,1600><CTR530>~AB~<p>')).first
      expect(text.x).to eq(1605)
    end

    it 'centers along the rotation (RL builds toward row 0)' do
      text = texts(ticket('<RC550,20><RL><CTR530>~AB~<p>')).first
      expect([text.x, text.y]).to eq([20, 305])
    end

    it 'left-justifies text longer than the field' do
      text = texts(ticket('<RC10,100><CTR30>~ABCD~<p>')).first
      expect(text.x).to eq(100)
    end
  end

  describe 'lines and boxes' do
    it 'draws <BXr,c> as an outline with the LT thickness' do
      box = ticket('<RC80,140><LT3><BX400,800><p>').items.first
      expect(box.to_h).to eq(x: 140, y: 80, w: 800, h: 400, thickness: 3, overwrite: false)
    end

    it 'applies LT to the next line only' do
      first, second, third = ticket('<RC300,10><LT5><HX100><RC50,10><HX100><VX40><p>').items
      expect(first.to_h.slice(:x, :y, :w, :h)).to eq(x: 10, y: 295, w: 100, h: 5)
      expect(second.to_h.slice(:x, :y, :w, :h)).to eq(x: 10, y: 49, w: 100, h: 1)
      expect(third.to_h.slice(:x, :y, :w, :h)).to eq(x: 10, y: 50, w: 1, h: 40)
    end

    it 'grows a thick HX line upward so the sample orders\' full-width stub bars fit' do
      bar = ticket('<RC600,10><LT600><HX5><p>').items.first
      expect(bar.to_h.slice(:x, :y, :w, :h)).to eq(x: 10, y: 0, w: 5, h: 600)
    end
  end

  describe 'logos' do
    it 'stores an ESC BMP download without printing, then places it with <LD1>' do
      expect(run(logo_download)).to eq([])
      expect(interpreter.pending?).to be(false)
      expect(logo_store.fetch(1)).to be_a(FglPdf::Bitmap)
      image = ticket('<SP90,985><LD1><p>').items.first
      expect(image).to be_a(FglPdf::Image)
      expect(image.to_h.slice(:x, :y, :rotation, :scale_w, :scale_h)).to eq(
        x: 985, y: 90, rotation: :NR, scale_w: 1, scale_h: 1
      )
      expect([image.bitmap.width, image.bitmap.height]).to eq([240, 120])
    end

    it 'assigns implicit slots 1, 2, … and honors <ID#> for one download' do
      run(logo_download + logo_download + "<ID7>#{logo_download}#{logo_download}")
      expect(logo_store.slots).to eq([1, 2, 3, 7])
    end

    it 'restarts implicit slots at 1 for a new store on the same dir' do
      Dir.mktmpdir do |dir|
        described_class.new(logo_store: FglPdf::LogoStore.new(dir: dir)).feed(logo_download * 2)
        store = FglPdf::LogoStore.new(dir: dir)
        expect(store.slots).to eq([1, 2])
        store.store(1, FglPdf::LogoStore::Macro.new('old'))
        described_class.new(logo_store: store).feed(logo_download)
        expect(store.fetch(1)).to be_a(FglPdf::Bitmap)
      end
    end

    it 'scales logos by HW/SD and follows rotation' do
      run(logo_download)
      image = ticket('<RR><HW2,3><LD1><p>').items.first
      expect(image.to_h.slice(:rotation, :scale_w, :scale_h)).to eq(rotation: :RR, scale_w: 2, scale_h: 3)
    end

    it 'warns and draws a placeholder for a missing logo' do
      t = ticket('<SP90,985><LD1><p>')
      expect(t.warnings).to include('logo 1 not loaded')
      ph = t.items.first
      expect(ph.to_h).to eq(x: 985, y: 90, rotation: :NR, length: 100, height: 100, label: 'LOGO 1')
    end

    it 'warns for factory logos' do
      t = ticket('<LO2><p>')
      expect(t.warnings).to include('factory logo 2 not available')
      expect(t.items.first).to be_a(FglPdf::Placeholder)
    end

    it 'stores other ESC blocks as macros and replays them at the current state' do
      run("<ID5>\e<F1>HI\e")
      expect(logo_store.fetch(5)).to eq(FglPdf::LogoStore::Macro.new('<F1>HI'))
      t = ticket('<RC20,30><LD5><p>')
      expect(texts(t).first.to_h.slice(:x, :y, :string, :cell_w)).to eq(x: 30, y: 20, string: 'HI', cell_w: 7)
      expect(t.raw).to eq("<ID5>\e<F1>HI\e<RC20,30><LD5><p>".b)
    end

    it 'builds a bitmap from G band downloads (each CR moves down 8 dots)' do
      run("<ID2>\e<G2>\xFF\x01\r<G1>\x80\e".b)
      bitmap = logo_store.fetch(2)
      expect([bitmap.width, bitmap.height]).to eq([2, 16])
      expect([bitmap[0, 0], bitmap[1, 7], bitmap[1, 0], bitmap[0, 8]]).to eq([true, true, false, true])
    end

    it 'deletes logos with <DF#> and ESC c' do
      run("<ID1>\eA\e<ID2>\eB\e<DF1>")
      expect(logo_store.slots).to eq([2])
      run("\ec")
      expect(logo_store.slots).to eq([])
    end

    it 'prints inline <bmp><G n> at the cursor' do
      bmp = fixture('logo_240x120.bmp')
      image = ticket("<RC5,6><bmp><G#{bmp.bytesize}>#{bmp}<p>").items.first
      expect(image.to_h.slice(:x, :y)).to eq(x: 6, y: 5)
      expect(image.bitmap.width).to eq(240)
    end

    it 'prints inline <G#> column graphics and advances the cursor' do
      a, b = ticket("<RC5,6><G2>\xFF\x00<g2>80<p>".b).items
      expect([a.x, a.bitmap.width, a.bitmap.height, b.x]).to eq([6, 2, 8, 8])
      expect(b.bitmap[0, 0]).to be(true)
    end

    it 'keeps images for the next ticket after <h>' do
      run(logo_download)
      first, second = run('<LD1>A<h>B<p>')
      expect(first.items.map(&:class)).to eq([FglPdf::Image, FglPdf::Text])
      expect(second.items.map(&:class)).to eq([FglPdf::Image, FglPdf::Text])
    end
  end

  describe 'barcodes' do
    it 'renders picket-fence Code39 with human-readable text when BI is set' do
      bc = ticket('<RC50,60><X2><BI><NP5>*ABC*<p>').items.first
      expect(bc).to be_a(FglPdf::Barcode)
      expect(bc.to_h.slice(:x, :y, :rotation, :data, :module_w, :bar_height)).to eq(
        x: 60, y: 50, rotation: :NR, data: 'ABC', module_w: 2, bar_height: 40
      )
      expect(bc.modules).to match(/\A[01]+\z/)
      expect(bc.human_text).to include('ABC')
    end

    it 'resets BI after one barcode and uses the default bar width' do
      first, second = ticket('<BI><NP4>*A*<NP4>*B*<p>').items
      expect(first.human_text).not_to be_nil
      expect(second.human_text).to be_nil
      expect(second.module_w).to eq(config.default_bar_width)
    end

    it 'orients ladder barcodes as RR, lowercase types follow the rotation' do
      items = ticket('<OL4>^X^<RU><oP4>^X^<RL><oL4>^X^<RU><OP4>^X^<p>').items
      expect(items.map(&:rotation)).to eq(%i[RR RU RL NR])
    end

    it 'calls Symbology.linear with the uppercase type and stripped data' do
      allow(FglPdf::Symbology).to receive(:linear).and_return(modules: '101', human_text: 'x')
      ticket('<eP4>9J014561K780128L<p>')
      expect(FglPdf::Symbology).to have_received(:linear).with('E', '9014561780128')
    end

    it 'warns and draws a placeholder for data the symbology rejects' do
      t = ticket('<UP4>J12L<p>')
      expect(t.items.first).to be_a(FglPdf::Placeholder)
      expect(t.warnings.first).to start_with('barcode <UP4> not rendered')
    end

    it 'warns about the 3:1 ratio flag' do
      t = ticket('<NXP4>*A*<p>')
      expect(t.items.first).to be_a(FglPdf::Barcode)
      expect(t.warnings).to include('<NXP4>: 3:1 ratio not supported, drawn with standard ratio')
    end

    it 'renders QR codes with the module size and ECC level' do
      allow(FglPdf::Symbology).to receive(:qr_matrix).and_call_original
      qr = ticket('<RC10,20><QRV2><QR4,0,0,2>{https://example.org}<p>').items.first
      expect(FglPdf::Symbology).to have_received(:qr_matrix).with('https://example.org', ecc: :h)
      expect(qr).to be_a(FglPdf::Matrix2D)
      expect(qr.to_h.slice(:x, :y, :module_size)).to eq(x: 20, y: 10, module_size: 4)
    end

    it 'draws placeholders for PDF417, DataMatrix and Aztec' do
      t = ticket('<PDF8,3,0>{x}<DTM1>{y}<AZ1>{z}<p>')
      expect(t.items.map(&:label)).to eq(%w[PDF417 DataMatrix Aztec])
      expect(t.warnings).to include('PDF417 not rendered')
    end
  end

  describe 'printing' do
    it 'emits on <p>, <q>, <z>, FF and GS, including the print command in raw' do
      tickets = run("A<p>B<q>C<z>D\fE\x1D")
      expect(tickets.map { |t| texts(t).first.string }).to eq(%w[A B C D E])
      expect(tickets.map(&:raw)).to eq(['A<p>', 'B<q>', 'C<z>', "D\f", "E\x1D"])
    end

    it 'restores the default state after a print' do
      _, second = run('<RC50,60><RR><HW2,2><F1><EI><LT9>X<p>Y<HX5><p>')
      text = texts(second).first
      expect(text.to_h.slice(:x, :y, :rotation, :cell_w, :inverse)).to eq(
        x: 0, y: 0, rotation: :NR, cell_w: 20, inverse: false
      )
      expect(second.items.last.h).to eq(1)
    end

    it 'sets copies with <RE#> and increments the counter per copy' do
      t = ticket('<RE2>A<p>')
      expect(t.copies).to eq(3)
      expect(counter.value).to eq(103)
      expect(ticket('B<p>').copies).to eq(1)
    end

    it 'prints and sets the counter with <PC> and <TC#>' do
      first, second = run('<PC><p><TC42><PC><p>')
      expect(texts(first).first.string).to eq('0000100')
      expect(texts(second).first.string).to eq('0000042')
      expect(counter.value).to eq(43)
    end

    it 'clears pending items with <CB>' do
      expect(texts(ticket('A<CB>B<p>')).map(&:string)).to eq(['B'])
    end

    it 'shortens the ticket with <PL#>' do
      expect(ticket('<PL1200>A<p>').length_dots).to eq(1200)
      expect(ticket('A<p>').length_dots).to eq(1650)
    end

    it 'tracks pending content and bytes' do
      run('<RC1,1>AB')
      expect(interpreter.pending?).to be(true)
      expect(interpreter.pending_bytesize).to eq(9)
      run('<p>')
      expect(interpreter.pending?).to be(false)
      expect(interpreter.pending_bytesize).to eq(0)
    end

    it 'resets with #reset!' do
      run('<RR>AB')
      interpreter.reset!
      expect(interpreter.pending?).to be(false)
      expect(texts(ticket('C<p>')).first.rotation).to eq(:NR)
    end
  end

  describe 'diagnostics' do
    it 'rounds non-integer arguments with a warning' do
      t = ticket('<RC10,230.0>A<p>')
      expect(texts(t).first.x).to eq(230)
      expect(t.warnings).to eq(['non-integer argument in <RC10,230.0>'])
    end

    it 'warns about unknown commands' do
      expect(ticket('<XYZ9>A<p>').warnings).to eq(['unknown command <XYZ9>'])
    end

    it 'raises StrictError for unknown commands in strict mode' do
      config.strict = true
      expect { run('<XYZ9>') }.to raise_error(FglPdf::StrictError, 'unknown command <XYZ9>')
    end

    it 'ignores hardware commands silently and reports status queries' do
      t = ticket('<PP><dpi300><s1><S3><TRE>A<p>')
      expect(t.warnings).to eq([])
      expect(statuses).to eq(%w[s1 S3])
    end

    it 'warns once per off-page item, ignoring trailing blanks' do
      t = ticket('<RC10,1665><RR><F4><HW4,4>DOE, JOHN<RC10,1600><NR><F3><HW1,1>AB      <p>')
      expect(t.warnings).to eq(['Text "DOE, JOHN" extends off the ticket (x 1621..1665 > 1650)'])
    end
  end

  describe 'sample order fixtures' do
    it 'renders the general admission sample order as a ticket and a receipt' do
      run(logo_download)
      bytes = fixture('order_general_admission.fgl')
      tickets = run(bytes)
      expect(tickets.size).to eq(2)
      # raw holds everything since the previous print, so the logo download leads.
      expect(tickets.map(&:raw).join).to eq(logo_download + bytes)
      stub, receipt = tickets
      expect(stub.items.grep(FglPdf::Image).size).to eq(1)
      expect(texts(stub).map(&:string)).to include('DOE, JOHN', 'Test Show', '0000100')
      # The RR name is anchored at col 1665, so it builds back to col 1621 and its
      # anchor edge is 15 dots past the 1650-dot ticket.
      expect(stub.warnings).to include('Text "DOE, JOHN" extends off the ticket (x 1621..1665 > 1650)',
                                       'non-integer argument in <RC10,230.0>')
      expect(texts(receipt).map(&:string)).to include('RECEIPT', 'RECEIPT ONLY')
      expect(counter.value).to eq(102)
    end

    it 'renders the reserved seats sample order as two tickets and a receipt' do
      expect(run(fixture('order_reserved_seats.fgl')).size).to eq(3)
    end

    it 'renders the reprint sample order as a ticket and a receipt' do
      expect(run(fixture('order_reprint.fgl')).size).to eq(2)
    end

    it 'gives the same tickets when fed in 256-byte slices' do
      bytes = fixture('order_reserved_seats.fgl')
      whole = described_class.new(config: config).feed(bytes)
      sliced = bytes.bytes.each_slice(256).flat_map { |s| run(s.pack('C*')) }
      expect(sliced.map(&:raw)).to eq(whole.map(&:raw))
      expect(sliced.map { |t| t.items.size }).to eq(whole.map { |t| t.items.size })
      expect(sliced.map(&:warnings)).to eq(whole.map(&:warnings))
    end
  end
end
