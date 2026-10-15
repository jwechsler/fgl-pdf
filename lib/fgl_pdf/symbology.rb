# frozen_string_literal: true

require 'barby/barcode/code_39'
require 'barby/barcode/code_128'
require 'barby/barcode/ean_13'
require 'barby/barcode/ean_8'
require 'barby/barcode/code_25_interleaved'
require 'barby/barcode/codabar'
require 'rqrcode'

module FglPdf
  # Barcode encoders: FGL symbology letter + data → module pattern (and QR matrices).
  module Symbology
    # Symbology we cannot encode (or data it cannot represent).
    class Unsupported < StandardError; end
    # The symbology is known but the data is not valid for it.
    class InvalidData < Unsupported; end

    # FGL Code128 subset-switch characters ('^' prefixed in some firmware) are not
    # interpreted; data is auto-encoded by Barby.
    NAMES = { 'U' => 'UPC', 'E' => 'EAN13', 'N' => 'Code39', 'F' => 'I2of5', 'C' => 'Codabar',
              'O' => 'Code128' }.freeze

    module_function

    # Returns { modules: '1010…', human_text: String } for FGL barcode type +type_letter+.
    def linear(type_letter, data)
      data = data.to_s
      case type_letter.to_s.upcase
      when 'U' then upc(data)
      when 'E' then ean13(data)
      when 'N' then code39(data)
      when 'F' then interleaved(data)
      when 'C' then codabar(data)
      when 'O' then code128(data)
      else raise Unsupported, "barcode type #{type_letter.inspect} not supported"
      end
    rescue ArgumentError => e
      raise InvalidData, "invalid #{NAMES.fetch(type_letter.to_s.upcase, type_letter)} data #{data.inspect}: " \
                         "#{e.message}"
    end

    # QR code module matrix (true = dark), without quiet zone.
    def qr_matrix(data, ecc: :m)
      qr = RQRCode::QRCode.new(data.to_s, level: ecc)
      qr.modules.map { |row| row.map { |m| m ? true : false } }
    rescue RQRCode::QRCodeRunTimeError, RQRCode::QRCodeArgumentError => e
      raise InvalidData, "QR data not encodable: #{e.message}"
    end

    # Digits only, with EAN J/K/L field markers removed.
    def digits(data)
      stripped = data.delete('JKLjkl')
      raise InvalidData, "non-digit characters in #{data.inspect}" unless stripped.match?(/\A\d+\z/)

      stripped
    end

    def upc(data)
      d = digits(data)
      case d.length
      when 11, 12
        code = Barby::EAN13.new("0#{d[0, 11]}")
        { modules: code.encoding, human_text: code.data_with_checksum[1..] }
      when 7, 8
        code = Barby::EAN8.new(d[0, 7])
        { modules: code.encoding, human_text: code.data_with_checksum }
      else
        raise InvalidData, "UPC/EAN8 needs 7, 8, 11 or 12 digits, got #{d.length}"
      end
    end

    def ean13(data)
      d = digits(data)
      raise InvalidData, "EAN13 needs 12 or 13 digits, got #{d.length}" unless [12, 13].include?(d.length)

      code = Barby::EAN13.new(d[0, 12])
      { modules: code.encoding, human_text: code.data_with_checksum }
    end

    def code39(data)
      text = data.delete('*')
      code = begin
        Barby::Code39.new(text)
      rescue ArgumentError
        Barby::Code39.new(text, true)
      end
      { modules: code.encoding, human_text: "*#{text}*" }
    end

    def interleaved(data)
      d = digits(data)
      d = "0#{d}" if d.length.odd?
      code = Barby::Code25Interleaved.new(d)
      { modules: code.encoding, human_text: d }
    end

    def codabar(data)
      text = data.upcase
      code = Barby::Codabar.new(text)
      { modules: code.encoding, human_text: text }
    end

    def code128(data)
      raise InvalidData, 'Code128 data is empty' if data.empty?

      code = Barby::Code128.new(data)
      { modules: code.encoding, human_text: data }
    end
  end
end
