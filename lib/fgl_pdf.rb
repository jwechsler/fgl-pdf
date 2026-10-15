# frozen_string_literal: true

require_relative 'fgl_pdf/version'
require_relative 'fgl_pdf/config'
require_relative 'fgl_pdf/geometry'
require_relative 'fgl_pdf/fonts'
require_relative 'fgl_pdf/ticket'
require_relative 'fgl_pdf/bitmap'
require_relative 'fgl_pdf/counter'
require_relative 'fgl_pdf/symbology'
require_relative 'fgl_pdf/lexer'
require_relative 'fgl_pdf/logo_store'
require_relative 'fgl_pdf/interpreter'
require_relative 'fgl_pdf/renderer/pdf'

# Boca Systems FGL (Friendly Ghost Language) → PDF.
module FglPdf
  class Error < StandardError; end
  # Raised in strict mode for unknown or malformed commands.
  class StrictError < Error; end

  RenderedTicket = Struct.new(:ticket, :pdf)

  # Renders every completed ticket in +bytes+ (terminated by <p>, <q>, <z>, FF, …).
  # Data after the last print command is discarded, as on a real printer.
  def self.render(bytes, config: Config.new, logo_store: LogoStore.new, counter: Counter.new)
    interpreter = Interpreter.new(config: config, logo_store: logo_store, counter: counter)
    renderer = Renderer::Pdf.new(config)
    interpreter.feed(bytes).map { |ticket| RenderedTicket.new(ticket, renderer.render(ticket)) }
  end
end
