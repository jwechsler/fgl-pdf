# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'fgl_pdf/config'
require 'fgl_pdf/fonts'
require 'fgl_pdf/ticket'
require 'fgl_pdf/bitmap'
require 'fgl_pdf/renderer/pdf'
require 'pdf/reader'
require 'stringio'
require 'tmpdir'

# 8-bit grayscale raster (PGM) of one page; 1 pixel = 1 dot at the printer dpi.
class RendererSpecRaster
  DARK = /[\x00-\x7F]/n

  attr_reader :width, :height

  def initialize(width, height, data)
    @width = width
    @height = height
    @data = data
  end

  def dark?(col, row)
    @data.getbyte((row * width) + col) < 128
  end

  # [min_x, min_y, max_x + 1, max_y + 1] of dark pixels inside +region+, or nil.
  def dark_bbox(region = [0, 0, width, height])
    x0, y0, x1, y1 = region
    box = nil
    (y0...y1).each do |row|
      line = @data.byteslice((row * width) + x0, x1 - x0)
      first = line.index(DARK) or next
      last = x0 + line.rindex(DARK) + 1
      box = box ? [[box[0], x0 + first].min, box[1], [box[2], last].max, row + 1] : [x0 + first, row, last, row + 1]
    end
    box
  end
end

RSpec.describe FglPdf::Renderer::Pdf do
  let(:config) { FglPdf::Config.new }
  let(:renderer) { described_class.new(config) }

  def ticket(*items, config: self.config)
    FglPdf::Ticket.new(width_dots: config.width_dots, length_dots: config.length_dots, items: items)
  end

  def resident_text(string, at: [100, 100], rotation: :NR, font: 3, **opts)
    f = FglPdf::Fonts.resident(font)
    FglPdf::Text.new(x: at[0], y: at[1], rotation: rotation, string: string, font_kind: :resident, face: f.face,
                     glyph_w: f.glyph_w, glyph_h: f.glyph_h, cell_w: f.box_w,
                     length: string.length * f.box_w, height: f.box_h, **opts)
  end

  def ttf_text(string, at: [100, 100], rotation: :NR, size: 40, **opts)
    face = config.ttf_path(1)
    FglPdf::Text.new(x: at[0], y: at[1], rotation: rotation, string: string, font_kind: :ttf, face: face, size: size,
                     length: FglPdf::Fonts.ttf_width(face, string, size), height: size, **opts)
  end

  def reader(pdf)
    PDF::Reader.new(StringIO.new(pdf))
  end

  def run_text(pdf, page = 0)
    reader(pdf).pages[page].runs.map(&:text).join.gsub(/\s+/, '')
  end

  def rasterize(pdf, dpi: config.dpi)
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, 't.pdf'), pdf)
      system('pdftoppm', '-r', dpi.to_s, '-gray', File.join(dir, 't.pdf'), File.join(dir, 'p'), exception: true)
      Dir[File.join(dir, 'p*.pgm')].map { |f| parse_pgm(File.binread(f)) }
    end
  end

  def parse_pgm(bytes)
    match = bytes.match(/\AP5\s+(\d+)\s+(\d+)\s+255\s/n)
    width = match[1].to_i
    height = match[2].to_i
    RendererSpecRaster.new(width, height, bytes.byteslice(match.end(0), width * height))
  end

  def dark?(img, col, row)
    img.dark?(col, row)
  end

  def dark_bbox(img, region = nil)
    region ? img.dark_bbox(region) : img.dark_bbox
  end

  def expect_bbox_near(actual, expected, tol: 2)
    expect(actual).not_to be_nil
    actual.zip(expected).each { |a, e| expect(a).to be_within(tol).of(e) }
  end

  describe 'page geometry' do
    it 'is 5.5" x 2" landscape (396 x 144 pt) at 300 dpi' do
      page = reader(renderer.render(ticket)).pages.first
      expect(page.attributes[:MediaBox].map(&:round)).to eq([0, 0, 396, 144])
    end

    it 'has the same physical size at 200 dpi' do
      cfg = FglPdf::Config.new(dpi: 200)
      page = reader(described_class.new(cfg).render(ticket(config: cfg))).pages.first
      expect(page.attributes[:MediaBox].map(&:round)).to eq([0, 0, 396, 144])
    end

    it 'renders one page per ticket with render_many' do
      pdf = renderer.render_many([ticket, ticket(resident_text('B')), ticket])
      expect(reader(pdf).page_count).to eq(3)
    end
  end

  describe 'text' do
    it 'draws extractable resident text (proportional and monospace faces)' do
      pdf = renderer.render(ticket(resident_text('HELLO 42'), resident_text('Courier', at: [100, 300], font: 8)))
      text = run_text(pdf)
      expect(text).to include('HELLO42')
      expect(text).to include('Courier')
    end

    it 'replaces characters outside WinAnsi instead of raising' do
      pdf = renderer.render(ticket(resident_text('café ☃ €')))
      expect(run_text(pdf)).to include('café?€')
    end

    it 'sizes stand-in resident glyphs to glyph_h (cap height) within the cell' do
      img = rasterize(renderer.render(ticket(resident_text('HH', at: [200, 100], font: 2)))).first
      f = FglPdf::Fonts.resident(2)
      expect_bbox_near(dark_bbox(img), [200, 100, 200 + f.box_w + f.glyph_w, 100 + f.glyph_h])
    end

    # Sizes measured on a ticket printed by a real Boca (see FglPdf::Fonts).
    it 'draws OCR-A (F7) with capitals filling glyph_h, one glyph per cell' do
      img = rasterize(renderer.render(ticket(resident_text('HH', at: [200, 100], font: 7)))).first
      expect_bbox_near(dark_bbox(img), [198, 101, 237, 130])
    end

    it 'draws OCR-B (F3) from the top of the digits to the bottom of the descenders in glyph_h' do
      img = rasterize(renderer.render(ticket(resident_text('Hy0', at: [200, 100], font: 3)))).first
      expect_bbox_near(dark_bbox(img), [202, 101, 256, 131])
    end

    it 'draws OCR text as an extractable run' do
      pdf = renderer.render(ticket(resident_text('EXPLORE1026 GEN35'),
                                   resident_text('DOE, JOHN', at: [100, 300], font: 4)))
      expect(run_text(pdf)).to include('EXPLORE1026GEN35', 'DOE,JOHN')
    end

    it 'draws extractable TTF text with the baseline at ascender x size' do
      item = ttf_text('Wit 2024', at: [100, 200], size: 50)
      run = reader(renderer.render(ticket(item))).pages.first.runs.first
      ascender, = FglPdf::Fonts.ttf_em_fractions(item.face)
      k = config.pt_per_dot
      expect(run.text).to eq('Wit 2024')
      expect(run.x).to be_within(1.5).of(100 * k)
      expect(run.y).to be_within(1.5).of(144 - ((200 + (ascender * 50)) * k))
    end

    it 'draws inverse text as white on a padded black box' do
      item = ttf_text('INV', at: [300, 200], size: 40, inverse: true)
      img = rasterize(renderer.render(ticket(item))).first
      expect_bbox_near(dark_bbox(img), [298, 198, 302 + item.length.ceil, 242], tol: 2)
      expect(dark_bbox(img, [300, 200, 300 + item.length.floor, 240]).nil?).to be(false)
      white = (200...240).sum { |y| (300...(300 + item.length.to_i)).count { |x| !dark?(img, x, y) } }
      expect(white).to be > 50
    end

    it 'places TTF text in the right quadrant for :RR' do
      # :RR anchor at (800, 300): advance runs down (+y), glyphs extend to the left (-x).
      item = ttf_text('ROTATED', at: [800, 300], rotation: :RR, size: 40)
      img = rasterize(renderer.render(ticket(item))).first
      min_x, min_y, max_x, max_y = dark_bbox(img)
      expect(max_x).to be <= 801
      expect(min_x).to be >= 755
      expect(min_y).to be >= 299
      expect(max_y).to be_within(15).of(300 + item.length)
    end
  end

  describe 'rotations' do
    it 'maps the local frame correctly for all four rotations' do
      # A solid "barcode" of 100 x 40 local dots anchored at (800, 300).
      pages = FglPdf::Geometry::ROTATIONS.map do |rot|
        ticket(FglPdf::Barcode.new(x: 800, y: 300, rotation: rot, modules: '1' * 50, module_w: 2, bar_height: 40))
      end
      images = rasterize(renderer.render_many(pages))
      FglPdf::Geometry::ROTATIONS.each_with_index do |rot, i|
        expected = FglPdf::Geometry.bbox(800, 300, rot, 100, 40)
        expect_bbox_near(dark_bbox(images[i]), expected, tol: 1)
      end
    end
  end

  describe 'graphics' do
    let(:images) do
      bitmap = FglPdf::Bitmap.new(4, 2)
      bitmap[0, 0] = true
      bitmap[3, 1] = true
      items = [
        FglPdf::Rect.new(x: 10, y: 10, w: 100, h: 20),
        FglPdf::BoxOutline.new(x: 200, y: 10, w: 100, h: 80, thickness: 5),
        FglPdf::Image.new(x: 400, y: 10, rotation: :NR, bitmap: bitmap, scale_w: 10, scale_h: 10),
        FglPdf::Matrix2D.new(x: 600, y: 10, rotation: :NR, matrix: [[true, false], [false, true]], module_size: 10),
        FglPdf::Placeholder.new(x: 800, y: 10, rotation: :NR, length: 200, height: 100, label: 'PDF417'),
        FglPdf::Barcode.new(x: 1100, y: 10, rotation: :NR, modules: '1011', module_w: 3, bar_height: 50,
                            human_text: '12'),
        FglPdf::Rect.new(x: 10, y: 300, w: 100, h: 100),
        FglPdf::Rect.new(x: 30, y: 320, w: 20, h: 20, overwrite: true)
      ]
      rasterize(renderer.render(ticket(*items))).first
    end
    let(:img) { images }

    it 'fills rectangles' do
      expect_bbox_near(dark_bbox(img, [0, 0, 150, 150]), [10, 10, 110, 30], tol: 1)
    end

    it 'draws box outlines growing inward' do
      expect_bbox_near(dark_bbox(img, [150, 0, 350, 150]), [200, 10, 300, 90], tol: 1)
      expect(dark?(img, 202, 50)).to be(true)
      expect(dark?(img, 208, 50)).to be(false)
      expect(dark?(img, 250, 50)).to be(false)
    end

    it 'scales images and keeps transparent pixels white' do
      expect(dark?(img, 405, 15)).to be(true)
      expect(dark?(img, 435, 25)).to be(true)
      expect(dark?(img, 415, 15)).to be(false)
      expect(dark?(img, 405, 25)).to be(false)
    end

    it 'draws matrix modules' do
      expect(dark?(img, 605, 15)).to be(true)
      expect(dark?(img, 615, 25)).to be(true)
      expect(dark?(img, 615, 15)).to be(false)
    end

    it 'draws placeholders with an outline and cross' do
      expect_bbox_near(dark_bbox(img, [750, 0, 1050, 150]), [800, 10, 1000, 110], tol: 1)
      expect(dark?(img, 900, 60)).to be(true) # centre of the cross
    end

    it 'draws barcode bars and human-readable text below them' do
      expect(dark?(img, 1101, 30)).to be(true)
      expect(dark?(img, 1104, 30)).to be(false)
      expect(dark?(img, 1110, 30)).to be(true)
      expect(dark_bbox(img, [1090, 61, 1200, 80])).not_to be_nil
    end

    it 'clears the area under overwrite items before drawing' do
      expect(dark?(img, 20, 310)).to be(true)
      expect(dark?(img, 40, 330)).to be(true)
    end
  end

  describe 'debug overlays' do
    it 'renders debug_grid and annotate without error' do
      cfg = FglPdf::Config.new(debug_grid: true, annotate: true)
      t = ticket(resident_text('X'), config: cfg)
      t.warn('unknown command <ZZ> ☃')
      pdf = described_class.new(cfg).render(t)
      expect(run_text(pdf)).to include('unknowncommand<ZZ>?')
    end
  end
end
