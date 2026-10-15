# frozen_string_literal: true

require 'fileutils'

RSpec.describe FglPdf::Config do
  def font_dir_with(*names)
    dir = Dir.mktmpdir('fgl-fonts')
    names.each { |n| FileUtils.touch(File.join(dir, n)) }
    dir
  end

  it 'uses the bundled DejaVu faces by default' do
    config = described_class.new
    expect(File.basename(config.ttf_path(3))).to eq('DejaVuSans.ttf')
    expect(File.basename(config.ttf_path(6))).to eq('DejaVuSans-BoldOblique.ttf')
  end

  {
    'Windows' => %w[verdana.ttf verdanab.ttf verdanai.ttf verdanaz.ttf],
    'macOS' => ['Verdana.ttf', 'Verdana Bold.ttf', 'Verdana Italic.ttf', 'Verdana Bold Italic.ttf'],
    'Linux msttcorefonts' => %w[Verdana.ttf Verdana_Bold.ttf Verdana_Italic.ttf Verdana_Bold_Italic.ttf]
  }.each do |platform, names|
    it "maps #{platform} Verdana file names to ids 3-6" do
      dir = font_dir_with(*names)
      config = described_class.new(font_dir: dir)
      expect((3..6).map { |id| File.basename(config.ttf_path(id)) }).to eq(names)
    end
  end

  it 'keeps DejaVu for faces missing from the font dir' do
    config = described_class.new(font_dir: font_dir_with('VERDANA.TTF'))
    expect(File.basename(config.ttf_path(3))).to eq('VERDANA.TTF')
    expect(File.basename(config.ttf_path(4))).to eq('DejaVuSans-Bold.ttf')
  end

  it 'reads the font dir from FGL_PDF_FONT_DIR' do
    dir = font_dir_with('verdanab.ttf')
    config = described_class.from_env({ 'FGL_PDF_FONT_DIR' => dir })
    expect(config.ttf_path(4)).to eq(File.join(dir, 'verdanab.ttf'))
  end

  it 'lets an explicit ttf_map override any id' do
    config = described_class.new(ttf_map: { '4' => '/fonts/custom-bold.ttf' })
    expect(config.ttf_path(4)).to eq('/fonts/custom-bold.ttf')
  end
end
