# frozen_string_literal: true

require 'open3'
require 'rbconfig'

RSpec.describe 'exe/fgl2pdf', :integration do
  let(:exe) { File.expand_path('../exe/fgl2pdf', __dir__) }

  before do
    skip 'FglPdf::Interpreter / Renderer::Pdf not loadable yet' unless
      defined?(FglPdf::Interpreter) && defined?(FglPdf::Renderer::Pdf) && defined?(FglPdf::LogoStore)
  end

  around do |example|
    Dir.mktmpdir('fgl2pdf') do |dir|
      @dir = dir
      example.run
    end
  end

  def run_cli(*args, stdin: '')
    Open3.capture3(RbConfig.ruby, exe, *args, stdin_data: stdin, binmode: true)
  end

  it 'writes one PDF per ticket' do
    out, _err, status = run_cli(File.join(FIXTURES, 'order_general_admission.fgl'), '-o', @dir)
    expect(status.exitstatus).to eq(0)
    expect(Dir.children(@dir).sort).to eq(%w[order_general_admission-001.pdf order_general_admission-002.pdf])
    expect(out.lines.size).to eq(2)
    expect(File.binread(File.join(@dir, 'order_general_admission-001.pdf'))).to start_with('%PDF')
  end

  it 'reads stdin and writes a single PDF with --single' do
    _out, _err, status = run_cli('-', '-o', @dir, '--single', stdin: '<RC10,10><F3>ONE<p><RC10,10><F3>TWO<p>')
    expect(status.exitstatus).to eq(0)
    expect(Dir.children(@dir)).to eq(['stdin.pdf'])
  end

  it 'fails when there is no print command' do
    _out, err, status = run_cli('-', '-o', @dir, stdin: '<RC10,10><F3>NO PRINT')
    expect(status.exitstatus).to eq(1)
    expect(err).to include('no tickets found')
  end
end
