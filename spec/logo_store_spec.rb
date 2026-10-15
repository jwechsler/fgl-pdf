# frozen_string_literal: true

RSpec.describe FglPdf::LogoStore do
  let(:bitmap) do
    FglPdf::Bitmap.new(3, 2, [[true, false, true], [false, true, false]])
  end

  it 'stores, fetches, deletes and clears logos' do
    store = described_class.new
    store.store(2, bitmap)
    store.store(5, described_class::Macro.new('<RC1,1>X'.b))
    expect(store.fetch(2)).to eq(bitmap)
    expect(store.fetch(5).bytes).to eq('<RC1,1>X')
    expect(store.slots).to eq([2, 5])
    store.delete(2)
    expect(store.fetch(2)).to be_nil
    store.clear
    expect(store.slots).to eq([])
  end

  it 'reports the lowest free slot' do
    store = described_class.new
    expect(store.next_free_slot).to eq(1)
    store.store(1, bitmap)
    store.store(3, bitmap)
    expect(store.next_free_slot).to eq(2)
  end

  it 'hands out implicit slots from 1 for each new store' do
    store = described_class.new
    expect([store.take_implicit_slot, store.take_implicit_slot]).to eq([1, 2])
    expect(described_class.new.take_implicit_slot).to eq(1)
  end

  it 'rejects other kinds of logo' do
    expect { described_class.new.store(1, 'nope') }.to raise_error(ArgumentError)
  end

  it 'persists bitmaps and macros to dir and reloads them' do
    Dir.mktmpdir do |dir|
      store = described_class.new(dir: dir)
      store.store(1, bitmap)
      store.store(2, described_class::Macro.new("<RC1,1>\e\x00".b))
      expect(Dir.children(dir).sort).to eq(%w[logo_1.png macro_2.fgl])

      reloaded = described_class.new(dir: dir)
      expect(reloaded.fetch(1).rows).to eq(bitmap.rows)
      expect(reloaded.fetch(2).bytes).to eq("<RC1,1>\e\x00".b)

      reloaded.store(1, described_class::Macro.new('x'))
      expect(Dir.children(dir).sort).to eq(%w[macro_1.fgl macro_2.fgl])
      reloaded.delete(2)
      expect(Dir.children(dir)).to eq(%w[macro_1.fgl])
      reloaded.clear
      expect(Dir.children(dir)).to eq([])
    end
  end

  it 'is safe to share across threads' do
    store = described_class.new
    slots = Array.new(8) { Thread.new { Array.new(50) { store.take_implicit_slot } } }.flat_map(&:value)
    expect(slots.sort).to eq((1..400).to_a)
    Array.new(8) { |t| Thread.new { 20.times { |i| store.store((t * 20) + i + 1, bitmap) } } }.each(&:join)
    expect(store.size).to eq(160)
  end
end
