# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'fgl_pdf'
require 'tmpdir'

FIXTURES = File.expand_path('fixtures', __dir__)

def fixture(name)
  File.binread(File.join(FIXTURES, name))
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
end
