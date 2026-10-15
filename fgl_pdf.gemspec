# frozen_string_literal: true

require_relative 'lib/fgl_pdf/version'

Gem::Specification.new do |spec|
  spec.name = 'fgl_pdf'
  spec.version = FglPdf::VERSION
  spec.authors = ['Jeremy Wechsler']
  spec.summary = 'Render Boca Systems FGL (Friendly Ghost Language) ticket printer data to PDF'
  spec.description = 'A pure-Ruby interpreter for Boca FGL that renders tickets to PDF, ' \
                     'plus a virtual TCP 9100 printer that spools each ticket to a numbered PDF.'
  spec.homepage = 'https://github.com/jwechsler/fgl-pdf'
  spec.license = 'GPL-3.0-or-later'
  spec.required_ruby_version = '>= 3.2'

  spec.files = Dir['lib/**/*.rb', 'exe/*', 'fonts/*', 'README.md', 'LICENSE']
  spec.bindir = 'exe'
  spec.executables = %w[fgl2pdf fgl-printer]
  spec.require_paths = ['lib']

  spec.add_dependency 'barby', '~> 0.7'
  spec.add_dependency 'chunky_png', '~> 1.4'
  spec.add_dependency 'prawn', '~> 2.5'
  spec.add_dependency 'rqrcode', '>= 2.0', '< 4'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
